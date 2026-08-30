#!/usr/bin/env node
"use strict"

const AdmZip = require("adm-zip")
const { CosmosClient } = require("@azure/cosmos")
const { DefaultAzureCredential } = require("@azure/identity")

const REPO = process.env.GITHUB_REPOSITORY
const GH_TOKEN = process.env.GH_TOKEN
const COSMOS_ENDPOINT = process.env.COSMOS_ENDPOINT
const COSMOS_DATABASE =
    process.env.COSMOS_METRICS_DATABASE || "InfraMonitorMetricsDB"
const AZURE_CLIENT_ID = process.env.AZURE_CLIENT_ID
const PUSHGATEWAY_URL = process.env.PUSHGATEWAY_URL?.trim() || ""
const DORA_WINDOW_DAYS = 30
const PIPELINE_WINDOW_DAYS = 7

// Every workflow this collector reads history from. deploy-frontend.yml and terraform.yml are
// deliberately excluded - they're unrelated to the three services' DORA/pipeline metrics.
const WORKFLOWS = [
    { file: "events-service-ci.yml", service: "events-service", kind: "ci" },
    {
        file: "events-service-production-promotion.yml",
        service: "events-service",
        kind: "promotion",
    },
    {
        file: "incidents-service-ci.yml",
        service: "incidents-service",
        kind: "ci",
    },
    {
        file: "incidents-service-production-promotion.yml",
        service: "incidents-service",
        kind: "promotion",
    },
    {
        file: "create-incident-job-ci.yml",
        service: "create-incident-job",
        kind: "ci",
    },
    {
        file: "create-incident-job-production-promotion.yml",
        service: "create-incident-job",
        kind: "promotion",
    },
]

function credential() {
    return new DefaultAzureCredential({
        managedIdentityClientId: AZURE_CLIENT_ID || undefined,
        excludeInteractiveBrowserCredential: true,
    })
}

async function ghApi(path) {
    const res = await fetch(`https://api.github.com/${path}`, {
        headers: {
            Authorization: `Bearer ${GH_TOKEN}`,
            Accept: "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    })
    if (!res.ok) {
        throw new Error(
            `GitHub API ${path} failed: ${res.status} ${await res.text()}`,
        )
    }
    return res.json()
}

async function getWorkflowId(file) {
    const data = await ghApi(`repos/${REPO}/actions/workflows/${file}`)
    return data.id
}

// created=> is a coarse pre-filter to keep result pages small - the real, exact dedup against
// what's already been processed happens client-side via id > prevLastRunId, since run IDs are
// assigned in strictly increasing creation order but the created_at filter's second-level
// precision isn't guaranteed to exclude the run already at the checkpoint.
async function getRunsSince(workflowId, sinceIso) {
    const runs = []
    let page = 1
    for (;;) {
        const data = await ghApi(
            `repos/${REPO}/actions/workflows/${workflowId}/runs?created=>${sinceIso}&per_page=100&page=${page}`,
        )
        runs.push(...data.workflow_runs)
        if (data.workflow_runs.length < 100) break
        page += 1
    }
    return runs.sort((a, b) => a.id - b.id)
}

async function getJobs(runId) {
    const jobs = []
    let page = 1
    for (;;) {
        const data = await ghApi(
            `repos/${REPO}/actions/runs/${runId}/jobs?per_page=100&page=${page}`,
        )
        jobs.push(...data.jobs)
        if (data.jobs.length < 100) break
        page += 1
    }
    return jobs
}

// smoke-test-production uploads smoke-test-evidence-production (summary.json, including
// image_tag) via `if: always()`, so it exists whenever that job at least started - even on a
// failed smoke test. This is the same artifact scripts/find-rollback-target.sh already reads
// image_tag out of; GitHub's API never exposes a completed run's workflow_dispatch inputs or
// job outputs directly, so the artifact is the only real source for this value.
async function getPromotedImageTag(runId) {
    const data = await ghApi(`repos/${REPO}/actions/runs/${runId}/artifacts`)
    const artifact = data.artifacts.find(
        (a) => a.name === "smoke-test-evidence-production",
    )
    if (!artifact) return null

    const res = await fetch(
        `https://api.github.com/repos/${REPO}/actions/artifacts/${artifact.id}/zip`,
        {
            headers: { Authorization: `Bearer ${GH_TOKEN}` },
        },
    )
    if (!res.ok) return null

    const zip = new AdmZip(Buffer.from(await res.arrayBuffer()))
    const entry = zip.getEntry("summary.json")
    if (!entry) return null

    try {
        const summary = JSON.parse(zip.readAsText(entry))
        return summary.image_tag || null
    } catch {
        return null
    }
}

function durationSeconds(startedAt, completedAt) {
    return (
        (new Date(completedAt).getTime() - new Date(startedAt).getTime()) / 1000
    )
}

async function writePipelineMetrics(container, wf, run, jobs) {
    let written = 0
    for (const job of jobs) {
        if (job.conclusion !== "success" && job.conclusion !== "failure")
            continue
        await container.items.upsert({
            id: `${run.id}-${job.id}`,
            service: wf.service,
            workflow_name: run.name,
            job_name: job.name,
            run_id: run.id,
            status: job.conclusion,
            started_at: job.started_at,
            completed_at: job.completed_at,
            duration_seconds: durationSeconds(job.started_at, job.completed_at),
            timestamp: new Date().toISOString(),
        })
        written += 1
    }
    return written
}

// One document per run summarizing the whole workflow's wall-clock time (created_at to
// updated_at) - genuinely different from summing this run's own job durations, since jobs that
// ran in parallel would otherwise be double-counted. job_name is a sentinel, not a real job
// name, and is explicitly excluded from computePipelineMetrics()'s per-job loop (see there).
// Same success/failure-only gate as writePipelineMetrics's own jobs, for the same reason: a
// cancelled/timed-out run's created_at-to-updated_at span doesn't represent a real completed
// pipeline duration.
async function writeWorkflowTotalMetric(container, wf, run) {
    if (run.conclusion !== "success" && run.conclusion !== "failure") return 0
    await container.items.upsert({
        id: `${run.id}-total`,
        service: wf.service,
        workflow_name: run.name,
        job_name: "__workflow_total__",
        run_id: run.id,
        status: run.conclusion,
        started_at: run.created_at,
        completed_at: run.updated_at,
        duration_seconds: durationSeconds(run.created_at, run.updated_at),
        timestamp: new Date().toISOString(),
    })
    return 1
}

async function writeDeploymentEvents(container, wf, run, jobs) {
    const findJob = (needle) => jobs.find((j) => j.name.includes(needle))
    const promote = findJob("Promote to production")
    const smoke = findJob("Smoke Test (production)")
    const rollback = findJob("Rollback production")

    const promotionSucceeded = Boolean(
        promote && promote.conclusion === "success",
    )
    // No image was ever promoted if promote-to-production didn't succeed - image_tag is
    // genuinely unavailable then, not just unrecovered (and smoke-test-production, the only
    // source of the evidence artifact, never even runs in that case).
    const imageTag = promotionSucceeded
        ? await getPromotedImageTag(run.id)
        : null
    let written = 0

    let eventType
    let completedAt
    if (!promotionSucceeded) {
        eventType = "deploy_failure"
        completedAt = promote?.completed_at || run.updated_at
    } else if (smoke && smoke.conclusion === "failure") {
        eventType = "deploy_failure"
        completedAt = smoke.completed_at
    } else {
        eventType = "deploy_success"
        completedAt = smoke?.completed_at || promote.completed_at
    }

    await container.items.upsert({
        id: `${run.id}-deploy`,
        service: wf.service,
        environment: "production",
        eventType,
        commit_sha: run.head_sha,
        image_tag: imageTag,
        triggered_at: run.created_at,
        completed_at: completedAt,
        timestamp: new Date().toISOString(),
    })
    written += 1

    if (rollback && rollback.conclusion === "success") {
        await container.items.upsert({
            id: `${run.id}-rollback`,
            service: wf.service,
            environment: "production",
            eventType: "rollback",
            commit_sha: run.head_sha,
            // The tag being rolled back FROM (the one the failed smoke test was against) -
            // the only image_tag this run's evidence artifact actually contains.
            image_tag: imageTag,
            triggered_at: rollback.started_at,
            completed_at: rollback.completed_at,
            timestamp: new Date().toISOString(),
        })
        written += 1
    }

    return written
}

async function processRun(wf, run, pipelineMetrics, deploymentEvents) {
    const jobs = await getJobs(run.id)
    let written = await writePipelineMetrics(pipelineMetrics, wf, run, jobs)
    // Workflow-level wall-clock time is only a meaningful "pipeline total" concept for the
    // staging CI/CD pipeline (build -> scan -> deploy -> smoke test) - a promotion run's own
    // total duration is a structurally different, much shorter kind of pipeline, and averaging
    // the two together under one gauge would misrepresent both.
    if (wf.kind === "ci") {
        written += await writeWorkflowTotalMetric(pipelineMetrics, wf, run)
    }
    if (wf.kind === "promotion") {
        written += await writeDeploymentEvents(deploymentEvents, wf, run, jobs)
    }
    return written
}

async function readCheckpoint(stateContainer, workflowFile) {
    try {
        const { resource } = await stateContainer
            .item(workflowFile, workflowFile)
            .read()
        return resource || null
    } catch (err) {
        if (err.code === 404) return null
        throw err
    }
}

async function processWorkflow(
    wf,
    pipelineMetrics,
    deploymentEvents,
    stateContainer,
) {
    const prevState = await readCheckpoint(stateContainer, wf.file)
    const prevLastRunId = prevState?.last_run_id || 0
    const sinceIso = prevState?.last_run_created_at || "2020-01-01T00:00:00Z"

    const workflowId = await getWorkflowId(wf.file)
    const candidateRuns = (await getRunsSince(workflowId, sinceIso)).filter(
        (r) => r.id > prevLastRunId,
    )

    let processed = 0
    let docsWritten = 0
    let newCheckpointRunId = prevLastRunId
    let newCheckpointCreatedAt = prevState?.last_run_created_at || sinceIso
    let checkpointBlocked = false

    for (const run of candidateRuns) {
        if (run.status !== "completed") {
            // A still-open run blocks the checkpoint from advancing past it, so it gets
            // picked up on a later poll once it finishes - but any completed run that
            // happens to appear after it in this same batch is still recorded now.
            checkpointBlocked = true
            continue
        }
        docsWritten += await processRun(
            wf,
            run,
            pipelineMetrics,
            deploymentEvents,
        )
        processed += 1
        if (!checkpointBlocked) {
            newCheckpointRunId = run.id
            newCheckpointCreatedAt = run.created_at
        }
    }

    if (newCheckpointRunId > prevLastRunId) {
        await stateContainer.items.upsert({
            id: wf.file,
            workflow: wf.file,
            workflow_id: workflowId,
            last_run_id: newCheckpointRunId,
            last_run_created_at: newCheckpointCreatedAt,
            updated_at: new Date().toISOString(),
        })
    }

    return {
        workflow: wf.file,
        service: wf.service,
        found: candidateRuns.length,
        processed,
        docsWritten,
    }
}

async function getCommitAuthoredAt(sha) {
    try {
        const data = await ghApi(`repos/${REPO}/commits/${sha}`)
        // Confirmed for real against this repo's actual history: author.date and
        // committer.date are identical for every merge commit checked (GitHub resets both to
        // the merge timestamp, not any earlier feature-branch commit time) - only a genuine
        // direct/non-merge commit preserves a genuinely distinct author.date. author.date is still the
        // textbook-correct DORA field regardless: it's the timestamp of the commit that
        // actually reached main, which for a merge-commit-based workflow like this project's
        // IS "when the change integrated" - not an individual developer's original per-commit
        // timestamp on a since-merged-and-deleted branch.
        return data.commit.author.date
    } catch (err) {
        // Confirmed for real: an invalid/unreachable SHA returns HTTP 422 ("No commit found
        // for SHA"), not 404 - can genuinely happen for force-pushed/rewritten history. One
        // bad historical record shouldn't crash the whole collector run.
        console.error(`  Could not fetch commit ${sha}: ${err.message}`)
        return null
    }
}

// One-time-per-document (idempotent) enrichment: DeploymentEvents is written with only
// commit_sha (an identifier), never the commit's own timestamp - Lead Time for Changes needs
// the latter. Re-running this is always safe and cheap: the query itself excludes documents
// that already have commit_authored_at, so an already-enriched document is never re-fetched.
async function backfillCommitTimestamps(deploymentEvents) {
    const { resources: docs } = await deploymentEvents.items
        .query(
            "SELECT * FROM c WHERE c.environment = 'production' AND IS_DEFINED(c.commit_sha) AND NOT IS_DEFINED(c.commit_authored_at)",
        )
        .fetchAll()

    let enriched = 0
    let notFound = 0
    for (const doc of docs) {
        const authoredAt = await getCommitAuthoredAt(doc.commit_sha)
        if (!authoredAt) {
            notFound += 1
            continue
        }
        // Patch, not upsert - this only ever adds the one new field, never touches or risks
        // clobbering anything else already on the document.
        await deploymentEvents
            .item(doc.id, doc.service)
            .patch([
                { op: "add", path: "/commit_authored_at", value: authoredAt },
            ])
        enriched += 1
    }
    return { enriched, notFound, total: docs.length }
}

// DORA metrics as CURRENT, recomputed-each-run values - a legitimate Pushgateway use (a
// short-lived batch job pushing the latest snapshot of a number), not history storage. History
// lives in Cosmos DB; Pushgateway only ever holds "as of the last collector run" values.
async function computeDora(deploymentEvents, service) {
    const sinceIso = new Date(
        Date.now() - DORA_WINDOW_DAYS * 24 * 60 * 60 * 1000,
    ).toISOString()
    const { resources: events } = await deploymentEvents.items
        .query({
            query: "SELECT * FROM c WHERE c.service = @service AND c.triggered_at >= @since",
            parameters: [
                { name: "@service", value: service },
                { name: "@since", value: sinceIso },
            ],
        })
        .fetchAll()

    const successes = events.filter((e) => e.eventType === "deploy_success")
    const failures = events.filter((e) => e.eventType === "deploy_failure")
    const rollbacks = events.filter((e) => e.eventType === "rollback")

    // Unlike changeFailureRate, this is never ambiguous at zero: it's a count divided by the
    // fixed window length, not by attempts, so "0 deploys/day" always means exactly that -
    // zero deploys happened - not "no data". No null-handling needed here.
    const deploymentFrequencyPerDay = successes.length / DORA_WINDOW_DAYS
    const attempts = successes.length + failures.length
    // null (not 0) when attempts is 0 - a real 0% failure rate (many successes, zero failures)
    // and "no deploy attempts at all in the window" are genuinely different outcomes, and 0
    // can't distinguish them. Same convention mttrSeconds already uses below.
    const changeFailureRate = safeRate(failures.length, attempts)

    let mttrSeconds = null
    if (rollbacks.length > 0) {
        const restoreDurations = rollbacks.map((r) => {
            const runId = r.id.replace(/-rollback$/, "")
            const failure = failures.find((f) => f.id === `${runId}-deploy`)
            const from = failure ? failure.completed_at : r.triggered_at
            return durationSeconds(from, r.completed_at)
        })
        mttrSeconds =
            restoreDurations.reduce((a, b) => a + b, 0) /
            restoreDurations.length
    }

    // Lead Time for Changes: every DeploymentEvents document is already production-only (this
    // container is only ever written from the *-production-promotion.yml workflows - staging
    // deploys land in PipelineMetrics instead, never here), but filtering by environment
    // explicitly rather than relying on that being true forever. completed_at (not
    // triggered_at) is "reached production" - triggered_at is when the promotion workflow
    // started, before the smoke test even ran; completed_at is when it was actually verified
    // live. commit_authored_at is populated by backfillCommitTimestamps() - a success without
    // it yet (not backfilled, or the commit lookup failed) is excluded rather than treated as 0.
    let leadTimeSeconds = null
    const productionSuccessesWithCommitData = successes.filter(
        (e) => e.environment === "production" && e.commit_authored_at,
    )
    if (productionSuccessesWithCommitData.length > 0) {
        const leadTimes = productionSuccessesWithCommitData
            .map((e) => durationSeconds(e.commit_authored_at, e.completed_at))
            .sort((a, b) => a - b)
        // Median, not mean: lead time is a classically skewed distribution (most changes ship
        // fast, occasional ones sit for days), and a single slow outlier would drag a mean up
        // in a way that misrepresents the typical case. Reusing percentile() at p50.
        leadTimeSeconds = percentile(leadTimes, 50)
    }

    return {
        deploymentFrequencyPerDay,
        changeFailureRate,
        mttrSeconds,
        leadTimeSeconds,
        sampleSize: attempts,
    }
}

async function pushDoraMetrics(service, dora) {
    if (!PUSHGATEWAY_URL) return false

    const lines = [
        "# TYPE dora_deployment_frequency_per_day gauge",
        `dora_deployment_frequency_per_day{service="${service}"} ${dora.deploymentFrequencyPerDay}`,
    ]
    if (dora.changeFailureRate !== null) {
        lines.push(
            "# TYPE dora_change_failure_rate gauge",
            `dora_change_failure_rate{service="${service}"} ${dora.changeFailureRate}`,
        )
    }
    if (dora.mttrSeconds !== null) {
        lines.push(
            "# TYPE dora_mttr_seconds gauge",
            `dora_mttr_seconds{service="${service}"} ${dora.mttrSeconds}`,
        )
    }
    if (dora.leadTimeSeconds !== null) {
        lines.push(
            "# TYPE dora_lead_time_seconds gauge",
            `dora_lead_time_seconds{service="${service}"} ${dora.leadTimeSeconds}`,
        )
    }
    lines.push("")

    // Grouped by instance=<service> so pushing a new snapshot for one service never wipes
    // another's. POST (not PUT) specifically: Pushgateway's POST only replaces metric families
    // with the SAME name already under this job/instance grouping key - other metric families
    // (e.g. the pipeline_job_* ones pushPipelineMetrics sends to this exact same grouping key)
    // are left untouched. PUT would wholesale-replace everything under the grouping key instead,
    // which would make the two pushes fight each other.
    const res = await fetch(
        `${PUSHGATEWAY_URL}/metrics/job/metrics-collector/instance/${service}`,
        {
            method: "POST",
            headers: { "Content-Type": "text/plain" },
            body: lines.join("\n"),
        },
    )
    if (!res.ok) {
        console.error(
            `Pushgateway push failed for ${service}: ${res.status} ${await res.text()}`,
        )
        return false
    }
    return true
}

// null (not 0) when there's nothing to compute a rate FROM - a real 0 and "no data" are
// different outcomes a bare division can't distinguish.
function safeRate(numerator, denominator) {
    return denominator > 0 ? numerator / denominator : null
}

// Pushgateway's POST can only ADD or REPLACE-BY-NAME metric families under a grouping key - it
// can never remove one that stops being pushed. Confirmed for real against the live instance:
// a metric pushed once and then omitted from a later POST simply lingers forever. So a field
// that goes from a real value to null (e.g. changeFailureRate with zero attempts) would leave
// its last real value stuck in Prometheus, silently wrong. Clearing the whole group first -
// confirmed safe to call even when the group doesn't exist yet (real 202, not a 404) - then
// re-pushing only what's currently true is the only way to make an absent metric actually
// disappear, not just stop growing.
async function clearPushgatewayGroup(service) {
    if (!PUSHGATEWAY_URL) return
    const res = await fetch(
        `${PUSHGATEWAY_URL}/metrics/job/metrics-collector/instance/${service}`,
        { method: "DELETE" },
    )
    if (!res.ok) {
        console.error(
            `Pushgateway group clear failed for ${service}: ${res.status} ${await res.text()}`,
        )
    }
}

function escapeLabelValue(value) {
    return value
        .replace(/\\/g, "\\\\")
        .replace(/"/g, '\\"')
        .replace(/\n/g, "\\n")
}

function percentile(sortedValues, p) {
    const idx = Math.ceil((p / 100) * sortedValues.length) - 1
    return sortedValues[Math.max(0, Math.min(idx, sortedValues.length - 1))]
}

// Same reasoning as computeDora's own comment: a recomputed-each-run snapshot of "current job
// health" is exactly the short-lived-batch-job pattern Pushgateway is for. History lives in
// PipelineMetrics itself; this just summarizes the trailing window on every collector run.
async function computePipelineMetrics(pipelineMetrics, service) {
    const sinceIso = new Date(
        Date.now() - PIPELINE_WINDOW_DAYS * 24 * 60 * 60 * 1000,
    ).toISOString()
    const { resources: docs } = await pipelineMetrics.items
        .query({
            query: "SELECT * FROM c WHERE c.service = @service AND c.started_at >= @since",
            parameters: [
                { name: "@service", value: service },
                { name: "@since", value: sinceIso },
            ],
        })
        .fetchAll()

    const byJob = new Map()
    for (const doc of docs) {
        // __workflow_total__ is a whole-run sentinel written by writeWorkflowTotalMetric(), not
        // a real job - excluded here so it never shows up as a fake "job" in the per-job
        // tables/trend panels. Its own aggregation lives in computeTotalPipelineMetrics().
        if (doc.job_name === "__workflow_total__") continue
        if (!byJob.has(doc.job_name)) byJob.set(doc.job_name, [])
        byJob.get(doc.job_name).push(doc)
    }

    const results = []
    for (const [jobName, jobDocs] of byJob) {
        const durations = jobDocs
            .map((d) => d.duration_seconds)
            .sort((a, b) => a - b)
        const successCount = jobDocs.filter(
            (d) => d.status === "success",
        ).length
        results.push({
            jobName,
            avgDurationSeconds:
                durations.reduce((a, b) => a + b, 0) / durations.length,
            p95DurationSeconds: percentile(durations, 95),
            successRate: successCount / jobDocs.length,
            sampleSize: jobDocs.length,
        })
    }
    return results
}

// Workflow-level wall-clock time (trigger to final completion), aggregated the same way as
// computePipelineMetrics()'s per-job durations (avg/p95 over the same rolling window) but
// queried separately rather than folded into that function's loop - keeps "no total-duration
// docs yet for this service" (null) cleanly distinguishable from "zero jobs ran either".
async function computeTotalPipelineMetrics(pipelineMetrics, service) {
    const sinceIso = new Date(
        Date.now() - PIPELINE_WINDOW_DAYS * 24 * 60 * 60 * 1000,
    ).toISOString()
    const { resources: docs } = await pipelineMetrics.items
        .query({
            query: "SELECT * FROM c WHERE c.service = @service AND c.job_name = '__workflow_total__' AND c.started_at >= @since",
            parameters: [
                { name: "@service", value: service },
                { name: "@since", value: sinceIso },
            ],
        })
        .fetchAll()

    if (docs.length === 0) return null

    const durations = docs.map((d) => d.duration_seconds).sort((a, b) => a - b)
    return {
        avgDurationSeconds:
            durations.reduce((a, b) => a + b, 0) / durations.length,
        p95DurationSeconds: percentile(durations, 95),
        sampleSize: docs.length,
    }
}

async function pushPipelineMetrics(service, jobMetrics) {
    if (!PUSHGATEWAY_URL) return false
    if (jobMetrics.length === 0) return true

    const metricLine = (name, m, value) =>
        `${name}{service="${service}",job_name="${escapeLabelValue(m.jobName)}"} ${value}`

    const lines = [
        "# TYPE pipeline_job_duration_avg_seconds gauge",
        ...jobMetrics.map((m) =>
            metricLine(
                "pipeline_job_duration_avg_seconds",
                m,
                m.avgDurationSeconds,
            ),
        ),
        "# TYPE pipeline_job_duration_p95_seconds gauge",
        ...jobMetrics.map((m) =>
            metricLine(
                "pipeline_job_duration_p95_seconds",
                m,
                m.p95DurationSeconds,
            ),
        ),
        "# TYPE pipeline_job_success_rate gauge",
        ...jobMetrics.map((m) =>
            metricLine("pipeline_job_success_rate", m, m.successRate),
        ),
        "",
    ]

    // Same grouping key as pushDoraMetrics (job=metrics-collector, instance=<service>) and same
    // POST method - the two pushes merge (different metric names), neither wipes the other.
    const res = await fetch(
        `${PUSHGATEWAY_URL}/metrics/job/metrics-collector/instance/${service}`,
        {
            method: "POST",
            headers: { "Content-Type": "text/plain" },
            body: lines.join("\n"),
        },
    )
    if (!res.ok) {
        console.error(
            `Pushgateway push failed for ${service} (pipeline metrics): ${res.status} ${await res.text()}`,
        )
        return false
    }
    return true
}

// null (not a push of nothing) when there are no __workflow_total__ docs yet in the window -
// same reasoning as pushDoraMetrics's null-skip fields, so a service with no data doesn't get a
// stale or fabricated value sitting in Prometheus.
async function pushTotalPipelineMetric(service, totalMetrics) {
    if (!PUSHGATEWAY_URL) return false
    if (!totalMetrics) return true

    const lines = [
        "# TYPE pipeline_total_duration_avg_seconds gauge",
        `pipeline_total_duration_avg_seconds{service="${service}"} ${totalMetrics.avgDurationSeconds}`,
        "# TYPE pipeline_total_duration_p95_seconds gauge",
        `pipeline_total_duration_p95_seconds{service="${service}"} ${totalMetrics.p95DurationSeconds}`,
        "",
    ]

    // Same grouping key as pushPipelineMetrics/pushDoraMetrics - merges rather than conflicts.
    const res = await fetch(
        `${PUSHGATEWAY_URL}/metrics/job/metrics-collector/instance/${service}`,
        {
            method: "POST",
            headers: { "Content-Type": "text/plain" },
            body: lines.join("\n"),
        },
    )
    if (!res.ok) {
        console.error(
            `Pushgateway push failed for ${service} (total pipeline duration): ${res.status} ${await res.text()}`,
        )
        return false
    }
    return true
}

async function main() {
    if (!REPO) throw new Error("GITHUB_REPOSITORY must be set")
    if (!GH_TOKEN) throw new Error("GH_TOKEN must be set")
    if (!COSMOS_ENDPOINT) throw new Error("COSMOS_ENDPOINT must be set")

    const client = new CosmosClient({
        endpoint: COSMOS_ENDPOINT,
        aadCredentials: credential(),
    })
    const db = client.database(COSMOS_DATABASE)
    const pipelineMetrics = db.container("PipelineMetrics")
    const deploymentEvents = db.container("DeploymentEvents")
    const stateContainer = db.container("CollectorState")

    const backfill = await backfillCommitTimestamps(deploymentEvents)
    console.log(
        `Commit timestamp backfill: ${backfill.enriched}/${backfill.total} production deploy record(s) enriched` +
            (backfill.notFound > 0
                ? ` (${backfill.notFound} commit(s) could not be found)`
                : ""),
    )

    const results = []
    for (const wf of WORKFLOWS) {
        results.push(
            await processWorkflow(
                wf,
                pipelineMetrics,
                deploymentEvents,
                stateContainer,
            ),
        )
    }

    const totalFound = results.reduce((s, r) => s + r.found, 0)
    const totalProcessed = results.reduce((s, r) => s + r.processed, 0)
    const totalDocsWritten = results.reduce((s, r) => s + r.docsWritten, 0)

    console.log("=== Collector run summary ===")
    for (const r of results) {
        console.log(
            `  ${r.workflow}: ${r.found} new run(s) found, ${r.processed} completed and processed, ${r.docsWritten} document(s) written`,
        )
    }

    if (totalFound === 0) {
        console.log("Nothing new since last run - exiting cleanly.")
    } else {
        console.log(
            `Total: ${totalProcessed}/${totalFound} new runs processed, ${totalDocsWritten} documents written.`,
        )
    }

    if (!PUSHGATEWAY_URL) {
        console.log(
            "PUSHGATEWAY_URL not set - skipping DORA/pipeline metric push (no Pushgateway deployed yet).",
        )
    } else {
        const services = [...new Set(WORKFLOWS.map((w) => w.service))]
        for (const service of services) {
            await clearPushgatewayGroup(service)

            const dora = await computeDora(deploymentEvents, service)
            const doraPushed = await pushDoraMetrics(service, dora)
            console.log(
                `  DORA snapshot for ${service}: ${JSON.stringify(dora)} (pushed: ${doraPushed})`,
            )

            const jobMetrics = await computePipelineMetrics(
                pipelineMetrics,
                service,
            )
            const pipelinePushed = await pushPipelineMetrics(
                service,
                jobMetrics,
            )
            console.log(
                `  Pipeline metrics for ${service}: ${jobMetrics.length} job(s) (pushed: ${pipelinePushed})`,
            )

            const totalMetrics = await computeTotalPipelineMetrics(
                pipelineMetrics,
                service,
            )
            const totalPushed = await pushTotalPipelineMetric(
                service,
                totalMetrics,
            )
            console.log(
                `  Total pipeline duration for ${service}: ${JSON.stringify(totalMetrics)} (pushed: ${totalPushed})`,
            )
        }
    }
}

if (require.main === module) {
    main().catch((err) => {
        console.error(err)
        process.exit(1)
    })
}

module.exports = { durationSeconds, percentile, escapeLabelValue, safeRate }

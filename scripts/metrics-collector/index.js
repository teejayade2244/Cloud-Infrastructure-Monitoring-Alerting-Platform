#!/usr/bin/env node
"use strict"

const AdmZip = require("adm-zip")
const { CosmosClient } = require("@azure/cosmos")
const { DefaultAzureCredential } = require("@azure/identity")

const REPO = process.env.GITHUB_REPOSITORY
const GH_TOKEN = process.env.GH_TOKEN
const COSMOS_ENDPOINT = process.env.COSMOS_ENDPOINT
const COSMOS_DATABASE = process.env.COSMOS_METRICS_DATABASE || "InfraMonitorMetricsDB"
const AZURE_CLIENT_ID = process.env.AZURE_CLIENT_ID
const PUSHGATEWAY_URL = process.env.PUSHGATEWAY_URL?.trim() || ""
const DORA_WINDOW_DAYS = 30

// Every workflow this collector reads history from. deploy-frontend.yml and terraform.yml are
// deliberately excluded - they're unrelated to the three services' DORA/pipeline metrics.
const WORKFLOWS = [
    { file: "events-service-ci.yml", service: "events-service", kind: "ci" },
    { file: "events-service-production-promotion.yml", service: "events-service", kind: "promotion" },
    { file: "incidents-service-ci.yml", service: "incidents-service", kind: "ci" },
    { file: "incidents-service-production-promotion.yml", service: "incidents-service", kind: "promotion" },
    { file: "create-incident-job-ci.yml", service: "create-incident-job", kind: "ci" },
    { file: "create-incident-job-production-promotion.yml", service: "create-incident-job", kind: "promotion" },
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
        throw new Error(`GitHub API ${path} failed: ${res.status} ${await res.text()}`)
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
        const data = await ghApi(`repos/${REPO}/actions/runs/${runId}/jobs?per_page=100&page=${page}`)
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
    const artifact = data.artifacts.find((a) => a.name === "smoke-test-evidence-production")
    if (!artifact) return null

    const res = await fetch(`https://api.github.com/repos/${REPO}/actions/artifacts/${artifact.id}/zip`, {
        headers: { Authorization: `Bearer ${GH_TOKEN}` },
    })
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
    return (new Date(completedAt).getTime() - new Date(startedAt).getTime()) / 1000
}

async function writePipelineMetrics(container, wf, run, jobs) {
    let written = 0
    for (const job of jobs) {
        if (job.conclusion !== "success" && job.conclusion !== "failure") continue
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

async function writeDeploymentEvents(container, wf, run, jobs) {
    const findJob = (needle) => jobs.find((j) => j.name.includes(needle))
    const promote = findJob("Promote to production")
    const smoke = findJob("Smoke Test (production)")
    const rollback = findJob("Rollback production")

    const promotionSucceeded = Boolean(promote && promote.conclusion === "success")
    // No image was ever promoted if promote-to-production didn't succeed - image_tag is
    // genuinely unavailable then, not just unrecovered (and smoke-test-production, the only
    // source of the evidence artifact, never even runs in that case).
    const imageTag = promotionSucceeded ? await getPromotedImageTag(run.id) : null
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
    if (wf.kind === "promotion") {
        written += await writeDeploymentEvents(deploymentEvents, wf, run, jobs)
    }
    return written
}

async function readCheckpoint(stateContainer, workflowFile) {
    try {
        const { resource } = await stateContainer.item(workflowFile, workflowFile).read()
        return resource || null
    } catch (err) {
        if (err.code === 404) return null
        throw err
    }
}

async function processWorkflow(wf, pipelineMetrics, deploymentEvents, stateContainer) {
    const prevState = await readCheckpoint(stateContainer, wf.file)
    const prevLastRunId = prevState?.last_run_id || 0
    const sinceIso = prevState?.last_run_created_at || "2020-01-01T00:00:00Z"

    const workflowId = await getWorkflowId(wf.file)
    const candidateRuns = (await getRunsSince(workflowId, sinceIso)).filter((r) => r.id > prevLastRunId)

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
        docsWritten += await processRun(wf, run, pipelineMetrics, deploymentEvents)
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

    return { workflow: wf.file, service: wf.service, found: candidateRuns.length, processed, docsWritten }
}

// DORA metrics as CURRENT, recomputed-each-run values - a legitimate Pushgateway use (a
// short-lived batch job pushing the latest snapshot of a number), not history storage. History
// lives in Cosmos DB; Pushgateway only ever holds "as of the last collector run" values.
async function computeDora(deploymentEvents, service) {
    const sinceIso = new Date(Date.now() - DORA_WINDOW_DAYS * 24 * 60 * 60 * 1000).toISOString()
    const { resources: events } = await deploymentEvents.items
        .query({
            query:
                "SELECT * FROM c WHERE c.service = @service AND c.triggered_at >= @since",
            parameters: [
                { name: "@service", value: service },
                { name: "@since", value: sinceIso },
            ],
        })
        .fetchAll()

    const successes = events.filter((e) => e.eventType === "deploy_success")
    const failures = events.filter((e) => e.eventType === "deploy_failure")
    const rollbacks = events.filter((e) => e.eventType === "rollback")

    const deploymentFrequencyPerDay = successes.length / DORA_WINDOW_DAYS
    const attempts = successes.length + failures.length
    const changeFailureRate = attempts > 0 ? failures.length / attempts : 0

    let mttrSeconds = null
    if (rollbacks.length > 0) {
        const restoreDurations = rollbacks.map((r) => {
            const runId = r.id.replace(/-rollback$/, "")
            const failure = failures.find((f) => f.id === `${runId}-deploy`)
            const from = failure ? failure.completed_at : r.triggered_at
            return durationSeconds(from, r.completed_at)
        })
        mttrSeconds = restoreDurations.reduce((a, b) => a + b, 0) / restoreDurations.length
    }

    return { deploymentFrequencyPerDay, changeFailureRate, mttrSeconds, sampleSize: attempts }
}

async function pushDoraMetrics(service, dora) {
    if (!PUSHGATEWAY_URL) return false

    const lines = [
        "# TYPE dora_deployment_frequency_per_day gauge",
        `dora_deployment_frequency_per_day{service="${service}"} ${dora.deploymentFrequencyPerDay}`,
        "# TYPE dora_change_failure_rate gauge",
        `dora_change_failure_rate{service="${service}"} ${dora.changeFailureRate}`,
    ]
    if (dora.mttrSeconds !== null) {
        lines.push("# TYPE dora_mttr_seconds gauge", `dora_mttr_seconds{service="${service}"} ${dora.mttrSeconds}`)
    }
    lines.push("")

    // Grouped by instance=<service> so pushing a new snapshot for one service never wipes
    // another's - Pushgateway replaces everything under the exact job/instance grouping key
    // on each push, not just the metric names present in this payload.
    const res = await fetch(`${PUSHGATEWAY_URL}/metrics/job/metrics-collector/instance/${service}`, {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: lines.join("\n"),
    })
    if (!res.ok) {
        console.error(`Pushgateway push failed for ${service}: ${res.status} ${await res.text()}`)
        return false
    }
    return true
}

async function main() {
    if (!REPO) throw new Error("GITHUB_REPOSITORY must be set")
    if (!GH_TOKEN) throw new Error("GH_TOKEN must be set")
    if (!COSMOS_ENDPOINT) throw new Error("COSMOS_ENDPOINT must be set")

    const client = new CosmosClient({ endpoint: COSMOS_ENDPOINT, aadCredentials: credential() })
    const db = client.database(COSMOS_DATABASE)
    const pipelineMetrics = db.container("PipelineMetrics")
    const deploymentEvents = db.container("DeploymentEvents")
    const stateContainer = db.container("CollectorState")

    const results = []
    for (const wf of WORKFLOWS) {
        results.push(await processWorkflow(wf, pipelineMetrics, deploymentEvents, stateContainer))
    }

    const totalFound = results.reduce((s, r) => s + r.found, 0)
    const totalProcessed = results.reduce((s, r) => s + r.processed, 0)
    const totalDocsWritten = results.reduce((s, r) => s + r.docsWritten, 0)

    console.log("=== Collector run summary ===")
    for (const r of results) {
        console.log(`  ${r.workflow}: ${r.found} new run(s) found, ${r.processed} completed and processed, ${r.docsWritten} document(s) written`)
    }

    if (totalFound === 0) {
        console.log("Nothing new since last run - exiting cleanly.")
    } else {
        console.log(`Total: ${totalProcessed}/${totalFound} new runs processed, ${totalDocsWritten} documents written.`)
    }

    if (!PUSHGATEWAY_URL) {
        console.log("PUSHGATEWAY_URL not set - skipping DORA metric push (no Pushgateway deployed yet).")
    } else {
        const services = [...new Set(WORKFLOWS.map((w) => w.service))]
        for (const service of services) {
            const dora = await computeDora(deploymentEvents, service)
            const pushed = await pushDoraMetrics(service, dora)
            console.log(`  DORA snapshot for ${service}: ${JSON.stringify(dora)} (pushed: ${pushed})`)
        }
    }
}

main().catch((err) => {
    console.error(err)
    process.exit(1)
})

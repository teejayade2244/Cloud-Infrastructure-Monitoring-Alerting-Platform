FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev

FROM node:20-alpine AS runtime
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# npm itself is never invoked at runtime (only `node server.js` is) - its bundled internal
# dependencies inside the base image (tar, sigstore, cross-spawn, glob, minimatch, etc.) are a
# well-known source of unrelated CVE noise when scanning node:*-alpine images. apk upgrade picks
# up any Alpine OS package security patches published since this base image tag was last built.
RUN apk update && apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "server.js"]
FROM node:20-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev

FROM node:20-alpine AS runtime
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NODE_ENV=production
# Overridden per Container Apps Job via the `command` field in Terraform - this is just a
# sane default for running the image directly.
CMD ["node", "src/create-incident.js"]

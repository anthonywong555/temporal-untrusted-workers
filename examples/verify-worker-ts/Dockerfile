# @temporalio/core-bridge ships prebuilt native (napi-rs) binaries only for
# glibc targets (aarch64/x86_64-unknown-linux-gnu, among others) - no musl
# build exists, so this must be a glibc-based (Debian) image, never Alpine.
FROM node:lts-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build
RUN npm run build:workflow

FROM node:lts-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    BUILD_ID=${BUILD_ID} \
    DEPLOYMENT_NAME=${DEPLOYMENT_NAME} \
    VERIFY_TASK_QUEUE=${VERIFY_TASK_QUEUE} 

COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/lib ./lib
COPY --from=build /app/workflow-bundle.js ./workflow-bundle.js
RUN apt-get update \
    && apt-get install -y ca-certificates \
    && rm -rf /var/lib/apt/lists/*
USER node
ENTRYPOINT ["node", "lib/worker.js"]

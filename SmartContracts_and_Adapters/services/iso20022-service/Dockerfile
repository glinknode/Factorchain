# ---- Build deps layer ----
FROM node:20-alpine AS deps
WORKDIR /app
# Only copy the manifest to leverage Docker layer cache
COPY package.json .
# Install only production deps (works even without a lockfile)
RUN npm install --omit=dev

# ---- Runtime image ----
FROM node:20-alpine
WORKDIR /app

# Environment (tune at runtime via docker-compose or `docker run -e`)
ENV NODE_ENV=production \
    PORT=18887 \
    JSON_LIMIT=1mb \
    ALLOWED_ORIGINS= \
    LOG_LEVEL=info \
    LOG_BODY=0 \
    LOG_PRETTY=0 \
    LOG_SUMMARY_INTERVAL=30 \
    LOG_BODY_PREVIEW_LIMIT=800

# Copy node_modules from deps layer and the app file
COPY --from=deps /app/node_modules ./node_modules
COPY server.js ./iso20022-adapter-public.js

# Non-root user for safety
RUN addgroup -S app && adduser -S app -G app
USER app

EXPOSE 18887

# Simple healthcheck
HEALTHCHECK --interval=30s --timeout=3s --retries=5 \
  CMD wget -qO- http://localhost:18887/healthz || exit 1

CMD ["node", "iso20022-adapter-public.js"]

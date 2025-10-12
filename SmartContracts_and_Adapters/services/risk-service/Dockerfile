# ---- deps layer ----
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

# ---- runtime ----
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production \
    PORT=18888 \
    JSON_LIMIT=256kb \
    ALLOWED_ORIGINS= \
    LOG_LEVEL=info \
    LOG_BODY=0 \
    LOG_PRETTY=0 \
    LOG_SUMMARY_INTERVAL=30 \
    LOG_BODY_PREVIEW_LIMIT=800

COPY --from=deps /app/node_modules ./node_modules
COPY risk-adapter-public.js ./risk-adapter-public.js

# run as non-root
RUN addgroup -S app && adduser -S app -G app
USER app

EXPOSE 18888

HEALTHCHECK --interval=30s --timeout=3s --retries=5 \
  CMD wget -qO- http://localhost:18888/healthz || exit 1

CMD ["node", "risk-adapter-public.js"]

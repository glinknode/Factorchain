# ---------- builder stage ----------
FROM node:20-alpine AS builder
WORKDIR /app

# Tools required to install from GitHub and build native deps (if any)
RUN apk add --no-cache git python3 make g++

# Copy manifest first for better layer caching
COPY package.json package-lock.json* ./

# Install dependencies (lockfile preferred)
RUN if [ -f package-lock.json ]; then \
      npm ci ; \
    else \
      npm i ; \
    fi

# Compile TS → JS
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Keep only production deps to copy into the runtime image
RUN npm prune --omit=dev


# ---------- runtime stage ----------
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production TZ=UTC

# Copy production dependencies and app files from builder
COPY --from=builder /app/package.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist

# Non-root user
RUN addgroup -S nodeapp && adduser -S nodeapp -G nodeapp \
 && chown -R nodeapp:nodeapp /app
USER nodeapp

EXPOSE 18882

# Simple healthcheck using Node's built-in fetch (Node 20+)
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "const p=process.env.PORT||18882; fetch('http://127.0.0.1:'+p+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1));"

CMD ["node", "dist/index.js"]
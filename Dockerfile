# ─── Quenderin — Multi-stage Docker build ────────────────────────────────────
# Runs the dashboard (web UI + backend) in headless mode.
# Suitable for x86_64 and ARM64 hosts (Raspberry Pi 4+, cloud VMs, etc.)
#
# Build:   docker build -t quenderin .
# Run:     docker run -p 3000:3000 -v quenderin-models:/root/.quenderin quenderin
# With GPU: docker run --gpus all -p 3000:3000 -v quenderin-models:/root/.quenderin quenderin

# ─── Stage 1: Build ──────────────────────────────────────────────────────────
FROM node:20-slim AS builder

WORKDIR /app

# Install build deps for native modules (node-llama-cpp, tesseract, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ cmake git \
    && rm -rf /var/lib/apt/lists/*

# Copy package files first for better layer caching
COPY package.json package-lock.json* ./
COPY ui/package.json ui/package-lock.json* ./ui/

# Install backend deps (optional deps may fail on some arches — that's fine)
RUN npm install --ignore-scripts=false || true
RUN cd ui && npm install

# Copy source
COPY . .

# Build TypeScript backend + React frontend
RUN npx tsc || true
RUN cd ui && npx vite build

# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM node:20-slim AS runtime

WORKDIR /app

# Minimal runtime deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy built artifacts
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/ui/dist ./ui/dist
COPY --from=builder /app/public ./public
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

# Container environment markers
ENV QUENDERIN_CONTAINER=1
ENV QUENDERIN_NO_BROWSER=1
ENV BROWSER=none
ENV NODE_ENV=production

# Constrain Node.js memory to prevent container OOM kills.
# Override with: docker run -e NODE_OPTIONS="--max-old-space-size=1024" ...
ENV NODE_OPTIONS="--max-old-space-size=512"

# Model storage — mount a volume here to persist models across restarts
VOLUME /root/.quenderin

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD node -e "fetch('http://localhost:3000/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"

CMD ["node", "dist/src/index.js", "dashboard", "--port", "3000", "--no-open"]

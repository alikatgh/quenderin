# ─── Quenderin — Multi-stage Docker build ────────────────────────────────────
# Runs the dashboard (web UI + backend) in headless mode.
# Suitable for x86_64 and ARM64 hosts (Raspberry Pi 4+, cloud VMs, etc.)
#
# Build:   docker build -t quenderin .
# Run:     docker run -p 3000:3000 -v quenderin-models:/home/app/.quenderin quenderin
#          then `docker logs <container>` and open the printed ?token= URL (auth is per-launch).
# With GPU: docker run --gpus all -p 3000:3000 -v quenderin-models:/home/app/.quenderin quenderin

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

# Install deps from the lockfiles. NOTE: no `|| true` — npm already treats optionalDependencies
# failures as warnings, so the old `|| true` only masked REAL failures (r19: a container that
# "built" with missing required deps died at runtime instead of at build time).
RUN npm ci
RUN cd ui && npm ci

# Copy source
COPY . .

# Build TypeScript backend + React frontend. Strict: a tsc error must FAIL the image build —
# the old `|| true` let a broken compile ship a stale/missing dist/ (false-green build, r19).
RUN npx tsc
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

# Drop root (audit MEDIUM: runtime ran as root). Create an unprivileged user, give it the app dir
# and its model-storage home, then switch to it before launching — a container breakout or RCE then
# lands as uid 10001, not root.
RUN useradd -m -u 10001 -s /usr/sbin/nologin app \
    && mkdir -p /home/app/.quenderin \
    && chown -R app:app /app /home/app/.quenderin
USER app

# Container environment markers
ENV QUENDERIN_CONTAINER=1
ENV QUENDERIN_NO_BROWSER=1
ENV BROWSER=none
ENV NODE_ENV=production
# Bind all interfaces INSIDE the container — the server's loopback default made the documented
# `docker run -p 3000:3000` unreachable (the port mapping targets eth0, not 127.0.0.1) (r19).
# Isolation still comes from Docker networking; auth still comes from the per-launch token,
# which is printed in `docker logs` as the "Open this URL to connect" line.
ENV QUENDERIN_HOST=0.0.0.0

# Constrain Node.js memory to prevent container OOM kills.
# Override with: docker run -e NODE_OPTIONS="--max-old-space-size=1024" ...
ENV NODE_OPTIONS="--max-old-space-size=512"

# Model storage — mount a volume here to persist models across restarts (owned by the non-root user)
VOLUME /home/app/.quenderin

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD node -e "fetch('http://localhost:3000/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"

CMD ["node", "dist/src/index.js", "dashboard", "--port", "3000", "--no-open"]

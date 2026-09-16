# syntax=docker/dockerfile:1
#
# Build context must be the MONOREPO ROOT, not backend/, so that the pnpm
# workspace manifest and lockfile are visible, e.g.:
#   docker build -f backend/Dockerfile .
#
# Note on dependencies: the final runtime image intentionally keeps the full
# (prod + dev) node_modules rather than a --prod-only install. The
# `migrate` service in docker-compose.prod.yml reuses this same image and
# runs `npx drizzle-kit migrate`, and drizzle-kit is a devDependency of the
# backend package. Keeping one install across all stages guarantees the
# migrate job runs the exact pinned drizzle-kit version, with no network
# fetch, instead of depending on npx falling back to a registry install.

###############################################################################
# Stage 1: Install dependencies (whole workspace, frozen lockfile)
###############################################################################
FROM node:22-alpine AS deps
WORKDIR /app

# bcrypt has a native addon that needs a build toolchain on Alpine
RUN apk add --no-cache python3 make g++

RUN corepack enable && corepack prepare pnpm@12.4.2 --activate

# Copy only what's needed to resolve the workspace and install deps, so this
# layer stays cached until a manifest or the lockfile actually changes.
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY backend/package.json ./backend/package.json
COPY packages/shared/package.json ./packages/shared/package.json

# --filter ...backend... limits the install to the backend package and its
# workspace dependencies. The repo's lockfile still carries leftover entries
# from an old Expo client workspace member that no longer exists on disk;
# without the filter, a plain `pnpm install` resolves the entire lockfile
# and pulls those in too.
RUN pnpm install --frozen-lockfile --filter @health-monitor/backend...

###############################################################################
# Stage 2: Build TypeScript
###############################################################################
FROM node:22-alpine AS builder
WORKDIR /app

RUN corepack enable && corepack prepare pnpm@12.4.2 --activate

# Bring over the already-resolved node_modules (root + workspace packages)
COPY --from=deps /app ./

# Now layer in the real source
COPY packages/shared ./packages/shared
COPY backend ./backend

WORKDIR /app/backend
RUN pnpm build

###############################################################################
# Stage 3: Production runtime
###############################################################################
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production

# Don't run as root
RUN addgroup -S nodejs && adduser -S nodejs -G nodejs

# Root node_modules holds the pnpm content-addressable store (.pnpm) that
# backend/node_modules symlinks into — both must travel together.
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nodejs:nodejs /app/backend ./backend

WORKDIR /app/backend
USER nodejs

EXPOSE 3000

CMD ["node", "dist/server.js"]

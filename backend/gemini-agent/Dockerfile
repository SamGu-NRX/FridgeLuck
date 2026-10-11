# Stage 1 — build toolchain: Bun + the full (dev + prod) dependency set,
# used only for the TypeScript build. Nothing from this stage ships.
FROM oven/bun:1.3.10 AS build
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY tsconfig.json ./
COPY src ./src
RUN bun run build

# Stage 2 — production dependencies only (no devDependencies, no build tooling).
FROM oven/bun:1.3.10 AS prod-deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

# Stage 3 — runtime: Node 24 "Krypton" slim, Active LTS per the official
# Node.js release table (maintenance until 2028-04-30). Node 20 went
# end-of-life on 2026-04-30 and is no longer security-patched.
FROM node:24-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
EXPOSE 8080
# Run as the image's built-in non-root "node" user (uid/gid 1000).
USER node
CMD ["node", "dist/server.js"]

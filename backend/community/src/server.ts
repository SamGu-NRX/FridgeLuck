/**
 * The community backend server (SPEC §7). Boots the app, discovers modules
 * from src/modules/<name>/index.ts, mounts their routers under /v1, and answers
 * GET /healthz like gemini-agent.
 */

import { buildApp } from "./app.js";

const app = await buildApp();

const server = Bun.serve({
  port: app.config.port,
  fetch: (request) => app.handle(request),
});

console.log(`@fridgeluck/community listening on :${server.port} (store=${app.config.store}, modules=${app.modules.map((m) => m.name).join(", ")})`);

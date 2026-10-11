/**
 * The community module's one mountable surface.
 *
 * A later integration task owns server.ts and mounts this exactly once:
 *   app.use(createCommunityRouter(deps))
 *
 * Nothing here reads server.ts or edits other backend files. Part modules
 * export their own router factories; this file is the only place they are
 * wired together, so the composition (who enforces blocks, who feeds the
 * moderation queue) is provable in one place — suite E.
 */
import { Router, type NextFunction, type Request, type Response, type Router as ExpressRouter } from "express";
import type { CommunityStore } from "./shared/store.js";
import type { BlockDirectory, ModerationQueue, ScreeningStage } from "./shared/contracts.js";
import type { Clock } from "./shared/time.js";
import type { CommunityConfig } from "./config.js";
import { SessionService } from "./shared/sessionCore.js";
import { requireAccount } from "./shared/auth.js";
import { isCommunityError } from "./shared/errors.js";
import { mustCommunity, route } from "./shared/http.js";

export interface CommunityDeps {
  readonly store: CommunityStore;
  readonly clock: Clock;
  readonly config: CommunityConfig;
  /** Real implementation from the safety part; wired by the parent join. */
  readonly blocks: BlockDirectory;
  /** Real implementation from the safety part; wired by the parent join. */
  readonly moderation: ModerationQueue;
  /** Automated screening stages: text checks always; linter/allergens when present. */
  readonly screeningStages: readonly ScreeningStage[];
}

/** Parts' router factories (landed by their own tasks, wired here). */
export interface CommunityPartRouters {
  identity?: (deps: CommunityDeps, runtime: CommunityRuntime) => ExpressRouter;
}

export interface CommunityRuntime {
  readonly sessions: SessionService;
  readonly requireAccount: ReturnType<typeof requireAccount>;
}

export function createCommunitySessionRuntime(deps: CommunityDeps): CommunityRuntime {
  const sessions = new SessionService({
    sessions: deps.store.sessions,
    firestore: deps.store.firestore,
    config: {
      sessionSecret: deps.config.sessionSecret ?? "emulator-only-secret",
      accessTtlMinutes: deps.config.accessTtlMinutes,
      refreshTtlDays: deps.config.refreshTtlDays,
    },
  });
  return { sessions, requireAccount: requireAccount({ sessions, clock: deps.clock }) };
}

export function createCommunityRouter(deps: CommunityDeps, parts: CommunityPartRouters = {}): ExpressRouter {
  const runtime = createCommunitySessionRuntime(deps);
  const router = Router();

  router.get("/v1/community/healthz", (_req, res) => {
    res.json({ ok: true, module: "community" });
  });

  // Session self-inspection: proves the account boundary end to end. The
  // account id comes from the verified token + live session, never the caller.
  router.get(
    "/v1/community/whoami",
    runtime.requireAccount,
    route(async (req, res) => {
      const ctx = mustCommunity(req);
      res.json({ accountId: ctx.accountId, sessionId: ctx.sessionId });
    }),
  );

  // Part routers are mounted here as the parent join merges them.
  if (parts.identity !== undefined) {
    router.use(parts.identity(deps, runtime));
  }

  // The error boundary: middleware-thrown CommunityErrors (requireAccount)
  // and anything a part lets escape become the module error envelope.
  router.use((err: unknown, _req: Request, res: Response, next: NextFunction) => {
    if (res.headersSent) {
      next(err);
      return;
    }
    if (isCommunityError(err)) {
      res.status(err.status).json({ error: err.message, code: err.code });
      return;
    }
    res.status(500).json({ error: "internal error", code: "internal" });
  });

  router.use("/v1/community", (req, res) => {
    res.status(404).json({ error: "unknown community route", code: "not_found", path: req.path });
  });

  return router;
}

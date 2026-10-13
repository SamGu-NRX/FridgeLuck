import type { NextFunction, Request, Response } from "express";

// Bounded, expiring, per-IP token buckets for paid-model routes.
//
// IMPORTANT — what this is and is not:
// - This is per-instance cost containment for expensive model calls. It is NOT
//   authentication, NOT abuse protection in depth, and NOT a quota system:
//   distributed clients, IPv6 rotation, or multiple instances each get their
//   own budget. Real access control must exist elsewhere.
// - The bucket key is the TCP peer address (`req.socket.remoteAddress`).
//   `X-Forwarded-For` and friends are deliberately IGNORED: arbitrary clients
//   can set forwarded headers, so trusting them would make the limiter
//   trivially bypassable. The flip side is documented too: on platforms where
//   the TLS terminator presents a shared proxy address, all clients share one
//   bucket per instance; tune RATE_LIMIT_MAX_REQUESTS /
//   RATE_LIMIT_WINDOW_SECONDS for that deployment.
//
// Memory is bounded: at most `maxTrackedClients` buckets exist at once, idle
// buckets expire after one window, and the map is pruned under pressure.

export interface IpRateLimiterOptions {
  /** Bucket capacity; refills continuously over the window. */
  capacity: number;
  /** Seconds over which an empty bucket fully refills. */
  windowSeconds: number;
  /** Maximum simultaneously tracked client buckets (memory bound). */
  maxTrackedClients: number;
}

export interface RateLimitDecision {
  allowed: boolean;
  retryAfterSeconds: number;
}

interface Bucket {
  tokens: number;
  updatedAtMs: number;
}

export interface IpRateLimiter {
  readonly options: IpRateLimiterOptions;
  middleware(req: Request, res: Response, next: NextFunction): void;
  /** Direct bucket probe (used by tests). */
  take(clientKey: string, nowMs: number): RateLimitDecision;
  /** Number of live buckets (used by tests to assert the bound). */
  size(): number;
}

export function createIpRateLimiter(
  options: IpRateLimiterOptions,
  nowMs: () => number = Date.now
): IpRateLimiter {
  const capacity = Math.max(1, Math.floor(options.capacity));
  const windowSeconds = Math.max(1, Math.floor(options.windowSeconds));
  const maxTrackedClients = Math.max(1, Math.floor(options.maxTrackedClients));
  const windowMs = windowSeconds * 1000;
  const refillPerMs = capacity / windowMs;

  const buckets = new Map<string, Bucket>();

  const prune = (now: number): void => {
    for (const [key, bucket] of buckets) {
      if (now - bucket.updatedAtMs > windowMs) {
        buckets.delete(key);
      }
    }
    if (buckets.size >= maxTrackedClients) {
      // Drop the least-recently-updated buckets until under the bound.
      const oldest = [...buckets.entries()].sort(
        (a, b) => a[1].updatedAtMs - b[1].updatedAtMs
      );
      for (let i = 0; i < oldest.length && buckets.size >= maxTrackedClients; i++) {
        buckets.delete(oldest[i][0]);
      }
    }
  };

  const take = (clientKey: string, now: number): RateLimitDecision => {
    if (buckets.size >= maxTrackedClients) {
      prune(now);
    }

    let bucket = buckets.get(clientKey);
    if (!bucket || now - bucket.updatedAtMs > windowMs) {
      bucket = { tokens: capacity, updatedAtMs: now };
    } else {
      bucket.tokens = Math.min(capacity, bucket.tokens + (now - bucket.updatedAtMs) * refillPerMs);
    }
    bucket.updatedAtMs = now;

    if (bucket.tokens < 1) {
      const deficitMs = (1 - bucket.tokens) / refillPerMs;
      buckets.set(clientKey, bucket);
      return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(deficitMs / 1000)) };
    }

    bucket.tokens -= 1;
    buckets.set(clientKey, bucket);
    return { allowed: true, retryAfterSeconds: 0 };
  };

  const middleware = (req: Request, res: Response, next: NextFunction): void => {
    const now = nowMs();
    // Deliberately ignore forwarded headers; see the file comment above.
    const clientKey = req.socket.remoteAddress ?? "unknown";
    const decision = take(clientKey, now);

    if (decision.allowed) {
      next();
      return;
    }

    const locals = res.locals as { requestId?: string; errorCode?: string };
    locals.errorCode = "rate_limited";
    res.setHeader("Retry-After", String(decision.retryAfterSeconds));
    res.status(429).json({
      error: "rate_limited",
      retryAfterSeconds: decision.retryAfterSeconds,
      ...(locals.requestId ? { requestId: locals.requestId } : {})
    });
  };

  return { options, middleware, take, size: () => buckets.size };
}

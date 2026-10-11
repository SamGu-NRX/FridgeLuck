import { OAuth2Client } from "google-auth-library";
import type { LoginTicket } from "google-auth-library";

type IdTokenPayload = NonNullable<ReturnType<LoginTicket["getPayload"]>>;

/**
 * OIDC authentication for the FridgeLuck webhook endpoints triggered by
 * Google Cloud Scheduler / Cloud Tasks.
 *
 * Production verifies signed OIDC ID tokens from the `Bearer` Authorization
 * header with google-auth-library's OAuth2Client.verifyIdToken, then requires
 * an exact configured audience, an allowlisted service-account email, and
 * email_verified=true. Configuration comes from the environment:
 *
 *   WEBHOOK_OIDC_AUDIENCE   exact audience the scheduler job presents in `aud`
 *   WEBHOOK_ALLOWED_EMAILS  comma-separated service-account emails allowed to call
 *
 * If either setting is absent or empty after trimming, the webhook endpoints
 * refuse every request with 503 — they never fall back to accepting
 * unauthenticated calls.
 *
 * Log hygiene: this module only ever surfaces bounded reason codes. The
 * underlying library error text can embed the raw token, so it is discarded
 * here and must never reach logs or responses.
 */

export const WEBHOOK_OIDC_AUDIENCE_ENV = "WEBHOOK_OIDC_AUDIENCE";
export const WEBHOOK_ALLOWED_EMAILS_ENV = "WEBHOOK_ALLOWED_EMAILS";

/**
 * Thrown when the effective OIDC configuration is absent or invalid.
 * The router maps this to HTTP 503.
 */
export class WebhookOidcConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WebhookOidcConfigError";
  }
}

const WEBHOOK_AUTH_REASONS = [
  "missing_bearer_token",
  "malformed_authorization_header",
  "invalid_token",
  "email_unverified",
  "unauthorized_email"
] as const;

export type WebhookAuthReason = (typeof WEBHOOK_AUTH_REASONS)[number];

/**
 * Thrown when the presented credentials are missing or invalid.
 * The router maps this to HTTP 401.
 */
export class WebhookAuthError extends Error {
  readonly reason: WebhookAuthReason;

  constructor(reason: WebhookAuthReason) {
    // Only the bounded reason code is exposed; library error text can embed
    // the raw token and must never reach logs or responses.
    super(`webhook authentication failed: ${reason}`);
    this.name = "WebhookAuthError";
    this.reason = reason;
  }
}

export interface WebhookOidcConfig {
  audience: string;
  allowedEmails: readonly string[];
}

export interface WebhookIdentity {
  email: string;
}

export interface WebhookOidcVerifier {
  verifyBearerToken(authorizationHeader: string | undefined): Promise<WebhookIdentity>;
}

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Reads and validates the effective webhook OIDC configuration. Values are
 * trimmed; the email allowlist is lowercased because Google-issued identity
 * emails are lowercase. Absent or empty settings throw WebhookOidcConfigError
 * so callers can refuse every request (HTTP 503) instead of accepting.
 */
export function parseWebhookOidcConfig(
  env: Record<string, string | undefined> = process.env
): WebhookOidcConfig {
  const audience = (env[WEBHOOK_OIDC_AUDIENCE_ENV] ?? "").trim();
  if (!audience) {
    throw new WebhookOidcConfigError(
      `${WEBHOOK_OIDC_AUDIENCE_ENV} must be set to the exact audience configured on the scheduler job.`
    );
  }

  const allowedEmails = (env[WEBHOOK_ALLOWED_EMAILS_ENV] ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry.length > 0);

  if (allowedEmails.length === 0) {
    throw new WebhookOidcConfigError(
      `${WEBHOOK_ALLOWED_EMAILS_ENV} must list at least one allowed service-account email.`
    );
  }

  allowedEmails.forEach((entry, index) => {
    if (!EMAIL_PATTERN.test(entry)) {
      throw new WebhookOidcConfigError(
        `${WEBHOOK_ALLOWED_EMAILS_ENV} entry ${index + 1} is not a valid email address.`
      );
    }
  });

  return { audience, allowedEmails };
}

const GOOGLE_ISSUERS = new Set(["accounts.google.com", "https://accounts.google.com"]);

function extractBearerToken(authorizationHeader: string | undefined): string {
  if (!authorizationHeader) {
    throw new WebhookAuthError("missing_bearer_token");
  }

  const match = /^Bearer[ \t]+(\S+)[ \t]*$/i.exec(authorizationHeader.trim());
  const token = match?.[1];
  if (!token) {
    throw new WebhookAuthError("malformed_authorization_header");
  }

  return token;
}

/**
 * Builds the production verifier. OAuth2Client.verifyIdToken is declared
 * directly (no injection in production) and enforces the RSA signature
 * against Google's fetched certificates, plus issuer, expiry, and exact
 * audience. The optional client parameter exists so offline tests can stub
 * only the certificate fetch while keeping signature verification real.
 */
export function createWebhookOidcVerifier(
  oidcConfig: WebhookOidcConfig,
  client: OAuth2Client = new OAuth2Client()
): WebhookOidcVerifier {
  return {
    async verifyBearerToken(authorizationHeader) {
      const token = extractBearerToken(authorizationHeader);

      let payload: IdTokenPayload | undefined;
      try {
        const ticket = await client.verifyIdToken({
          idToken: token,
          audience: oidcConfig.audience
        });
        payload = ticket.getPayload() ?? undefined;
      } catch {
        // Discard library error text: it may embed the raw token.
        throw new WebhookAuthError("invalid_token");
      }

      if (!payload) {
        throw new WebhookAuthError("invalid_token");
      }

      // Defense in depth: the library already enforces exact audience and
      // Google issuers; re-check explicitly so the contract holds even if
      // verifier options drift.
      if (payload.aud !== oidcConfig.audience) {
        throw new WebhookAuthError("invalid_token");
      }
      if (!payload.iss || !GOOGLE_ISSUERS.has(payload.iss)) {
        throw new WebhookAuthError("invalid_token");
      }

      const email = (payload.email ?? "").trim().toLowerCase();
      if (!email) {
        throw new WebhookAuthError("unauthorized_email");
      }
      if (payload.email_verified !== true) {
        throw new WebhookAuthError("email_unverified");
      }
      if (!oidcConfig.allowedEmails.includes(email)) {
        throw new WebhookAuthError("unauthorized_email");
      }

      return { email };
    }
  };
}


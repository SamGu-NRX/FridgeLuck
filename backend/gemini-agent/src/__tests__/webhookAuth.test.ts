import { describe, it, expect } from "bun:test";
import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { OAuth2Client, type LoginTicket } from "google-auth-library";
import {
  createWebhookOidcVerifier,
  parseWebhookOidcConfig,
  WebhookAuthError,
  WebhookOidcConfigError,
  WEBHOOK_OIDC_AUDIENCE_ENV,
  WEBHOOK_ALLOWED_EMAILS_ENV,
  type WebhookOidcVerifier
} from "../api/webhookAuth.js";

/**
 * Offline tests for the real google-auth-library verification adapter.
 *
 * Only the certificate fetch (getFederatedSignonCertsAsync) is stubbed, so
 * every token is checked by the library's actual RSA-SHA256 signature
 * verification, issuer/expiry/audience checks, and this adapter's email
 * policy. No test talks to Google.
 *
 * All signing keys are generated in this file and are obviously synthetic;
 * none of them is a real credential.
 */

const AUDIENCE = "https://fridgeluck.example.invalid/v1/webhooks/scheduler";
const ALLOWED_EMAIL = "scheduler@fridgeluck-test.iam.gserviceaccount.com";
const OTHER_ALLOWED_EMAIL = "backup-scheduler@fridgeluck-test.iam.gserviceaccount.com";
const DENIED_EMAIL = "intruder@fridgeluck-test.iam.gserviceaccount.com";
const SYNTHETIC_KID = "obvious-synthetic-test-key-001";

function generateSyntheticRsaKey(): { publicKey: KeyObject; privateKey: KeyObject } {
  return generateKeyPairSync("rsa", { modulusLength: 2048 });
}

const fixture = generateSyntheticRsaKey(); // the "provider" key whose cert the stub serves
const impostor = generateSyntheticRsaKey(); // a key the stub does NOT certify

function fixtureCertificates(): Record<string, string> {
  const pem = fixture.publicKey.export({ type: "spki", format: "pem" }).toString();
  return { [SYNTHETIC_KID]: pem };
}

function toBase64Url(buffer: Buffer): string {
  return buffer
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function b64urlJson(value: unknown): string {
  return toBase64Url(Buffer.from(JSON.stringify(value), "utf8"));
}

function signBase64Url(signingInput: string, key: KeyObject): string {
  // RSA-SHA256, matching the algorithm google-auth-library verifies with.
  // Uses the one-shot crypto.sign API (Bun-compatible; returns a Buffer).
  return toBase64Url(sign("sha256", Buffer.from(signingInput, "utf8"), key));
}

function validClaims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Math.floor(Date.now() / 1000);
  return {
    iss: "https://accounts.google.com",
    aud: AUDIENCE,
    sub: "000000000000000000000", // synthetic subject
    email: ALLOWED_EMAIL,
    email_verified: true,
    iat: now - 60,
    exp: now + 600,
    ...overrides
  };
}

interface TokenSpec {
  payload: Record<string, unknown>;
  header?: Record<string, unknown>;
  signingKey?: KeyObject | null;
}

function makeIdToken({ payload, header, signingKey = fixture.privateKey }: TokenSpec): string {
  const resolvedHeader = header ?? { alg: "RS256", typ: "JWT", kid: SYNTHETIC_KID };
  const signingInput = `${b64urlJson(resolvedHeader)}.${b64urlJson(payload)}`;
  if (signingKey === null) {
    return `${signingInput}.`; // unsigned token (empty signature segment)
  }
  return `${signingInput}.${signBase64Url(signingInput, signingKey)}`;
}

/** Swaps the payload segment after signing, keeping the original signature. */
function tamperPayload(token: string, payload: Record<string, unknown>): string {
  const segments = token.split(".");
  segments[1] = b64urlJson(payload);
  return segments.join(".");
}

/** Builds the production verifier with ONLY the cert fetch stubbed. */
function makeStubbedVerifier(certs: Record<string, string> = fixtureCertificates()): WebhookOidcVerifier {
  const client = new OAuth2Client();
  (client as unknown as { getFederatedSignonCertsAsync: () => Promise<unknown> }).getFederatedSignonCertsAsync =
    async () => ({ certs, format: "PEM" });
  return createWebhookOidcVerifier(oidcConfig(), client);
}

function oidcConfig(overrides: Partial<{ audience: string; allowedEmails: string[] }> = {}) {
  return {
    audience: overrides.audience ?? AUDIENCE,
    allowedEmails: overrides.allowedEmails ?? [ALLOWED_EMAIL, OTHER_ALLOWED_EMAIL]
  };
}

async function expectAuthRejection(
  verifier: WebhookOidcVerifier,
  authorizationHeader: string | undefined,
  expectedReason?: WebhookAuthError["reason"]
): Promise<WebhookAuthError> {
  let caught: unknown;
  try {
    await verifier.verifyBearerToken(authorizationHeader);
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(WebhookAuthError);
  const authError = caught as WebhookAuthError;
  if (expectedReason) {
    expect(authError.reason).toBe(expectedReason);
  }
  return authError;
}

describe("parseWebhookOidcConfig", () => {
  it("trims the audience and lowercases/trims each allowed email", () => {
    const config = parseWebhookOidcConfig({
      [WEBHOOK_OIDC_AUDIENCE_ENV]: `  ${AUDIENCE}  `,
      [WEBHOOK_ALLOWED_EMAILS_ENV]: ` ${ALLOWED_EMAIL.toUpperCase()} ,  ${OTHER_ALLOWED_EMAIL} `
    });
    expect(config.audience).toBe(AUDIENCE);
    expect(config.allowedEmails).toEqual([ALLOWED_EMAIL, OTHER_ALLOWED_EMAIL]);
  });

  it("accepts multiple comma-separated emails and drops empty entries", () => {
    const config = parseWebhookOidcConfig({
      [WEBHOOK_OIDC_AUDIENCE_ENV]: AUDIENCE,
      [WEBHOOK_ALLOWED_EMAILS_ENV]: `${ALLOWED_EMAIL},,${OTHER_ALLOWED_EMAIL},`
    });
    expect(config.allowedEmails).toEqual([ALLOWED_EMAIL, OTHER_ALLOWED_EMAIL]);
  });

  it("throws WebhookOidcConfigError when the audience is absent or whitespace", () => {
    for (const audience of [undefined, "   "]) {
      expect(() =>
        parseWebhookOidcConfig({
          [WEBHOOK_OIDC_AUDIENCE_ENV]: audience,
          [WEBHOOK_ALLOWED_EMAILS_ENV]: ALLOWED_EMAIL
        })
      ).toThrow(WebhookOidcConfigError);
    }
  });

  it("throws WebhookOidcConfigError when the email list is absent or empty", () => {
    for (const emails of [undefined, "", "  ,  ,  "]) {
      expect(() =>
        parseWebhookOidcConfig({
          [WEBHOOK_OIDC_AUDIENCE_ENV]: AUDIENCE,
          [WEBHOOK_ALLOWED_EMAILS_ENV]: emails
        })
      ).toThrow(WebhookOidcConfigError);
    }
  });

  it("throws WebhookOidcConfigError on a malformed email entry", () => {
    expect(() =>
      parseWebhookOidcConfig({
        [WEBHOOK_OIDC_AUDIENCE_ENV]: AUDIENCE,
        [WEBHOOK_ALLOWED_EMAILS_ENV]: `${ALLOWED_EMAIL}, not-an-email`
      })
    ).toThrow(WebhookOidcConfigError);
  });
});

describe("extractBearerToken policy (via verifyBearerToken)", () => {
  const verifier = makeStubbedVerifier();

  it("rejects a missing Authorization header", async () => {
    await expectAuthRejection(verifier, undefined, "missing_bearer_token");
  });

  it("rejects non-Bearer schemes and bare 'Bearer'", async () => {
    await expectAuthRejection(verifier, "Basic dXNlcjpwYXNz", "malformed_authorization_header");
    await expectAuthRejection(verifier, "Bearer", "malformed_authorization_header");
    await expectAuthRejection(verifier, "Bearer   ", "malformed_authorization_header");
  });
});

describe("createWebhookOidcVerifier with real google-auth-library verification", () => {
  it("accepts a correctly signed token from the allowed scheduler identity", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({ payload: validClaims() });
    const identity = await verifier.verifyBearerToken(`Bearer ${token}`);
    expect(identity.email).toBe(ALLOWED_EMAIL);
  });

  it("rejects an UNSIGNED (alg none) token carrying the allowed email", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({
      payload: validClaims(),
      header: { alg: "none", typ: "JWT", kid: SYNTHETIC_KID },
      signingKey: null
    });
    await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
  });

  it("rejects a token signed by a key the certificate set does not vouch for, even with the allowed email", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({ payload: validClaims(), signingKey: impostor.privateKey });
    await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
  });

  it("rejects a token whose payload was tampered with after signing", async () => {
    const verifier = makeStubbedVerifier();
    const signed = makeIdToken({ payload: validClaims() });
    const tampered = tamperPayload(signed, validClaims({ email: DENIED_EMAIL }));
    await expectAuthRejection(verifier, `Bearer ${tampered}`, "invalid_token");
  });

  it("rejects a correctly signed token with the wrong audience", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({ payload: validClaims({ aud: "https://other.example.invalid/target" }) });
    await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
  });

  it("rejects a correctly signed token with a non-Google issuer", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({
      payload: validClaims({ iss: "https://attacker.example.invalid" })
    });
    await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
  });

  it("rejects an expired token", async () => {
    const verifier = makeStubbedVerifier();
    const now = Math.floor(Date.now() / 1000);
    const token = makeIdToken({ payload: validClaims({ iat: now - 7200, exp: now - 3600 }) });
    await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
  });

  it("rejects a token whose expiry exceeds the maximum token lifetime", async () => {
    const verifier = makeStubbedVerifier();
    const now = Math.floor(Date.now() / 1000);
    const token = makeIdToken({ payload: validClaims({ exp: now + 7 * 24 * 3600 }) });
    await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
  });

  it("rejects a token with email_verified=false", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({ payload: validClaims({ email_verified: false }) });
    await expectAuthRejection(verifier, `Bearer ${token}`, "email_unverified");
  });

  it("rejects a token whose verified email is not on the allowlist", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({ payload: validClaims({ email: DENIED_EMAIL }) });
    await expectAuthRejection(verifier, `Bearer ${token}`, "unauthorized_email");
  });

  it("rejects a token without an email claim", async () => {
    const verifier = makeStubbedVerifier();
    const claims = validClaims();
    delete claims.email;
    delete claims.email_verified;
    const token = makeIdToken({ payload: claims });
    await expectAuthRejection(verifier, `Bearer ${token}`, "unauthorized_email");
  });

  it("never leaks the raw token through error messages", async () => {
    const verifier = makeStubbedVerifier();
    const token = makeIdToken({ payload: validClaims(), signingKey: impostor.privateKey });
    const err = await expectAuthRejection(verifier, `Bearer ${token}`, "invalid_token");
    expect(err.message.includes(token)).toBe(false);
    expect(err.message.includes(SYNTHETIC_KID)).toBe(false);
  });
});

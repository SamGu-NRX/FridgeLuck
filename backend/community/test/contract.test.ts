/**
 * Contract round-trip tests (review finding 5, SPEC §14): the PR body claimed
 * "every response is validated against the committed JSON Schemas with Ajv" —
 * these tests make that claim true and machine-checked. Every implemented
 * operation's live response is validated against the OpenAPI-declared JSON
 * Schema, every committed example fixture is validated against the same
 * schema, and implemented responses must match the example's key shape
 * (a null on either side tolerates absence on the other).
 */
import { describe, test, expect } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse } from "yaml";
import Ajv2020, { type ValidateFunction } from "ajv/dist/2020";
import addFormats from "ajv-formats";
import { buildApp, type App } from "../src/app.js";
import type { AppleIdentityTokenClaims } from "../src/core/appleVerify.js";
import type { DocumentStore } from "../src/core/store/documentStore.js";

const CONTRACTS = join(import.meta.dir, "..", "..", "..", "docs", "spec", "community", "contracts");

interface OperationInfo {
  method: string;
  path: string;
  requestRef?: string;
  responseRef?: string;
}

const openapi = parse(readFileSync(join(CONTRACTS, "openapi.yaml"), "utf8")) as {
  paths: Record<string, Record<string, unknown>>;
};

const operations = new Map<string, OperationInfo>();
for (const [path, item] of Object.entries(openapi.paths)) {
  for (const [method, op] of Object.entries(item)) {
    if (!["get", "post", "patch", "put", "delete"].includes(method) || op === null || typeof op !== "object") {
      continue;
    }
    const o = op as {
      operationId?: string;
      requestBody?: { content?: { "application/json"?: { schema?: string } } };
      responses?: Record<string, { content?: { "application/json"?: { schema?: string } } }>;
    };
    if (o.operationId === undefined) {
      continue;
    }
    operations.set(o.operationId, {
      method: method.toUpperCase(),
      path,
      requestRef: o.requestBody?.content?.["application/json"]?.schema,
      responseRef: Object.entries(o.responses ?? {})
        .filter(([status]) => status.startsWith("2"))
        .map(([, response]) => response?.content?.["application/json"]?.schema)
        .find((ref) => typeof ref === "string"),
    });
  }
}

const ajv = new Ajv2020({ allErrors: true, strict: false });
addFormats(ajv);
const schemasDir = join(CONTRACTS, "schemas");
// Register every contract schema exactly once by its $id. Compiling a schema
// that carries an $id would re-register it (Ajv throws on duplicates, and any
// compile also registers $ref targets transitively), so validation always goes
// through the registry instead of recompiling loaded files.
const schemaIdByRef = new Map<string, string>();
for (const file of readdirSync(schemasDir).sort()) {
  if (!file.endsWith(".json")) {
    continue;
  }
  const schema = JSON.parse(readFileSync(join(schemasDir, file), "utf8")) as { $id?: string };
  ajv.addSchema(schema);
  if (typeof schema.$id === "string") {
    schemaIdByRef.set(`schemas/${file}`, schema.$id);
  }
}

const validatorCache = new Map<string, ValidateFunction>();

function validatorFor(ref: string): ValidateFunction {
  const cached = validatorCache.get(ref);
  if (cached !== undefined) {
    return cached;
  }
  const [fileRef, fragment] = ref.split("#");
  const id = schemaIdByRef.get(fileRef ?? "");
  if (id === undefined) {
    throw new Error(`no contract schema registered for ${ref}`);
  }
  const validate =
    fragment === undefined
      ? ajv.getSchema(id)
      : ajv.compile({ $ref: `${id}#${fragment}` });
  if (validate === undefined) {
    throw new Error(`schema ${id} is not registered`);
  }
  validatorCache.set(ref, validate);
  return validate;
}

function expectValid(operationId: string, ref: string, data: unknown, where: string): void {
  const validate = validatorFor(ref);
  if (!validate(data)) {
    throw new Error(`${where} payload of ${operationId} violates ${ref}: ${ajv.errorsText(validate.errors)}`);
  }
}

/**
 * Key-shape equality between a live response and the committed example. Leaf
 * values differ by design (ids, timestamps); the schema already checked their
 * types. A key present on one side and absent on the other is a mismatch
 * unless the present value is null (fields the example fills only when set).
 */
function assertSameShape(live: unknown, example: unknown, path: string): void {
  if (live === null || example === null || typeof live !== "object" || typeof example !== "object") {
    return;
  }
  if (Array.isArray(live) || Array.isArray(example)) {
    if (Array.isArray(live) && Array.isArray(example) && live.length > 0 && example.length > 0) {
      assertSameShape(live[0], example[0], `${path}[0]`);
    }
    return;
  }
  const liveRec = live as Record<string, unknown>;
  const exampleRec = example as Record<string, unknown>;
  for (const key of Object.keys(liveRec)) {
    if (!(key in exampleRec) && liveRec[key] !== null && liveRec[key] !== undefined) {
      throw new Error(`${path}.${key}: emitted by the implementation but absent from the contract example`);
    }
  }
  for (const key of Object.keys(exampleRec)) {
    if (!(key in liveRec) && exampleRec[key] !== null && exampleRec[key] !== undefined) {
      throw new Error(`${path}.${key}: in the contract example but never emitted by the implementation`);
    }
  }
  for (const key of Object.keys(liveRec)) {
    if (key in exampleRec) {
      assertSameShape(liveRec[key], exampleRec[key], `${path}.${key}`);
    }
  }
}

/** Maps a stub identity token to an Apple sub; anything unknown is refused. */
const stubApple = {
  verify: async (identityToken: string, nonce: string, _nowMs: number): Promise<AppleIdentityTokenClaims> => {
    if (!identityToken.startsWith("stub-jwt-")) {
      throw new Error("apple rejected the identity token");
    }
    return { appleSub: identityToken.slice("stub-jwt-".length), nonce, email: null };
  },
};

interface Session {
  accessToken: string;
  refreshToken: string;
  account: { accountId: string };
}

function readExample(name: string): unknown {
  return JSON.parse(readFileSync(join(CONTRACTS, "examples", name), "utf8"));
}

describe("contract round-trip (SPEC §14, review finding 5)", () => {
  let app: App;
  let author: Session;
  let operator: Session;
  let reporter: Session;
  let authorAccountId = "";
  let operatorAccountId = "";
  let publicationId = "";
  let caseId = "";

  const bearer = (token: string): RequestInit => ({ headers: { authorization: `Bearer ${token}` } });
  const post = (token: string, body: unknown): RequestInit => ({
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  test("authApple: live response, example, and request fixture all satisfy schemas/session.schema.json", async () => {
    app = await buildApp({ apple: stubApple });
    const signIn = async (sub: string): Promise<Response> =>
      app.handle(new Request("https://api.test/v1/auth/apple", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ identityToken: `stub-jwt-${sub}`, nonce: crypto.randomUUID() }) }));
    const authApple = operations.get("authApple");
    if (authApple?.responseRef === undefined) {
      throw new Error("authApple has no 2xx JSON schema in the contract");
    }
    const res = await signIn("sub-contract-author");
    expect(res.status).toBe(200);
    author = (await res.json()) as Session;
    expectValid("authApple", authApple.responseRef, author, "live");
    const example = readExample("authApple.response.json");
    expectValid("authApple", authApple.responseRef, example, "example");
    assertSameShape(author, example, "$");
    const opRes = await signIn("sub-contract-operator");
    expect(opRes.status).toBe(200);
    operator = (await opRes.json()) as Session;
    operatorAccountId = operator.account.accountId;
    const reporterRes = await signIn("sub-contract-reporter");
    expect(reporterRes.status).toBe(200);
    reporter = (await reporterRes.json()) as Session;
    authorAccountId = author.account.accountId;
  });

  test("getMe: live response satisfies schemas/account.schema.json and matches the example shape", async () => {
    const getMe = operations.get("getMe");
    if (getMe?.responseRef === undefined) {
      throw new Error("getMe has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request("https://api.test/v1/me", bearer(author.accessToken)));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("getMe", getMe.responseRef, body, "live");
    const example = readExample("getMe.response.json");
    expectValid("getMe", getMe.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("updateMe: example request replays verbatim; response satisfies schemas/account.schema.json", async () => {
    const updateMe = operations.get("updateMe");
    if (updateMe?.responseRef === undefined) {
      throw new Error("updateMe has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request("https://api.test/v1/me", { ...post(author.accessToken, readExample("updateMe.request.json")), method: "PATCH" }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("updateMe", updateMe.responseRef, body, "live");
    const example = readExample("updateMe.response.json");
    expectValid("updateMe", updateMe.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("createPublication: example request replays verbatim; response satisfies schemas/publication.schema.json", async () => {
    const createPublication = operations.get("createPublication");
    if (createPublication?.responseRef === undefined) {
      throw new Error("createPublication has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request("https://api.test/v1/publications", post(author.accessToken, readExample("createPublication.request.json"))));
    expect(res.status).toBe(201);
    const body = (await res.json()) as { publicationId: string };
    publicationId = body.publicationId;
    expectValid("createPublication", createPublication.responseRef, body, "live");
    const example = readExample("createPublication.response.json");
    expectValid("createPublication", createPublication.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("listMyPublications: response satisfies schemas/publication-list.schema.json", async () => {
    const op = operations.get("listMyPublications");
    if (op?.responseRef === undefined) {
      throw new Error("listMyPublications has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request("https://api.test/v1/publications/mine", bearer(author.accessToken)));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("listMyPublications", op.responseRef, body, "live");
    const example = readExample("listMyPublications.response.json");
    expectValid("listMyPublications", op.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("getPublication: response satisfies schemas/publication.schema.json", async () => {
    const op = operations.get("getPublication");
    if (op?.responseRef === undefined) {
      throw new Error("getPublication has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`, bearer(author.accessToken)));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("getPublication", op.responseRef, body, "live");
    const example = readExample("getPublication.response.json");
    expectValid("getPublication", op.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("getExploreFeed: response satisfies schemas/explore-feed.schema.json", async () => {
    const op = operations.get("getExploreFeed");
    if (op?.responseRef === undefined) {
      throw new Error("getExploreFeed has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request("https://api.test/v1/explore/feed", bearer(author.accessToken)));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("getExploreFeed", op.responseRef, body, "live");
    const example = readExample("getExploreFeed.response.json");
    expectValid("getExploreFeed", op.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("getCookCounts: response satisfies schemas/cook-counts.schema.json", async () => {
    const op = operations.get("getCookCounts");
    if (op?.responseRef === undefined) {
      throw new Error("getCookCounts has no 2xx JSON schema in the contract");
    }
    const res = await app.handle(new Request("https://api.test/v1/explore/cook-counts", bearer(author.accessToken)));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("getCookCounts", op.responseRef, body, "live");
    const example = readExample("getCookCounts.response.json");
    expectValid("getCookCounts", op.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("createReport: example request (targetId bound to the live publication) returns 202", async () => {
    const requestExample = readExample("createReport.request.json") as { targetId: string };
    // The example names a fixture publication id; the request replays verbatim
    // except for the target id, which must name the publication created above.
    requestExample.targetId = publicationId;
    const res = await app.handle(new Request("https://api.test/v1/reports", post(reporter.accessToken, requestExample)));
    expect(res.status).toBe(202);
  });

  test("listModerationQueue: response satisfies schemas/moderation-queue.schema.json", async () => {
    const op = operations.get("listModerationQueue");
    if (op?.responseRef === undefined) {
      throw new Error("listModerationQueue has no 2xx JSON schema in the contract");
    }
    const store = (app as unknown as { store: DocumentStore })["store"];
    const opApp = await buildApp({ apple: stubApple, store, config: { operatorAccountIds: [operatorAccountId] } });
    const res = await opApp.handle(new Request("https://api.test/v1/moderation/queue", bearer(operator.accessToken)));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { cases: { caseId: string }[] };
    expectValid("listModerationQueue", op.responseRef, body, "live");
    const example = readExample("listModerationQueue.response.json");
    expectValid("listModerationQueue", op.responseRef, example, "example");
    assertSameShape(body, example, "$");
    const first = body.cases[0];
    if (first === undefined) {
      throw new Error("the report should have queued a case");
    }
    caseId = first.caseId;
  });

  test("decideCase: dismissal returns a case satisfying schemas/moderation-case.schema.json", async () => {
    const op = operations.get("decideCase");
    if (op?.responseRef === undefined) {
      throw new Error("decideCase has no 2xx JSON schema in the contract");
    }
    const store = (app as unknown as { store: DocumentStore })["store"];
    const opApp = await buildApp({ apple: stubApple, store, config: { operatorAccountIds: [operatorAccountId] } });
    // The example decides "remove"; the flow dismisses so the false report is
    // undone and the author can withdraw the restored publication afterwards.
    const requestExample = readExample("decideCase.request.json") as { action: string; note: string };
    requestExample.action = "dismiss";
    const res = await opApp.handle(new Request(`https://api.test/v1/moderation/cases/${caseId}/decision`, post(operator.accessToken, requestExample)));
    expect(res.status).toBe(200);
    const body = await res.json();
    expectValid("decideCase", op.responseRef, body, "live");
    const example = readExample("decideCase.response.json");
    expectValid("decideCase", op.responseRef, example, "example");
    assertSameShape(body, example, "$");
  });

  test("authRefresh: live rotation satisfies schemas/session.schema.json alongside both fixtures", async () => {
    const op = operations.get("authRefresh");
    if (op?.responseRef === undefined) {
      throw new Error("authRefresh has no 2xx JSON schema in the contract");
    }
    const refresh = await app.handle(
      new Request("https://api.test/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ refreshToken: author.refreshToken }) }),
    );
    expect(refresh.status).toBe(200);
    const body = (await refresh.json()) as Session;
    expectValid("authRefresh", op.responseRef, body, "live");
    expectValid("authRefresh", op.responseRef, readExample("authRefresh.response.json"), "example");
    const requestExample = readExample("authRefresh.request.json");
    if (op.requestRef === undefined) {
      throw new Error("authRefresh declares no request body in the contract");
    }
    expectValid("authRefresh", op.requestRef, requestExample, "example");
    author = body; // subsequent steps use the rotated token
  });

  test("withdrawPublication: 204 no content", async () => {
    const res = await app.handle(new Request(`https://api.test/v1/publications/${publicationId}`, { method: "DELETE", ...bearer(author.accessToken) }));
    expect(res.status).toBe(204);
  });

  test("revokeSession: 204 no content", async () => {
    const res = await app.handle(new Request("https://api.test/v1/session", { method: "DELETE", ...bearer(author.accessToken) }));
    expect(res.status).toBe(204);
  });

  test("deleteAccount: 202 no content (re-authenticated: the presented session was revoked above)", async () => {
    const reauth = await app.handle(
      new Request("https://api.test/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ identityToken: "stub-jwt-sub-contract-author", nonce: crypto.randomUUID() }),
      }),
    );
    expect(reauth.status).toBe(200);
    const session = (await reauth.json()) as Session;
    const res = await app.handle(new Request("https://api.test/v1/account", { method: "DELETE", ...bearer(session.accessToken) }));
    expect(res.status).toBe(202);
  });

  test("every committed example fixture validates against its declared contract schema", () => {
    const examplesDir = join(CONTRACTS, "examples");
    let checked = 0;
    for (const file of readdirSync(examplesDir).sort()) {
      const match = /^(.+)\.(request|response)\.json$/.exec(file);
      if (match === null) {
        throw new Error(`example file ${file} does not follow <operationId>.<request|response>.json`);
      }
      const [, opId, kind] = match;
      if (opId === undefined || kind === undefined) {
        throw new Error(`example file ${file} produced an empty operation id or kind`);
      }
      const op = operations.get(opId);
      if (op === undefined) {
        throw new Error(`example ${file} names operation ${opId} which openapi.yaml does not define`);
      }
      const data = readExample(file);
      if (kind === "request") {
        if (op.requestRef === undefined) {
          throw new Error(`${file}: operation ${opId} declares no request body schema`);
        }
        expectValid(opId, op.requestRef, data, "example");
      } else {
        if (op.responseRef === undefined) {
          throw new Error(`${file}: operation ${opId} has no 2xx JSON schema`);
        }
        expectValid(opId, op.responseRef, data, "example");
      }
      checked += 1;
    }
    expect(checked).toBeGreaterThan(25);
  });
});

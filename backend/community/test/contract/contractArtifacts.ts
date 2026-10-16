/**
 * Loads the contract (docs/spec/community/contracts/) for the round-trip suite:
 * openapi.yaml parsed for operations and their declared per-status schemas, the
 * JSON Schemas compiled into Ajv's 2020-12 build with ajv-formats, and the
 * request examples replayed as request fixtures.
 *
 * The schemas carry absolute $ids (https://fridgeluck.dev/community/schemas/...),
 * so cross-file $refs resolve inside Ajv once every file is registered.
 */

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { parse } from "yaml";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

/** Repo layout is stable: backend/community/test/contract/ → docs/spec/community/contracts/. */
export const CONTRACTS_DIR = join(import.meta.dir, "..", "..", "..", "..", "docs", "spec", "community", "contracts");
const SCHEMAS_DIR = join(CONTRACTS_DIR, "schemas");
const EXAMPLES_DIR = join(CONTRACTS_DIR, "examples");
const ID_BASE = "https://fridgeluck.dev/community/schemas/";

export interface OpenApiOperation {
  readonly operationId: string;
  readonly method: string;
  /** Path exactly as openapi.yaml spells it: /tables/{tableId}/cards. */
  readonly path: string;
  /** Router pattern form: /tables/:tableId/cards. */
  readonly routePattern: string;
  /** Absolute-$id ref for the request body schema, when the operation declares one. */
  readonly requestSchemaRef: string | null;
  /** Declared responses: status → absolute-$id response schema ref, or null for body-less (204/202). */
  readonly responses: Readonly<Record<string, string | null>>;
}

/** "schemas/session.schema.json#/$defs/X" → "https://fridgeluck.dev/community/schemas/session.schema.json#/$defs/X". */
function toAbsoluteRef(ref: string): string {
  return ref.startsWith("http") ? ref : ID_BASE + ref.replace(/^schemas\//, "");
}

/**
 * OpenAPI 3.1 requires a schema object, so the spec's response/request schemas
 * are `{$ref: "schemas/..."}`; the older contract-suite yaml spelling used a
 * bare $ref string. Accept both — the integration merges the spec rewrite
 * (obv/burst5-fridgeluck-spec-community) with the round-trip suite
 * (obv/burst6-fridgeluck-community-contract) that predates it.
 */
function responseSchemaRef(schema: unknown): string | undefined {
  if (typeof schema === "string") return schema;
  if (schema !== null && typeof schema === "object" && typeof (schema as { $ref?: unknown }).$ref === "string") {
    return (schema as { $ref: string }).$ref;
  }
  return undefined;
}

export function loadOpenApiOperation(path: string, method: string, op: Record<string, unknown>): OpenApiOperation {
  const responses: Record<string, string | null> = {};
  for (const [status, response] of Object.entries((op["responses"] as Record<string, unknown>) ?? {})) {
    const content = (response as Record<string, unknown> | null)?.["content"] as Record<string, Record<string, unknown>> | undefined;
    const schema = responseSchemaRef(content?.["application/json"]?.["schema"]);
    responses[String(status)] = schema === undefined ? null : toAbsoluteRef(schema);
  }
  const requestBody = op["requestBody"] as Record<string, unknown> | undefined;
  const requestSchema = responseSchemaRef((requestBody?.["content"] as Record<string, Record<string, unknown>> | undefined)?.["application/json"]?.["schema"]);
  return {
    operationId: op["operationId"] as string,
    method: method.toUpperCase(),
    path,
    routePattern: path.replaceAll(/\{([^}]+)\}/g, ":$1"),
    requestSchemaRef: requestSchema === undefined ? null : toAbsoluteRef(requestSchema),
    responses,
  };
}

/**
 * Reads one request-example file. An absent example is null — the suite's
 * "no example declared" path; any other read failure or malformed JSON
 * throws, so contract breakage fails loudly instead of posing as contract
 * absence.
 */
export function readExampleFile(path: string): Record<string, unknown> | null {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") {
      return null;
    }
    throw e;
  }
  return JSON.parse(raw) as Record<string, unknown>;
}

export interface ContractArtifacts {
  readonly operations: readonly OpenApiOperation[];
  readonly operationByRoute: ReadonlyMap<string, OpenApiOperation>;
  /** Compiles an absolute-$id ref (or a $defs fragment) into an Ajv validate fn. */
  readonly compile: (ref: string) => (data: unknown) => boolean;
  readonly lastAjvErrors: () => string | null;
  /** contracts/examples/<name>.json, or null when the operation has no example. */
  readonly exampleRequest: (operationId: string) => Record<string, unknown> | null;
}

let cached: ContractArtifacts | null = null;

export function loadContractArtifacts(): ContractArtifacts {
  if (cached !== null) {
    return cached;
  }

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const schemaFiles = readdirSync(SCHEMAS_DIR).filter((f) => f.endsWith(".json"));
  for (const file of schemaFiles) {
    ajv.addSchema(JSON.parse(readFileSync(join(SCHEMAS_DIR, file), "utf8")));
  }
  let lastErrors: string | null = null;

  const openapiText = readFileSync(join(CONTRACTS_DIR, "openapi.yaml"), "utf8");
  const doc = parse(openapiText) as { paths: Record<string, Record<string, Record<string, unknown>>> };
  const operations: OpenApiOperation[] = [];
  for (const [path, methods] of Object.entries(doc.paths ?? {})) {
    for (const [method, op] of Object.entries(methods)) {
      if (!["get", "post", "put", "patch", "delete"].includes(method.toLowerCase()) || typeof op !== "object" || op === null) {
        continue;
      }
      if (typeof op["operationId"] !== "string") {
        throw new Error(`openapi.yaml: ${method.toUpperCase()} ${path} has no operationId`);
      }
      operations.push(loadOpenApiOperation(path, method, op));
    }
  }
  const operationByRoute = new Map(operations.map((op) => [`${op.method} ${op.routePattern}`, op]));

  cached = {
    operations,
    operationByRoute,
    compile: (ref: string) => {
      const validate = ajv.getSchema(ref);
      if (validate === undefined) {
        throw new Error(`schema not registered: ${ref}`);
      }
      return (data: unknown) => {
        // Ajv types async schemas too; every schema registered here is sync.
        const ok: boolean = validate(data) === true;
        lastErrors = ok ? null : ajv.errorsText(validate.errors ?? [], { dataVar: "body" });
        return ok;
      };
    },
    lastAjvErrors: () => lastErrors,
    exampleRequest: (operationId: string) => readExampleFile(join(EXAMPLES_DIR, `${operationId}.request.json`)),
  };
  const loaded = cached;
  if (loaded === null) {
    throw new Error("contract artifacts failed to load");
  }
  return loaded;
}

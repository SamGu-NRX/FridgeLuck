/**
 * RecipeRef parsing for challenge entries: the contract's common RecipeRef is
 * {source, id, revision} with source fixed to the in-app catalog. Parsing
 * failures are 422 validation, never 500s from downstream lookups.
 */

import { errValidation } from "../../core/errors.js";

export interface RecipeRef {
  readonly source: string;
  readonly id: string;
  readonly revision: number;
}

/** Parses and validates a client-supplied recipeRef payload. */
export function recipeRefFromPayload(raw: unknown): RecipeRef {
  if (typeof raw !== "object" || raw === null) {
    throw errValidation("validation", "field recipeRef must be an object with source, id, revision");
  }
  const data = raw as Record<string, unknown>;
  const source = data["source"];
  const id = data["id"];
  const revision = data["revision"];
  if (typeof source !== "string" || !["catalog", "user", "community", "generated"].includes(source)) {
    throw errValidation("validation", 'field recipeRef.source must be one of catalog, user, community, generated');
  }
  if (typeof id !== "string" || id.length < 1 || id.length > 128) {
    throw errValidation("validation", "field recipeRef.id must be a string of 1-128 characters");
  }
  if (typeof revision !== "number" || !Number.isInteger(revision) || revision < 1) {
    throw errValidation("validation", "field recipeRef.revision must be a positive integer");
  }
  return { source, id, revision };
}

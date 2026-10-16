/** Request fixtures for the round-trip suite: contracts/examples where they exist. */

import { loadContractArtifacts } from "./contractArtifacts.js";

export function exampleRequest(operationId: string): Record<string, unknown> {
  const example = loadContractArtifacts().exampleRequest(operationId);
  if (example === null) {
    throw new Error(`no contracts/examples/${operationId}.request.json — add one to the contract or build the body inline`);
  }
  return example;
}

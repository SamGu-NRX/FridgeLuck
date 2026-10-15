/**
 * Module discovery and the fixed module shape (SPEC §7.2).
 *
 * Startup globs `src/modules/<name>/index.ts`; each module default-exports a
 * ModuleDefinition. Adding a feature later adds only a directory — no central
 * route file, no central schema file. The server refuses duplicate module
 * names, so two slices can never merge through the same mount point.
 */

import { readdirSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import type { Router } from "./router.js";
import type { DocumentStore } from "./store/documentStore.js";
import type { Clock } from "./time.js";
import type { SessionCore } from "./sessionCore.js";
import type { AppleVerifier } from "./appleVerify.js";

/** The module-facing verifier surface: only verify() is ever called. */
export type AppleTokenVerifier = Pick<AppleVerifier, "verify">;
import type { ScreeningPipeline } from "./screening.js";
import type { CommunityConfig } from "../config.js";

export interface ModuleContext {
  readonly config: CommunityConfig;
  readonly store: DocumentStore;
  readonly clock: Clock;
  readonly sessions: SessionCore;
  readonly apple: AppleTokenVerifier;
  readonly screening: ScreeningPipeline;
  /** True when the caller's account is on the operator allowlist. */
  isOperator(accountId: string): boolean;
}

export interface ModuleDefinition {
  readonly name: string;
  readonly version: number;
  routes(ctx: ModuleContext): Router;
  /** Collections + indexes this module owns (names registered for collision checks). */
  schema?(registry: SchemaRegistry): void;
  /** Schema changes it owns (burst5 uses schemaless documents; kept for later modules). */
  migrations?(runner: MigrationRunner): void;
}

export interface SchemaRegistry {
  /** Registers an owned collection name; duplicates across modules are refused. */
  collection(name: string, owner: string): void;
}

export interface MigrationRunner {
  step(id: string, apply: () => Promise<void> | void): Promise<void>;
}

export interface DiscoveredModule {
  readonly name: string;
  readonly directory: string;
  readonly definition: ModuleDefinition;
}

/**
 * Discovers modules under `modulesDir` (default: the package's
 * `src/modules/`). A directory without an `index.ts` is skipped; one that
 * fails to load or exports a duplicate name stops the boot loudly.
 */
export async function discoverModules(modulesDir: string): Promise<DiscoveredModule[]> {
  const found: DiscoveredModule[] = [];
  const names = new Set<string>();
  const entries = readdirSync(modulesDir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      continue;
    }
    const indexFile = join(modulesDir, entry.name, "index.ts");
    const mod = (await import(pathToFileURL(indexFile).href)) as { default?: unknown };
    const definition = mod.default;
    if (typeof definition !== "object" || definition === null || typeof (definition as ModuleDefinition).name !== "string") {
      throw new Error(`module ${entry.name} must default-export a ModuleDefinition`);
    }
    const def = definition as ModuleDefinition;
    if (names.has(def.name)) {
      throw new Error(`duplicate module name "${def.name}" (directory ${entry.name}); the server refuses to boot`);
    }
    names.add(def.name);
    found.push({ name: def.name, directory: entry.name, definition: def });
  }
  return found;
}

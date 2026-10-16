/**
 * PackResolver (SPEC §4.5): challenge constraints reference PR #116 pack data
 * by `packId` and item `usdaFdcId` — the community spec owns none of that data.
 * The pack files (budget_packs.json, food_bank_packs.json, seasonal_packs.json,
 * use_it_up_packs.json) use the envelope {schemaVersion, kind, retrieved, data}
 * with packs[].items[] keyed by ingredientKey/displayName/usdaFdcId/quantity;
 * the canonical join key is usdaFdcId (ingredientKey is display-only).
 *
 * Resolved items are frozen into the challenge document at creation, so a pack
 * file changing later can never mutate a running challenge (§4.5).
 */

import { errNotFound, errValidation } from "../../core/errors.js";

/** The frozen per-item snapshot stored on the challenge document. */
export interface PackItemSnapshot {
  readonly fdcId: number;
  readonly name: string;
  readonly quantityText: string | null;
}

/** The PR #116 pack envelope shape this resolver reads (by reference only). */
export interface PackEnvelope {
  readonly schemaVersion: number;
  readonly kind: string;
  readonly retrieved: string;
  readonly data: {
    readonly packs?: readonly {
      readonly id: string;
      readonly items?: readonly {
        readonly usdaFdcId?: number;
        readonly displayName?: string;
        readonly quantity?: string;
      }[];
    }[];
  };
}

export type PackLoader = (packId: string) => Promise<PackEnvelope | null>;

export class PackResolver {
  constructor(private readonly loadPack: PackLoader) {}

  /**
   * Resolves a packId to the frozen item snapshot at challenge creation.
   * The canonical join key is usdaFdcId; a pack item without one is a data
   * error and refuses the creation rather than silently dropping an item.
   */
  async freeze(packId: string): Promise<PackItemSnapshot[]> {
    if (packId.length < 3 || packId.length > 64) {
      throw errValidation("validation", "field packId must be a string of 3-64 characters");
    }
    const envelope = await this.loadPack(packId);
    if (envelope === null) {
      throw errNotFound(`pack ${packId} not found`);
    }
    const pack = envelope.data.packs?.find((p) => p.id === packId);
    if (pack === undefined) {
      throw errNotFound(`pack ${packId} not found in its envelope`);
    }
    const items: PackItemSnapshot[] = [];
    for (const item of pack.items ?? []) {
      if (typeof item.usdaFdcId !== "number") {
        throw errValidation("validation", `pack ${packId} item is missing its usdaFdcId join key`);
      }
      items.push({
        fdcId: item.usdaFdcId,
        name: typeof item.displayName === "string" && item.displayName.length > 0 ? item.displayName : `fdc ${item.usdaFdcId}`,
        quantityText: typeof item.quantity === "string" ? item.quantity : null,
      });
    }
    if (items.length === 0 || items.length > 12) {
      throw errValidation("validation", `pack ${packId} resolves to ${items.length} items; 1-12 are required`);
    }
    return items;
  }
}

/** A loader over an in-memory packId → envelope table (tests and operator seeding). */
export function packResolverOver(packs: Readonly<Record<string, PackEnvelope>>): PackResolver {
  return new PackResolver(async (packId) => packs[packId] ?? null);
}

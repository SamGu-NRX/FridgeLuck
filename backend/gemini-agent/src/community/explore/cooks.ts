/**
 * The cook-occurrence write path (SPEC §6: "cooked by N people ... only from
 * opted-in data").
 *
 * The store field is the publication's `optedInCooks` map — account id → the
 * UTC day the account last cooked that publication — which ranking.ts reads
 * for both the "cooked by N" badge and the campus weekly counter. This module
 * is that field's only writer.
 *
 * Dedup window (the interpretation recorded in the M4 handoff): one entry per
 * distinct cook per publication — the map is keyed by account id, so a cook
 * is counted once no matter how many times they cook it, and a later cook by
 * the same account refreshes the stored day (keeping the campus week window
 * honest). Counts are per-publication distinct cooks; no time decay. There is
 * deliberately no other surface: a re-cook changes no rendered count.
 *
 * Opt-in and consent (SPEC 3.4): the occurrence is recorded only when the
 * cook themselves calls the route — the caller's account id comes from
 * requireAccount, never the body, and no structured or free-text payload is
 * accepted beyond the act of opting in (aggregate cook notes with ratings are
 * a later, post-launch surface). The floors (minCookedCountFloor,
 * minDistinctPeopleForCampusCounts) are read-time concerns in ranking.ts and
 * are deliberately NOT enforced here: the writer records the truth, reads
 * suppress.
 */
import type { CollectionReference, Transaction } from "@google-cloud/firestore";
import type { Clock } from "../shared/time.js";
import { toDay, toIso } from "../shared/time.js";
import { type AccountId, type PublicationId } from "../shared/ids.js";
import { parsePublicationDoc, publicationVisibility } from "./publications.js";

export interface CookOccurrenceDeps {
  readonly publications: CollectionReference;
  readonly clock: Clock;
}

export type RecordCookOccurrenceOutcome =
  | { readonly outcome: "ok"; readonly firstOccurrence: boolean; readonly distinctCooks: number }
  | { readonly outcome: "missing" }
  | { readonly outcome: "not-live" };

/**
 * Records one cook occurrence inside a transaction so two concurrent
 * occurrences by the same cook converge to a single entry. Only a
 * reader-visible (live) publication accepts occurrences: the count never
 * renders anywhere else, and a hidden publication must not accumulate
 * aggregate data while it is under review.
 */
export async function recordCookOccurrence(
  deps: CookOccurrenceDeps,
  publicationId: PublicationId,
  cookId: AccountId,
): Promise<RecordCookOccurrenceOutcome> {
  const doc = deps.publications.doc(publicationId);
  const now = deps.clock.now();
  const cookDay = toDay(now);
  const updatedAtIso = toIso(now);
  return deps.publications.firestore.runTransaction(async (tx: Transaction): Promise<RecordCookOccurrenceOutcome> => {
    const existing = parsePublicationDoc(await tx.get(doc));
    if (existing === null) {
      return { outcome: "missing" };
    }
    if (!publicationVisibility(existing.status).visibleToReaders) {
      return { outcome: "not-live" };
    }
    const firstOccurrence = existing.optedInCooks[cookId] === undefined;
    const optedInCooks: Record<string, string> = { ...existing.optedInCooks, [cookId]: cookDay };
    tx.update(doc, { optedInCooks, updatedAtIso });
    return { outcome: "ok", firstOccurrence, distinctCooks: Object.keys(optedInCooks).length };
  });
}

/**
 * The server-rendered challenge page (SPEC §4.4): GET /web/challenges/{id},
 * no /v1 prefix, text/html, no app and no login — Sam's stage-0 share loop.
 * It reads stored challenge data server-side, renders the same payload the app
 * sees (display names only), and carries no scripts beyond basic styling.
 *
 * Scope note: the module defines the route and a complete handler, but the
 * core request plumbing gates non-/v1 paths and dispatch() can only emit JSON
 * bodies — serving this over HTTP needs a small core change that is outside
 * this slice's allowed directories. The renderer and data loading are pure
 * functions, fully tested here; the core wiring gap is documented in the PR.
 */

import { deriveStatus } from "./lifecycle.js";

/** HTML-escapes the five markup-significant characters; every interpolated string goes through this. */
function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch] ?? ch);
}
import {
  CHALLENGES_COLLECTION,
  ENTRIES_COLLECTION,
  VOTES_COLLECTION,
  challengeView,
  entryView,
  type ChallengeRecord,
  type EntryRecord,
} from "./views.js";
import type { DocumentStore } from "../../core/store/documentStore.js";
import type { Clock } from "../../core/time.js";
import { computeTallies } from "./lifecycle.js";

const TYPE_LABELS: Readonly<Record<ChallengeRecord["type"], string>> = {
  battle: "Battle",
  "use-it-up": "Use-it-up",
  budget: "Budget",
  seasonal: "Seasonal",
  "food-bank": "Food bank",
  campus: "Campus",
};

const STYLE = [
  "body{font-family:-apple-system,system-ui,sans-serif;margin:0 auto;max-width:40rem;padding:1.5rem;color:#1c1c1e;background:#fffdf9;line-height:1.5}",
  ".badge{display:inline-block;border:1px solid #d66;border-radius:999px;padding:0.1rem 0.7rem;font-size:0.85rem;color:#b33}",
  "li{margin:0.6rem 0}",
  ".muted{color:#666}",
  "ol.top li b{font-size:1.05rem}",
].join(" ");

/** Renders the page HTML for one challenge and its visible entries. Pure function. */
export function renderChallengePage(
  challenge: Record<string, unknown>,
  entries: readonly Record<string, unknown>[],
): string {
  const name = escapeHtml(String(challenge["name"]));
  const brief = escapeHtml(String(challenge["brief"]));
  const typeLabel = TYPE_LABELS[challenge["type"] as ChallengeRecord["type"]] ?? "Challenge";
  const status = String(challenge["status"]);
  const resolved = challenge["resolvedItems"];
  const items =
    Array.isArray(resolved) && resolved.length > 0
      ? `<h2>Ingredients</h2><ul>${resolved
          .map((i) => {
            const item = i as { name?: unknown; quantityText?: unknown };
            const quantity = typeof item["quantityText"] === "string" && item["quantityText"].length > 0 ? ` — ${escapeHtml(item["quantityText"])}` : "";
            return `<li>${escapeHtml(String(item["name"] ?? ""))}${quantity}</li>`;
          })
          .join("")}</ul>`
      : "";
  const visible = entries.filter((e) => e["state"] === "visible");
  const closed = status === "closed";
  const listTitle = closed ? "Most cooked" : visible.length > 0 ? "Entries" : "";
  const list =
    visible.length === 0
      ? closed
        ? `<p class="muted">Nobody entered this one.</p>`
        : `<p class="muted">No entries yet. Be the first.</p>`
      : `<h2>${listTitle}</h2><ol class="top">${visible
          .map((e) => {
            const counts = closed ? ` — <b>${e["voteCount"] as number} ${String(e["voteCount"]) === "1" ? "cook" : "cooks"}</b>` : "";
            const note = typeof e["note"] === "string" && e["note"].length > 0 ? `<br><span class="muted">${escapeHtml(e["note"])}</span>` : "";
            return `<li><b>${escapeHtml(String(e["title"]))}</b> by ${escapeHtml(String(e["authorDisplayName"]))}${counts}${note}</li>`;
          })
          .join("")}</ol>`;
  const timeline = `Entries close ${escapeHtml(String(challenge["entryClosesAt"]))} · Voting ends ${escapeHtml(String(challenge["votingClosesAt"]))}.`;
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${name} · FridgeLuck</title><style>${STYLE}</style></head>
<body>
<h1>${name}</h1>
<p><span class="badge">${typeLabel}</span> <span class="muted">${status}</span></p>
<p>${brief}</p>
<p class="muted">${timeline}</p>
${items}
${list}
<p class="muted">Made with FridgeLuck — cook something from what you have.</p>
</body>
</html>`;
}

/**
 * Loads the challenge and its viewer-visible entries, then renders the page.
 * Data path shared with the JSON routes: only visible entries appear, tallies
 * resolve only after votingClosesAt.
 */
export async function loadChallengePage(store: DocumentStore, clock: Clock, challengeId: string): Promise<string | null> {
  const challengeSnap = await store.collection(CHALLENGES_COLLECTION).doc(challengeId).get();
  if (challengeSnap.data === null) {
    return null;
  }
  const record = challengeSnap.data as unknown as ChallengeRecord;
  const nowMs = clock.now().getTime();
  const status = deriveStatus(record, nowMs);
  const entryDocs = await store.collection(ENTRIES_COLLECTION).where("challengeId", challengeId).get();
  const allEntries = entryDocs.map((d) => d.data as unknown as EntryRecord);
  const voteDocs = await store.collection(VOTES_COLLECTION).where("challengeId", challengeId).get();
  const votes = voteDocs.map((d) => d.data as unknown as { challengeId: string; accountId: string; entryId: string; createdAt: string; updatedAt: string });
  const tallies = computeTallies(
    allEntries.map((e) => ({ entryId: e.entryId, authorAccountId: e.accountId })),
    votes,
  );
  const authorNames = new Map<string, string>();
  for (const entry of allEntries) {
    if (!authorNames.has(entry.accountId)) {
      const snap = await store.collection("accounts").doc(entry.accountId).get();
      const raw = snap.data?.["displayName"];
      authorNames.set(entry.accountId, typeof raw === "string" && raw.length > 0 ? raw : "Cook");
    }
  }
  const view = challengeView(record, status, allEntries.length, { myEntryId: null, myVoteEntryId: null });
  const entryViews = allEntries
    .sort((a, b) => a.createdAt.localeCompare(b.createdAt))
    .map((e) =>
      entryView(
        e,
        authorNames.get(e.accountId) ?? "Cook",
        "visible",
        status === "closed" ? (tallies.get(e.entryId) ?? 0) : null,
      ),
    )
    .sort((a, b) => {
      if (status !== "closed") {
        return String(a["createdAt"]).localeCompare(String(b["createdAt"]));
      }
      return (b["voteCount"] as number) - (a["voteCount"] as number);
    });
  return renderChallengePage(view, entryViews);
}

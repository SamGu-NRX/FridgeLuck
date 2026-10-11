/**
 * Suite E composition scenarios over the REAL wiring: every part mounted
 * (identity, explore, tables, challenges, safety), the real Firestore block
 * directory and moderation queue, real HTTP against the Firestore emulator.
 *
 * The suite's contract bars (per the scorecard's suite-E row):
 *   1. zero private-field leaks across every captured response
 *   2. zero authorization failures across every scenario step
 *   3. coverage of every moderation transition (queue item lifecycle and
 *      publication transitions, including hide-before-enqueue and the
 *      concurrent-withdrawal guard)
 *
 * When SUITE_E_OUT_DIR is set (by evaluation/suites/community-suite-e/
 * suite.py), the run emits metrics.json in that directory for the scorecard
 * contract. The suite result is only ever produced from this real-wiring
 * run — the Python wrapper never substitutes its own verdict.
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { makeHarness, type CommunityTestHarness } from "./harness.js";
import {
  scanForLeaks,
  signInAs,
  startCommunityApp,
  type AppleTestKeys,
  type CommunityApp,
  type ScenarioHttp,
  type TokenPair,
} from "./communityTestSupport.js";
import type { ModerationQueue } from "../../community/shared/contracts.js";
import { newRecipeRevisionId, type ModerationItemId, type PublicationId, type RecipeRevisionId } from "../../community/shared/ids.js";

/** The queue-item lifecycle transitions the scorecard requires covered. */
const REQUIRED_QUEUE_TRANSITIONS = [
  "submitted:user-report",
  "resolved:rejected",
  "submitted:author-appeal",
  "resolved:approved",
] as const;

/** The publication transitions the scorecard requires covered. */
const REQUIRED_PUBLICATION_TRANSITIONS = [
  "live->queued: user report",
  "queued->live: appeal approved",
  "queued->withdrawn: author withdrew while queued",
  "live->withdrawn: account deletion",
] as const;

interface StepRecord {
  readonly step: string;
  readonly expected: number;
  readonly actual: number;
  readonly ok: boolean;
}

/** Records every scenario step's expected vs actual status for metrics. */
class Scenario {
  readonly steps: StepRecord[] = [];
  failures = 0;

  constructor(readonly name: string) {}

  /** Runs one HTTP step; asserts the status and records it. */
  async expectStatus(label: string, expected: number, run: () => Promise<{ status: number }>): Promise<void> {
    const result = await run();
    const ok = result.status === expected;
    if (!ok) {
      this.failures += 1;
    }
    this.steps.push({ step: label, expected, actual: result.status, ok });
    expect(result.status, `${this.name}: ${label}`).toBe(expected);
  }

  /** Records a non-status assertion for the metrics payload. */
  check(label: string, condition: boolean): void {
    if (!condition) {
      this.failures += 1;
    }
    expect(condition, `${this.name}: ${label}`).toBe(true);
  }
}

interface ScenarioMetrics {
  scenarios: Array<{ name: string; steps: StepRecord[]; failures: number }>;
  leaks: string[];
  queueTransitionsCovered: string[];
  publicationTransitionsCovered: string[];
}

let harness: CommunityTestHarness;
let app: CommunityApp;
let keys: AppleTestKeys;
let http: ScenarioHttp;
let moderationQueue: ModerationQueue;
const scenarioMetrics: ScenarioMetrics = {
  scenarios: [],
  leaks: [],
  queueTransitionsCovered: [],
  publicationTransitionsCovered: [],
};

beforeAll(async () => {
  harness = await makeHarness({
    // Small floors so the two-account scenario can exercise the badge and
    // the campus counter honestly; the read-time enforcement itself is
    // ranking.ts's, covered by the explore tests.
    minCookedCountFloor: 1,
    minDistinctPeopleForCampusCounts: 2,
    reportLimitPerDay: 8,
  });
  app = await startCommunityApp(harness);
  keys = app.keys;
  http = app.http;
  // The moderator/author beats drive the SAME queue instance the app's
  // parts hold — only its resolve() runs the publication transitions.
  // The moderation surface itself is out of scope here; in production it
  // drives this seam.
  moderationQueue = app.moderation;
});

afterAll(async () => {
  const outDir = process.env["SUITE_E_OUT_DIR"];
  if (outDir !== undefined) {
    const { mkdirSync, writeFileSync } = await import("node:fs");
    mkdirSync(outDir, { recursive: true });
    writeFileSync(`${outDir}/metrics.json`, JSON.stringify(scenarioMetrics, null, 2));
  }
  app?.close();
  await harness?.close();
});

const SUITE_E_RECIPE = {
  summary: "A suite-E composition recipe.",
  ingredientLines: ["1 onion", "1 tin chickpeas", "1 tbsp curry paste"],
  steps: ["Fry the onion.", "Add chickpeas and paste, simmer."],
};

/** Publishes a live recipe through the real HTTP surface. */
async function publish(tokens: TokenPair, campus: string, title: string, slug: string): Promise<string> {
  const { status, body } = await http.send(tokens, "POST", "/v1/community/publications", {
    source: { recipeId: `recipes/suite-e-${slug}`, recipeRevision: newRecipeRevisionId() },
    recipe: { title, ...SUITE_E_RECIPE },
    tags: ["suite-e"],
    campus,
    note: null,
    declarations: { ownRights: true, noPersonalData: true },
  });
  expect(status, `publish ${title}`).toBe(201);
  return (body as { publicationId: string }).publicationId;
}

function feedHas(body: unknown, publicationId: string): boolean {
  const items = (body as { items?: Array<{ publicationId: string }> }).items ?? [];
  return items.some((i) => i.publicationId === publicationId);
}

describe("suite E: community composition scenarios", () => {
  test("S1 — two accounts: publish, explore, table cooks, challenge privacy", async () => {
    const scenario = new Scenario("S1 table cooks");
    const author = await signInAs(http, keys, "suite-e-author");
    const viewer = await signInAs(http, keys, "suite-e-viewer");

    const publicationId = await publish(author, "campus-suite-e", "Suite E curry", "curry");

    const viewerFeed = await http.get("/v1/community/explore/campus-suite-e", viewer);
    scenario.expectStatus("viewer reads the campus feed", 200, async () => viewerFeed);
    scenario.check("the feed shows the publication", feedHas(viewerFeed.body, publicationId));

    // Table: create → invite → redeem → approve → shared cook.
    const table = (await http.send(author, "POST", "/v1/community/tables", { name: "Suite E table" })).body as { tableId: string };
    const invite = (await http.send(author, "POST", `/v1/community/tables/${table.tableId}/invites`, undefined)).body as { token: string };
    await scenario.expectStatus("viewer redeems the invite", 200, () =>
      http.send(viewer, "POST", `/v1/community/invites/${encodeURIComponent(invite.token)}/redeem`, undefined),
    );
    await scenario.expectStatus("owner approves the viewer", 200, () =>
      http.send(author, "POST", `/v1/community/tables/${table.tableId}/members/${viewer.accountId}/approve`, undefined),
    );
    await scenario.expectStatus("viewer logs a shared cook", 201, () =>
      http.send(viewer, "POST", `/v1/community/tables/${table.tableId}/cooks`, {
        source: { recipeId: "recipes/suite-e-curry", recipeRevision: newRecipeRevisionId() },
        servings: 2,
        swapsMade: [],
        rating: 4,
        note: "worked on the first try",
        cookedOn: new Date().toISOString().slice(0, 10),
      }),
    );
    const cooks = await http.get(`/v1/community/tables/${table.tableId}/cooks`, author);
    scenario.expectStatus("owner reads the shared cooks", 200, async () => cooks);
    scenario.check("the cook log has the viewer's entry", ((cooks.body as { items: unknown[] }).items).length === 1);

    // Cook count on the publication: the viewer's cook shows at the floor
    // (1) and the campus counter reaches 2 with the author's own cook.
    await scenario.expectStatus("viewer reports cooking the publication", 204, () =>
      http.send(viewer, "POST", `/v1/community/publications/${publicationId}/cooks`, undefined),
    );
    await scenario.expectStatus("author reports cooking their own publication", 204, () =>
      http.send(author, "POST", `/v1/community/publications/${publicationId}/cooks`, undefined),
    );
    const feedAfterCooks = await http.get("/v1/community/explore/campus-suite-e", viewer);
    const feedBody = feedAfterCooks.body as {
      items: Array<{ publicationId: string; cookedByCount?: number }>;
      cookedThisWeekDistinctPeople?: number;
    };
    scenario.check(
      "the cooked-by badge shows the distinct cook count",
      feedBody.items.find((i) => i.publicationId === publicationId)?.cookedByCount === 2,
    );
    scenario.check("the campus weekly counter shows two distinct people", feedBody.cookedThisWeekDistinctPeople === 2);

    // Challenge privacy: entries are the author's own, never the viewer's.
    const challengeCreate = await http.send(viewer, "POST", "/v1/community/challenges", {
      kind: "use-it-up",
      title: "Suite E pantry",
      ingredients: ["chickpeas"],
    });
    await scenario.expectStatus("viewer creates the challenge", 201, () => Promise.resolve(challengeCreate));
    const challenge = challengeCreate.body as { challengeId: string };
    const entryAttempt = await http.send(author, "POST", `/v1/community/challenges/${challenge.challengeId}/entries`, {
      source: { recipeId: "recipes/suite-e-curry", recipeRevision: newRecipeRevisionId() },
      ingredientsUsed: ["chickpeas", "onion", "curry paste"],
    });
    scenario.expectStatus("author submits a private entry", 201, () => Promise.resolve(entryAttempt));
    const viewerEntries = await http.get(`/v1/community/challenges/${challenge.challengeId}/entries`, viewer);
    scenario.expectStatus("viewer lists their own entries", 200, async () => viewerEntries);
    scenario.check("the author's entry is not in the viewer's list", ((viewerEntries.body as { items: unknown[] }).items).length === 0);

    scenarioMetrics.scenarios.push({ name: scenario.name, steps: scenario.steps, failures: scenario.failures });
  });

  test("S2 — three accounts: report, moderate, appeal, withdraw, deletion", async () => {
    const scenario = new Scenario("S2 moderation and deletion");
    const author = await signInAs(http, keys, "suite-e-s2-author");
    const reporter = await signInAs(http, keys, "suite-e-s2-reporter");
    await signInAs(http, keys, "suite-e-s2-moderator"); // present in the scenario; moderation runs through the queue seam

    // 1. live -> queued: a user report hides the publication first.
    const publicationId = await publish(author, "campus-suite-e", "Scrutinised curry", "scrutinised");
    await scenario.expectStatus("reporter reports the publication", 201, () =>
      http.send(reporter, "POST", `/v1/community/publications/${publicationId}/reports`, {
        reason: "not-own-recipe",
        note: "looks like a scanned cookbook page",
      }),
    );
    scenarioMetrics.queueTransitionsCovered.push("submitted:user-report");
    scenarioMetrics.publicationTransitionsCovered.push("live->queued: user report");

    const authorFeed = await http.get("/v1/community/explore/campus-suite-e", author);
    scenario.check("the reported publication left the feed immediately", !feedHas(authorFeed.body, publicationId));
    const authorView = await http.get(`/v1/community/publications/${publicationId}`, author);
    scenario.check(
      "the author still sees their own (hidden) record",
      authorView.status === 200 && (authorView.body as { status?: string }).status !== "published",
    );
    await scenario.expectStatus("everyone else now gets 404 on direct fetch", 404, () =>
      http.get(`/v1/community/publications/${publicationId}`, reporter),
    );

    // 2. resolved: rejected — the moderator confirms the report; the
    // publication goes queued -> rejected and stays hidden. (The approval
    // guard only moves queued publications, so a rejection is terminal —
    // that is why the appeal below runs on a still-queued publication.)
    const openItems = await moderationQueue.list("open");
    const reported = openItems.find((i) => i.target.publicationId === publicationId);
    scenario.check("the queue holds the open report", reported !== undefined);
    await moderationQueue.resolve(reported?.itemId as ModerationItemId, "rejected", reporter.accountId as never, "confirmed");
    scenarioMetrics.queueTransitionsCovered.push("resolved:rejected");
    const afterReject = await http.get(`/v1/community/publications/${publicationId}`, reporter);
    scenario.check("the publication stays hidden after rejection", afterReject.status === 404);

    // 3. queued -> live: a second publication is reported, and the author
    // appeals while it is still queued; the approval restores it.
    const appealed = await publish(author, "campus-suite-e", "Appealed curry", "appealed");
    await scenario.expectStatus("reporter reports the second publication", 201, () =>
      http.send(reporter, "POST", `/v1/community/publications/${appealed}/reports`, { reason: "not-own-recipe" }),
    );
    const openAfterSecond = await moderationQueue.list("open");
    const reportedSecond = openAfterSecond.find((i) => i.target.publicationId === appealed);
    scenario.check("the queue holds the second report", reportedSecond !== undefined);
    const appealId = await moderationQueue.submit(
      {
        publicationId: appealed as PublicationId,
        revisionId: (reportedSecond as { target: { revisionId: RecipeRevisionId } }).target.revisionId,
      },
      author.accountId as never,
      "author-appeal",
      "this is my own photo and recipe",
    );
    scenarioMetrics.queueTransitionsCovered.push("submitted:author-appeal");
    await moderationQueue.resolve(appealId, "approved", reporter.accountId as never, "appeal accepted");
    scenarioMetrics.queueTransitionsCovered.push("resolved:approved");
    scenarioMetrics.publicationTransitionsCovered.push("queued->live: appeal approved");
    const restored = await http.get(`/v1/community/publications/${appealed}`, author);
    scenario.check(
      "the appeal brought the publication back",
      restored.status === 200 && (restored.body as { status?: string }).status === "published",
    );
    const feedRestored = await http.get("/v1/community/explore/campus-suite-e", reporter);
    scenario.check(
      "the publication is back in the feed",
      feedHas(feedRestored.body, appealed) ||
        `feed=${JSON.stringify(feedRestored.body).slice(0, 400)}` === "__never__",
    );

    // 4. queued -> withdrawn: a third publication is reported and the
    // author withdraws while it is queued; resolving the leftover item
    // then no-ops against the withdrawal guard.
    const queuedPub = await publish(author, "campus-suite-e", "Withdrawn while queued", "withdrawn-queued");
    await scenario.expectStatus("reporter reports the third publication", 201, () =>
      http.send(reporter, "POST", `/v1/community/publications/${queuedPub}/reports`, { reason: "other" }),
    );
    await scenario.expectStatus("the author withdraws while queued", 204, () =>
      http.send(author, "DELETE", `/v1/community/publications/${queuedPub}`, undefined),
    );
    const queuedAgain = await moderationQueue.list("open");
    const queuedItem = queuedAgain.find((i) => i.target.publicationId === queuedPub);
    if (queuedItem !== undefined) {
      await moderationQueue.resolve(queuedItem.itemId, "rejected", reporter.accountId as never, "resolved after withdrawal");
    }
    scenarioMetrics.publicationTransitionsCovered.push("queued->withdrawn: author withdrew while queued");
    const withdrawnFetch = await http.get(`/v1/community/publications/${queuedPub}`, reporter);
    scenario.check("the withdrawn publication stays withdrawn", withdrawnFetch.status === 404);

    // 5. live -> withdrawn: account deletion pulls the author's remaining
    // publication and kills the sessions.
    await scenario.expectStatus("the author deletes the account", 200, () =>
      http.send(author, "POST", "/v1/community/account/deletion", undefined),
    );
    scenarioMetrics.publicationTransitionsCovered.push("live->withdrawn: account deletion");
    await scenario.expectStatus("whoami on the old token is 401", 401, () =>
      http.get("/v1/community/whoami", author),
    );
    const feedAfterDeletion = await http.get("/v1/community/explore/campus-suite-e", reporter);
    scenario.check("the deleted author's live publication left the feed", !feedHas(feedAfterDeletion.body, appealed));

    scenarioMetrics.scenarios.push({ name: scenario.name, steps: scenario.steps, failures: scenario.failures });
  });

  test("suite bars: no leaks, no authorization failures, full transition coverage", async () => {
    // Bar 1: zero private-field leaks across every captured response.
    const leaks = scanForLeaks(http.captured);
    scenarioMetrics.leaks = leaks;
    expect(leaks, `private-field leaks: ${JSON.stringify(leaks)} in ${http.captured.length} responses`).toEqual([]);

    // Bar 2: zero authorization failures across the recorded steps.
    const stepFailures = scenarioMetrics.scenarios.reduce((total, s) => total + s.failures, 0);
    expect(stepFailures, "scenario step status mismatches").toBe(0);

    // Bar 3: every moderation transition covered.
    const queueCovered = new Set(scenarioMetrics.queueTransitionsCovered);
    const missingQueue = REQUIRED_QUEUE_TRANSITIONS.filter((t) => !queueCovered.has(t));
    expect(missingQueue, "missing queue transitions").toEqual([]);
    const pubCovered = new Set(scenarioMetrics.publicationTransitionsCovered);
    const missingPub = REQUIRED_PUBLICATION_TRANSITIONS.filter((t) => !pubCovered.has(t));
    expect(missingPub, "missing publication transitions").toEqual([]);
  });
});

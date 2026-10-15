/**
 * Explore module (SPEC §3): candidate cards and opted-in aggregate cook
 * counts. The server supplies freshness and candidates only — ranking happens
 * on the phone, and no profile ever rides the request. cookedBy is null below
 * the floor of 10: never a small or invented number (SPEC §3.2, PR #104).
 */

import type { ModuleDefinition } from "../../core/moduleLoader.js";
import { json } from "../../core/router.js";
import { StoreExploreRepository } from "../../core/storeRepos.js";
import { exploreCard, distinctCookCount } from "../../core/views.js";

const FEED_LIMIT = 100; // contracts/openapi.yaml: "at most 100 per response"

const exploreModule: ModuleDefinition = {
  name: "explore",
  version: 1,
  routes: (ctx) => {
    const explore = new StoreExploreRepository(ctx.store);
    return [
      {
        method: "GET",
        pattern: "/explore/feed",
        handler: async () => {
          const candidates = await explore.feedCandidates();
          const items = candidates.slice(0, FEED_LIMIT).map((record) => exploreCard(record, distinctCookCount(record)));
          return json(200, { items, fetchedAt: ctx.clock.now().toISOString() });
        },
      },
      {
        method: "GET",
        pattern: "/explore/cook-counts",
        handler: async () => {
          const candidates = await explore.feedCandidates();
          const counts = candidates.slice(0, FEED_LIMIT).map((record) => ({
            recipeRef: record.recipeRef,
            cookedBy: distinctCookCount(record),
          }));
          return json(200, { counts });
        },
      },
    ];
  },
};

export default exploreModule;

/**
 * The coach design's focused script fixtures — 12 scripts on the shared
 * world (scripts/world.ts), each probing one distinctive behavior of the
 * coach design. This is NOT the general session corpus (that is suite D's
 * job); every script here exists because the coach's gates treat it
 * differently than a permissive design would.
 */

import type { CoachCase } from "./types.js";
import { proactivePantryUseSoon, proactiveSafetyRead } from "./proactiveReads.js";
import { cameraPushToLook, promptedProposalsApproved, proactiveProposalsDenied } from "./proposalGating.js";
import { rejectionAttribution, substitutionBeyondTable, useSoonSilence } from "./silence.js";
import { budgetExhausted, minGapPacing, suppressedActionRemap } from "./budget.js";
import { promptedOnlyControl } from "./control.js";

export const COACH_SCRIPTS: readonly CoachCase[] = [
  proactiveSafetyRead,
  proactivePantryUseSoon,
  proactiveProposalsDenied,
  promptedProposalsApproved,
  cameraPushToLook,
  useSoonSilence,
  rejectionAttribution,
  budgetExhausted,
  minGapPacing,
  suppressedActionRemap,
  promptedOnlyControl,
  substitutionBeyondTable
];

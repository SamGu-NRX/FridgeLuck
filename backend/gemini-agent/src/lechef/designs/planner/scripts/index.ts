/**
 * Registry of the planner's design scripts — every fixture this design
 * probes itself with, each a focused SessionScript plus its expected
 * replay shape. Twelve focused probes, not a corpus: the general
 * plan/substitute/coach/adapt/remember corpus belongs to suite D.
 */

import type { PlannerScriptFixture } from "./expectations.js";
import {
  planOpenBatchKept,
  planOpenBatchThenMidcookSuppressed,
  planPromptedOnlyControl,
  planReadBurst
} from "./opening-batch.js";
import { planUserDrivenBudgetStress, planPitchRejectionSilence, timerOfferSilenceScoped } from "./suggestion-silence.js";
import {
  rememberCloseMeallogApproved,
  rememberCloseMeallogProactiveDenied,
  rememberMeallogSilenceAfterTwo
} from "./remember-close.js";
import { planTimersSurviveKill, planTimerApprovalModes } from "./timers.js";

/** Built once per import — fixtures are pure and deterministic. */
export const PLANNER_SCRIPTS: readonly PlannerScriptFixture[] = [
  planOpenBatchKept(),
  planOpenBatchThenMidcookSuppressed(),
  planPromptedOnlyControl(),
  planReadBurst(),
  planUserDrivenBudgetStress(),
  planPitchRejectionSilence(),
  timerOfferSilenceScoped(),
  rememberCloseMeallogApproved(),
  rememberCloseMeallogProactiveDenied(),
  rememberMeallogSilenceAfterTwo(),
  planTimersSurviveKill(),
  planTimerApprovalModes()
];

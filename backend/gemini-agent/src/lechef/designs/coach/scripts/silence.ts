/**
 * Third-rejection-silence fixtures — after two user rejections of a
 * suggestion type, further suggestions of that type are suppressed for the
 * session; other types still flow, and only explicit no-ish openers
 * directly after a KEPT suggestion accrue rejections.
 */

import type { CoachCase } from "./types.js";
import { call, coachScript, turn } from "./world.js";

/** coach-006 — a third use-soon after two rejections is silenced; safety still flows. */
export const useSoonSilence: CoachCase = {
  name: "coach-006-use-soon-silence",
  focus: "the third use-soon after two rejections is suggestion-type-silenced, while a safety suggestion still flows",
  script: coachScript({
    sessionId: "coach-006",
    turns: [
      turn(0, "assistant", "use-soon: the spinach — oldest bag in the pantry, and step 4 wilts it in.", {
        toolCalls: [call("c-pantry", "getPantrySummary")]
      }),
      turn(1, "user", "no", { audioSeconds: 0.4 }),
      turn(2, "assistant", "use-soon: it really is turning — last time I'll mention it."),
      turn(3, "user", "not interested", { audioSeconds: 0.5 }),
      turn(4, "assistant", "use-soon: the spinach—"),
      turn(5, "user", "fine, let's move on", { audioSeconds: 0.9 }),
      turn(6, "assistant", "safety: the chicken still needs to read 74 °C before step 4.", {
        toolCalls: [call("c-fs", "checkFoodSafety", { product: "chicken" })]
      })
    ]
  }),
  expect: {
    suppressed: [{ turn: 4, because: "suggestion-type-silenced" }],
    keptTurns: [0, 1, 2, 3, 5, 6],
    toolStatus: [
      { id: "c-pantry", status: "ok" },
      { id: "c-fs", status: "ok" }
    ],
    donenessTemps: [74],
    silencedTypes: ["use-soon"],
    usageTurns: 6
  }
};

/** coach-007 — rejection attribution: non-rejections between suggestions never accrue. */
export const rejectionAttribution: CoachCase = {
  name: "coach-007-rejection-attribution",
  focus: "a non-rejection question between suggestions resets attribution, so only the two real rejections silence the third attempt",
  script: coachScript({
    sessionId: "coach-007",
    turns: [
      turn(0, "assistant", "use-soon: the spinach, oldest bag in the pantry.", {
        toolCalls: [call("c-pantry", "getPantrySummary")]
      }),
      turn(1, "user", "how long do I have on it?", { audioSeconds: 1.1 }),
      turn(2, "assistant", "use-soon: about two days — it's step 4's wilt."),
      turn(3, "user", "no", { audioSeconds: 0.3 }),
      turn(4, "assistant", "use-soon: noted — last mention."),
      turn(5, "user", "no thanks", { audioSeconds: 0.4 }),
      turn(6, "assistant", "use-soon: the spinach—"),
      turn(7, "user", "stop", { audioSeconds: 0.3 }),
      turn(8, "assistant", "safety: chicken needs 74 °C at the thickest piece.", {
        toolCalls: [call("c-fs", "checkFoodSafety", { product: "chicken" })]
      })
    ]
  }),
  expect: {
    // turn 4 KEPT is the attribution pin: if the question at turn 1 had
    // wrongly accrued, use-soon would already be silenced here.
    suppressed: [{ turn: 6, because: "suggestion-type-silenced" }],
    keptTurns: [0, 1, 2, 3, 4, 5, 7, 8],
    toolStatus: [
      { id: "c-pantry", status: "ok" },
      { id: "c-fs", status: "ok" }
    ],
    donenessTemps: [74],
    silencedTypes: ["use-soon"],
    usageTurns: 8
  }
};

/** coach-012 — substitution suggestions silence independently; the lookup is an explicit beyond-table unknown. */
export const substitutionBeyondTable: CoachCase = {
  name: "coach-012-substitution-beyond-table",
  focus: "a substitution suggestion grounded in an absent-table lookup silences after two rejections, like any other type",
  script: coachScript({
    sessionId: "coach-012",
    job: "substitute",
    turns: [
      turn(0, "user", "I'm out of lime for the stir-fry", { audioSeconds: 1.3 }),
      turn(1, "assistant", "substitution: no reviewed swap for lime on file yet (the table is absent on alpha) — there is lemon in your pantry, and it dresses the same.", {
        toolCalls: [call("c-sub", "lookupSubstitution", { ingredient: "lime" })]
      }),
      turn(2, "user", "no", { audioSeconds: 0.3 }),
      turn(3, "assistant", "substitution: lemon, then — half the juice, a little sharper."),
      turn(4, "user", "no thanks", { audioSeconds: 0.5 }),
      turn(5, "assistant", "substitution: just the lime, then—")
    ]
  }),
  expect: {
    suppressed: [{ turn: 5, because: "suggestion-type-silenced" }],
    keptTurns: [0, 1, 2, 3, 4],
    toolStatus: [{ id: "c-sub", status: "ok" }],
    otherAnswers: 1,
    silencedTypes: ["substitution"],
    usageTurns: 5
  }
};

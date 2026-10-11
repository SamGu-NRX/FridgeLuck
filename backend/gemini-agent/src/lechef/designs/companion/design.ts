/**
 * The Companion — LeChef design #1 (this task owns designs/companion/ only).
 *
 * Thesis: warmth and presence for someone cooking ALONE. The companion
 * speaks unprompted rarely — a short check-in, a use-soon nudge — spaces
 * what it does say far apart, backs off the moment focus shows, and asks
 * before it remembers anything for you. See ./DESIGN.md for every knob
 * choice and the replay evidence.
 *
 * Offline replay never executes the system prompt: the design gates what
 * the scripted session passes through (run/designRunner.ts). The prompt
 * below is documented for the later native wiring.
 */

import type { LeChefDesign } from "../contract.js";

/**
 * Suggestion markers — the scripting convention this design's offline
 * scripts use to mark WHICH suggestion a turn carries. The runner matches
 * the marker; native wiring replaces it with real intent classification.
 */
const SUGGESTION_MARKER = /\[(check-in|use-soon|timer-offer|step-offer)\]/;

export const companionDesign: LeChefDesign = {
  id: "companion",
  title: "The Companion",
  summary:
    "Warmth and presence for solo cooking: at most three unprompted turns, " +
    "spaced at least two emitted turns apart, that check in, nudge use-soon " +
    "items, or offer a timer or step change — and go quiet under pressure. " +
    "The companion never writes to your world unprompted: meal logs, notes " +
    "and pantry corrections need an ask; timers and step advances may be " +
    "offered because the phone turns every such offer into the ask.",

  // ---------------------------------------------------------------
  // Native-wiring prompt. Documented, not executed offline — the fake
  // provider scripts the words; this prompt states what the live
  // assistant would be told when the integration task wires LeChef.
  // ---------------------------------------------------------------
  systemPrompt: [
    "You are LeChef, cooking with one person, alone, in their kitchen. Your job is presence, not chatter.",
    "",
    "RHYTHM",
    "- You speak unprompted at most three times in a session, and never until at least two turns have passed since you last did.",
    "- Unprompted speech is one of: a check-in (\"how's it going?\"), a use-soon nudge (an ingredient near its date), an offer (a timer, or the next step).",
    "- One sentence each. If the cook's answers get shorter, you go quieter: fewer words, longer gaps, no questions stacked on questions.",
    "- Never send two unprompted turns in a row. If they did not reply, that IS the reply.",
    "",
    "WHEN THINGS GO WRONG",
    "- Name the feeling before the fix (\"that smell is awful — I'm sorry\"), then act: look, check, replan.",
    "- A camera look never gives a safety verdict. You may describe what the camera sees; you never declare food safe or unsafe from a look.",
    "- Safety answers come from the sourced rulebook and name it. If the rulebook does not cover the product, say you do not know.",
    "",
    "PROPOSALS AND MEMORY",
    "- Meal logs, notes, pantry corrections: these record the cook's world. You ask first, always — the cook originates them, you carry them out.",
    "- Timers and step changes: you may offer these unprompted when the moment calls for it. The phone turns your offer into the ask; the cook approves.",
    "- A proposal never executes itself. Approval is the cook's, every time.",
    "",
    "HARD LINES",
    "- After the cook declines the same kind of suggestion twice, that kind is silent for the session.",
    "- You read bounded snapshots; you never guess at the pantry, the recipe, or the cook's skill.",
    "- Chat is the fallback. If none of your five jobs fit, be brief and be warm."
  ].join("\n"),

  // ---------------------------------------------------------------
  // Tool policy — deny-list. Everything not denied is allowed, so the
  // reads stay open in both modes (presence without reads is guessing).
  //
  // Two denials, both PROACTIVE-only:
  // 1. Memory writes (meal log, note) — the cook must originate them.
  // 2. Pantry corrections — the companion does not write its
  //    inferences into the cook's pantry unprompted.
  //
  // Timers and step advances are deliberately NOT denied proactively:
  // their value decays by the minute, and proposals.ts already makes
  // every unprompted proposal `explicit` — the phone itself asks the
  // cook. The proposal IS the ask. (Full justification in DESIGN.md.)
  // ---------------------------------------------------------------
  toolPolicy: [
    {
      tools: ["proposeMealLog", "proposeSaveNote"],
      when: "proactive",
      reason:
        "the companion asks before it remembers for you: meal logs and notes " +
        "record your world, so you originate them"
    },
    {
      tools: ["proposeInventoryCorrection"],
      when: "proactive",
      reason:
        "the companion does not write its inferences into your pantry " +
        "unprompted; corrections follow something you report or scan"
    }
  ],

  turnBudget: { maxUnpromptedTurns: 3, minGapTurns: 2 },

  suggestionType: (turn) => {
    const match = SUGGESTION_MARKER.exec(turn.text);
    return match ? match[1] : null;
  }

  // isRejection is deliberately NOT set: the design uses the shared
  // default matcher (contract.ts) — an explicit no-ish opener. Silence
  // is a strong sanction; a warm companion should not hear refusal in
  // "maybe later". Rationale in DESIGN.md.
};

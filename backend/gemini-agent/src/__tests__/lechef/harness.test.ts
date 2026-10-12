import { describe, it, expect, afterAll } from "bun:test";
import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { runSession, buildSessionWorld } from "../../lechef/run/harness.js";
import { main as cliMain } from "../../lechef/run/cli.js";
import { estimateTokens } from "../../lechef/fakeModel.js";
import type { SessionScript } from "../../lechef/fakeModel.js";

const TMP = "/tmp/lechef-harness-test";

const SCRIPT: SessionScript = {
  sessionId: "s-eggs-01",
  job: "coach",
  cameraMode: "push-to-look",
  design: "design-a",
  fixture: {
    nowIso: "2026-01-01T18:00:00.000Z",
    pantry: [
      { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 6, unit: "piece" }, state: "sufficient", source: "scan" },
      { ingredientId: "bread", name: "Bread", quantity: { kind: "known", value: 4, unit: "piece" }, state: "sufficient", source: "scan" }
    ],
    session: { recipeId: "eggs-on-toast", state: "cooking", currentStepIndex: 0 },
    recipes: [
      {
        id: "eggs-on-toast",
        revision: 1,
        servings: 2,
        ingredientBill: [
          { ingredientId: "egg", name: "Eggs", quantity: { kind: "known", value: 4, unit: "piece" } },
          { ingredientId: "bread", name: "Bread", quantity: { kind: "known", value: 2, unit: "piece" } }
        ],
        steps: [
          { index: 0, text: "Boil the eggs" },
          { index: 1, text: "Toast the bread", timerMinutes: 3 },
          { index: 2, text: "Assemble" }
        ]
      }
    ],
    camera: {
      framesPerLook: 2,
      clipSeconds: 3,
      observed: ["pan on the stove"],
      cannotAssess: ["egg doneness"]
    }
  },
  turns: [
    { i: 0, role: "user", text: "Can we make something with these eggs?", audioSeconds: 3.5 },
    {
      i: 1,
      role: "assistant",
      text: "Eggs on toast works — you have everything. Starting a 9 minute egg timer as you asked.",
      toolCalls: [
        { id: "call-1", name: "getRecipeCandidates", args: { goal: "eggs on toast" } },
        { id: "call-1", name: "getRecipeCandidates", args: { goal: "eggs on toast" } }, // replayed id
        { id: "call-2", name: "proposeTimerStart", args: { label: "eggs", minutes: 9, deviceEventId: "cmd-0001" } },
        { id: "call-2", name: "proposeTimerStart", args: { label: "eggs", minutes: 9, deviceEventId: "cmd-0001" } }, // replayed id
        { id: "call-3", name: "proposeSaveNote", args: { text: "liked the toast very dark", scope: "cook" } },
        { id: "call-4", name: "proposeSaveNote", args: { text: "cancelled mid-flight", scope: "cook" } }
      ],
      cancelled: ["call-4"],
      prompted: false
    },
    { i: 2, role: "user", text: "Is the chicken safe to eat yet?" },
    {
      i: 3,
      role: "assistant",
      text: "Let me check and take one look at the pan.",
      toolCalls: [
        { id: "call-5", name: "checkFoodSafety", args: { product: "chicken thigh", question: "is it done" } },
        { id: "call-6", name: "requestCameraLook", args: { maxClipSeconds: 3 } }
      ],
      prompted: true
    }
  ],
  userActions: [
    { afterTurn: 0, action: { kind: "advanceMinutes", minutes: 1 } }, // connected time
    { afterTurn: 1, action: { kind: "approve", callId: "call-3" } },
    { afterTurn: 1, action: { kind: "kill" } },
    { afterTurn: 1, action: { kind: "advanceMinutes", minutes: 5 } }, // elapsed while killed
    { afterTurn: 2, action: { kind: "resume" } },
    { afterTurn: 3, action: { kind: "advanceMinutes", minutes: 1 } } // connected time
  ]
};

const RUN_KEYS = [
  "sessionId",
  "job",
  "cameraMode",
  "design",
  "turns",
  "toolCalls",
  "proposals",
  "receipts",
  "timers",
  "events",
  "answers",
  "camera",
  "usage"
] as const;

describe("harness: RunRecord assembly", () => {
  // The timer call cites the device event the phone recorded before the run —
  // a bare userInitiated flag in tool arguments is never trusted (SPEC 4).
  const world = buildSessionWorld(SCRIPT);
  world.phone.recordUserCommand({ command: "proposeTimerStart", source: "voice", detail: "start a nine minute egg timer" });
  const record = runSession(SCRIPT, world);

  it("emits exactly the pinned top-level keys, nothing scored", () => {
    expect(Object.keys(record).sort()).toEqual([...RUN_KEYS].sort());
    const blob = JSON.stringify(record);
    // Raw records only: no job success, no approval judgement, no scoring.
    expect(blob).not.toMatch(/"(jobSuccess|score|passed|approvalJudgement)"/);
  });

  it("records turns with call ids and prompted flags", () => {
    expect(record.turns).toHaveLength(4);
    expect(record.turns[1].toolCallIds).toEqual(["call-1", "call-1", "call-2", "call-2", "call-3", "call-4"]);
    expect(record.turns[3].prompted).toBe(true);
  });

  it("marks replayed call ids as duplicates and cancelled calls as cancelled", () => {
    const byId = new Map(record.toolCalls.map((c) => [c.id, c]));
    expect(byId.get("call-1")!.status).toBe("ok");
    expect(byId.get("call-2")!.status).toBe("duplicate");
    expect(byId.get("call-2")!.dupOf).toBeDefined();
    expect(byId.get("call-4")!.status).toBe("cancelled");
  });

  it("a cancelled call never produced a proposal; duplicates never doubled one", () => {
    expect(record.proposals).toHaveLength(2); // timer (device-auto) + note (explicit)
    const note = record.proposals.find((p) => p.tool === "proposeSaveNote")!;
    expect(note.requiredApproval).toBe("explicit");
    const timer = record.proposals.find((p) => p.tool === "proposeTimerStart")!;
    expect(timer.requiredApproval).toBe("device-auto");
    expect(timer.userInitiated).toBe(true);
  });

  it("maps receipts with ISO timestamps after the scripted approval", () => {
    expect(record.receipts.map((r) => r.state)).toContain("executed");
    for (const r of record.receipts) expect(r.recordedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it("survives the scripted kill with timer deadlines intact", () => {
    expect(record.timers).toHaveLength(1);
    const timer = record.timers[0];
    expect(timer.label).toBe("eggs");
    expect(timer.survivedKill).toBe(true);
    // Timer created at 18:01 (after the first advanceMinutes), 9 minutes long.
    expect(timer.deadline).toBe("2026-01-01T18:10:00.000Z");
    expect(timer.firedAt).toBeUndefined();
  });

  it("streams doneness answers with sourced checks", () => {
    expect(record.answers).toHaveLength(1);
    const answer = record.answers[0];
    expect(answer.type).toBe("doneness");
    expect(answer.sourcedCheck).not.toBeNull();
    expect(answer.sourcedCheck!.temperatureC).toBe(74);
    expect(answer.sourcedCheck!.source).toMatch(/USDA FSIS/);
  });

  it("camera events carry observations and a null verdict", () => {
    expect(record.camera).toHaveLength(1);
    const look = record.camera[0];
    expect(look.look).toBe(true);
    expect(look.framesSent).toBe(2);
    expect(look.clipSeconds).toBeLessThanOrEqual(3);
    expect(look.safetyVerdict).toBeNull();
  });

  it("accounts usage from script events: tokens estimated at ceil(chars/4), killed intervals excluded", () => {
    const userTokens = SCRIPT.turns.filter((t) => t.role === "user").reduce((sum, t) => sum + estimateTokens(t.text), 0);
    const assistantTokens = SCRIPT.turns.filter((t) => t.role === "assistant").reduce((sum, t) => sum + estimateTokens(t.text), 0);
    expect(userTokens).toBeGreaterThan(0);
    expect(record.usage.audioSeconds).toBe(3.5);
    expect(record.usage.framesSent).toBe(2);
    // Total elapsed 7 min (1 + 5 + 1); 5 min of that elapsed while killed → 120 connected seconds.
    expect(record.usage.connectedSeconds).toBe(120);
    expect(record.usage.textTokensIn).toBe(userTokens);
    expect(record.usage.textTokensOut).toBe(assistantTokens);
  });
});

describe("harness CLI", () => {
  afterAll(() => {
    rmSync(TMP, { recursive: true, force: true });
  });

  it("runs a session script file and writes its RunRecord", () => {
    const sessionsDir = join(TMP, "sessions");
    const outDir = join(TMP, "out");
    mkdirSync(sessionsDir, { recursive: true });
    writeFileSync(join(sessionsDir, "s-eggs-01.json"), JSON.stringify(SCRIPT));
    const code = cliMain([`--sessions=${sessionsDir}`, `--out=${outDir}`, "--pretty"]);
    expect(code).toBe(0);
    const recordPath = join(outDir, "s-eggs-01.json");
    expect(existsSync(recordPath)).toBe(true);
    const record = JSON.parse(readFileSync(recordPath, "utf8"));
    expect(Object.keys(record).sort()).toEqual([...RUN_KEYS].sort());
  });

  it("supports --design to relabel a script for design-x-session runs", () => {
    const sessionsDir = join(TMP, "sessions2");
    const outDir = join(TMP, "out2");
    mkdirSync(sessionsDir, { recursive: true });
    writeFileSync(join(sessionsDir, "s-eggs-01.json"), JSON.stringify(SCRIPT));
    const code = cliMain([`--sessions=${sessionsDir}`, `--out=${outDir}`, "--design=design-z"]);
    expect(code).toBe(0);
    const record = JSON.parse(readFileSync(join(outDir, "s-eggs-01.json"), "utf8"));
    expect(record.design).toBe("design-z");
  });

  it("fails closed on malformed scripts", () => {
    const sessionsDir = join(TMP, "sessions3");
    const outDir = join(TMP, "out3");
    mkdirSync(sessionsDir, { recursive: true });
    writeFileSync(join(sessionsDir, "bad.json"), JSON.stringify({ sessionId: "x" }));
    const code = cliMain([`--sessions=${sessionsDir}`, `--out=${outDir}`]);
    expect(code).toBe(1);
    expect(existsSync(join(outDir, "x.json"))).toBe(false);
  });
});

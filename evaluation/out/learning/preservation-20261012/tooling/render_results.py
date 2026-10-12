#!/usr/bin/env python3
"""Render RESULTS.md for the post-seam suite-B campaign.

Reads /home/user/work/postseam-out/{results,gate,arms,manifest,PROVENANCE}.json.
Writes /home/user/work/RESULTS-postseam.md.

CI conventions (documented in the output):
- Per-arm headline rows: bootstrap over the 6 seed values, B=10,000,
  numpy PCG64 seed 0, percentile interval.
- Activation-gate CIs: the Swift paired bootstrap from gate.json
  (preregistered); the paired lifts are recomputed here as a cross-check.
- Per-regime cells: bootstrap over the per-seed regime means, same
  B/seed convention.
"""
import json
import sys

import numpy as np

CAMP = sys.argv[1] if len(sys.argv) > 1 else "/home/user/work/postseam-out"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/home/user/work/RESULTS-postseam.md"

rng = np.random.default_rng(0)
B = 10_000

results = json.load(open(f"{CAMP}/results.json"))
gate = json.load(open(f"{CAMP}/gate.json"))
arms_raw = json.load(open(f"{CAMP}/arms.json"))
arms_meta = {a["id"]: a for a in (arms_raw if isinstance(arms_raw, list) else arms_raw["arms"])}
manifest = json.load(open(f"{CAMP}/manifest.json"))
try:
    prov = json.load(open(f"{CAMP}/PROVENANCE.json"))
except FileNotFoundError:
    prov = {}

ARM_ORDER = [
    "rule-port", "profile-only", "popularity", "random",
    "trust-vector", "logistic-l2", "pairwise-ltr", "embedding",
    "engine", "engine-no-exploration", "engine-no-exposure", "engine-no-recency",
]
FAMILY = {a: arms_meta.get(a, {}).get("family", "") for a in ARM_ORDER}

REGIMES = [
    "baseline", "sparse-feedback", "slow-drift", "two-eater", "abrupt-shift",
    "exposure-bias", "rule-blind",
]

rows_by_arm = {}
for r in results:
    rows_by_arm.setdefault(r["arm"], []).append(r)
for v in rows_by_arm.values():
    v.sort(key=lambda r: r["seed"])


def ci95(values):
    vals = np.asarray(values, dtype=float)
    if len(vals) < 2:
        return (float("nan"), float("nan"))
    idx = rng.integers(0, len(vals), size=(B, len(vals)))
    means = vals[idx].mean(axis=1)
    return tuple(np.percentile(means, [2.5, 97.5]))


def fmt(x, nd=4):
    return f"{x:.{nd}f}"


out = []

# ---------------------------------------------------------------- header
seeds = sorted({r["seed"] for r in results})
n_hh = sum(r["households"] for r in results) // len(ARM_ORDER)
out.append("# FLTaste suite B — campaign results (post-seam reduced grid)\n")
out.append(f"- Run identity: `{manifest.get('runId', '?')}` — commit `{manifest.get('commit', '?')}` "
           f"on branch `{manifest.get('branch', '?')}` (dirty files hashed in PROVENANCE.json).")
out.append(f"- Scale executed: **{n_hh} households × {len(seeds)} seeds × {len(ARM_ORDER)} arms × 13 weeks**, "
           f"7-regime wheel (baseline, sparse-feedback, slow-drift, two-eater, abrupt-shift, exposure-bias, rule-blind).")
out.append("- Metrics version 4: independent fail-closed restriction evaluation aligned to the "
           "simulator's enforcement granularity — a never-suggest mute emitted in week w counts "
           "against slates in weeks > w (Sim snapshots the mute into its week-start candidate "
           "filter, so same-week enforcement is not expressible on the current surface: RankInput "
           "carries no mute); one recovery observation per shift; NDCG@10 ideal over the full "
           "feasible universe.")
out.append("- **Superseded numbers are not shown.** The pre-seam reduced grid (ranker-visible inputs "
           "before the sealed RankerCandidate seam, metrics v2) was invalidated by the seam change; "
           "every number below is the post-seam baseline and replaces it.\n")

# ---------------------------------------------------------------- headline
out.append("## Headline table\n")
out.append("Per-arm means over seeds; 95% CI from bootstrap over seeds (B=10,000, numpy PCG64 seed 0). "
           "viol = independent fail-closed restriction violations (bar: 0 on every arm, every seed).\n")
out.append("| arm | family | NDCG@10 [CI] | viol | recov (med) | regret | exp-regret | tau | hit@10 |")
out.append("|---|---|---|---|---|---|---|---|---|")
for arm in ARM_ORDER:
    if arm not in rows_by_arm:
        continue
    rows = rows_by_arm[arm]
    ndcg = [r["meanNDCG"] for r in rows]
    lo, hi = ci95(ndcg)
    out.append(
        f"| {arm} | {FAMILY[arm]} | {fmt(np.mean(ndcg))} [{fmt(lo)}, {fmt(hi)}] "
        f"| {sum(r['independentRestrictionViolations'] for r in rows)} "
        f"| {np.mean([r['medianRecoveryCooks'] for r in rows]):.2f} "
        f"| {np.mean([r['meanRegret'] for r in rows]):.3f} "
        f"| {np.mean([r['meanExposureRegret'] for r in rows]):.3f} "
        f"| {np.mean([r['meanKendallTau'] for r in rows]):.3f} "
        f"| {np.mean([r['bestInSlateRate'] for r in rows]):.3f} |")

# ---------------------------------------------------------------- trust-vector
tv_mean = eng_mean = rule_mean = float("nan")
tv_rank = 0
if "trust-vector" in rows_by_arm and "engine" in rows_by_arm and "rule-port" in rows_by_arm:
    tv = rows_by_arm["trust-vector"]
    eng = rows_by_arm["engine"]
    rule = rows_by_arm["rule-port"]
    tv_mean = float(np.mean([r["meanNDCG"] for r in tv]))
    eng_mean = float(np.mean([r["meanNDCG"] for r in eng]))
    rule_mean = float(np.mean([r["meanNDCG"] for r in rule]))
    present = [a for a in ARM_ORDER if a in rows_by_arm]
    tv_rank = 1 + sum(1 for a in present if float(np.mean([r["meanNDCG"] for r in rows_by_arm[a]])) > tv_mean)

    out.append("")
    out.append("## The trust-vector arm (Sam's design, family 1)\n")
    out.append(f"The Beta-per-source/feature trust-vector arm is **#{tv_rank} overall by mean NDCG@10** "
               f"({fmt(tv_mean)}) at the executed scale, against the rule port's {fmt(rule_mean)} and the "
               f"engine arm's {fmt(eng_mean)}. Rationale: Beta posteriors converge from few observations, "
               "which matches staged replay's sparse effective data; per-source shrinkage gives it the rule "
               "ranker's structure as a prior without hard-coding the rules.\n")

# ---------------------------------------------------------------- gate
out.append("## Activation gate\n")
vr, vp = gate["versusRule"], gate["versusProfileOnly"]


def lift_row(label, g):
    return (
        f"| {label} | {g['baselineArm']} | {g['meanRelativeLift']*100:+.2f}% "
        f"| [{g['ciLow']*100:+.2f}%, {g['ciHigh']*100:+.2f}%] "
        f"| {'YES' if g['gateLowMet'] else 'NO'} |")


out.append("Relative NDCG@10 lift of the engine arm vs each required bar; Swift paired bootstrap CIs "
           "from gate.json (paired on identical households and seeds). The gate needs the interval LOW "
           ">= +10% relative on BOTH comparisons.\n")
out.append("| comparison | baseline arm | mean rel. lift | 95% CI | CI-low >= +10%? |")
out.append("|---|---|---|---|---|")
out.append(lift_row("engine vs rule ranker (port)", vr))
out.append(lift_row("engine vs explicit profile-only", vp))
out.append("")
out.append(f"- restriction violations (independent): {gate['restrictionViolations']} (bar: 0) "
           f"-> {'PASS' if gate['noViolations'] else 'FAIL'}")
if "safetyViolations" in gate:
    out.append(f"- safety violations: {gate['safetyViolations']} (bar: 0) "
               f"-> {'PASS' if gate.get('noSafetyViolations', gate['safetyViolations'] == 0) else 'FAIL'}")
if "coverageFailures" in gate:
    out.append(f"- coverage failures: {gate['coverageFailures']} (bar: 0) "
               f"-> {'PASS' if gate.get('noCoverageFailures', gate['coverageFailures'] == 0) else 'FAIL'}")
out.append(f"- median recovery: {gate['medianRecoveryCooks']:.2f} cooks (bar: <= 6) "
           f"-> {'PASS' if gate['recoveryBarMet'] else 'FAIL'}")
out.append("- preregistered scale (5,000 households x 20 seeds): **not-run** "
           f"(reduced grid {n_hh} x {len(seeds)} executed; ~1,600 CPU-hours projected for the full grid "
           "on the 2-core sandbox — weeks of wall time)")
out.append(f"- **activationGateMet: {str(gate['activationGateMet']).upper()}**")

# ---------------------------------------------------------------- cross-check
out.append("")
out.append("### Cross-check: paired lifts recomputed here (must match gate.json within rounding)\n")
if "engine" in rows_by_arm:
    engine_by_seed = {r["seed"]: r["meanNDCG"] for r in rows_by_arm["engine"]}
    for base in ("rule-port", "profile-only"):
        base_by_seed = {r["seed"]: r["meanNDCG"] for r in rows_by_arm[base]}
        seeds_sorted = sorted(engine_by_seed)
        lifts = [engine_by_seed[s] / base_by_seed[s] - 1.0 for s in seeds_sorted]
        lo, hi = ci95(lifts)
        out.append(f"- vs {base}: mean {np.mean(lifts)*100:+.2f}%  CI [{lo*100:+.2f}%, {hi*100:+.2f}%]  "
                   f"per-seed {[round(l*100, 2) for l in lifts]}")

# ---------------------------------------------------------------- regimes
out.append("")
out.append("## Per-regime breakdown (with intervals)\n")
out.append("Each regime is a wheel leg; arms are compared on identical seeds within a regime. "
           "The paired-seed regime comparison (SIM-ASSUMPTIONS §12): the rule port should stay "
           "competitive on visible-driver regimes and lose on rule-blind — that gap is the learning "
           "signal this suite measures. Cells: mean NDCG@10 [95% CI] over seeds.\n")
out.append("| arm | " + " | ".join(REGIMES) + " |")
out.append("|---|" + "---|" * len(REGIMES))
for arm in ARM_ORDER:
    if arm not in rows_by_arm:
        continue
    rows = rows_by_arm[arm]
    cells = []
    for reg in REGIMES:
        vals = [r["perRegime"][reg]["meanNDCG"] for r in rows if reg in r.get("perRegime", {})]
        if vals:
            lo, hi = ci95(vals)
            cells.append(f"{fmt(np.mean(vals), 3)} [{fmt(lo, 3)}, {fmt(hi, 3)}]")
        else:
            cells.append("n/a")
    out.append(f"| {arm} | " + " | ".join(cells) + " |")

# ---------------------------------------------------------------- recovery
out.append("")
out.append("## Recovery after the diet shift\n")
out.append("Cooks-to-recovery (utility gap < 0.1 vs the household's best feasible pick), pooled over "
           "seeds; censored = shifts whose recovery window outlived the 13-week horizon.\n")
out.append("| arm | median | p75 | p90 | censored |")
out.append("|---|---|---|---|---|")
for arm in ARM_ORDER:
    if arm not in rows_by_arm:
        continue
    rows = rows_by_arm[arm]
    pooled = []
    censored = 0
    for r in rows:
        pooled.extend(r["recoveryDistribution"])
        censored += r.get("recoveryCensored", 0)
    if pooled:
        a = np.asarray(pooled, dtype=float)
        out.append(f"| {arm} | {np.median(a):.1f} | {np.percentile(a, 75):.1f} "
                   f"| {np.percentile(a, 90):.1f} | {censored} |")
    else:
        out.append(f"| {arm} | n/a | n/a | n/a | {censored} |")

# ---------------------------------------------------------------- volume
out.append("")
out.append("## Volume and behaviour per arm (sum over seeds)\n")
out.append("| arm | households | ranked sessions | cooked sessions | mean choice rank | repeat rate | fairness gap |")
out.append("|---|---|---|---|---|---|---|")
for arm in ARM_ORDER:
    if arm not in rows_by_arm:
        continue
    rows = rows_by_arm[arm]
    out.append(
        f"| {arm} | {sum(r['households'] for r in rows)} "
        f"| {sum(r['rankedSessions'] for r in rows)} "
        f"| {sum(r['cookedSessions'] for r in rows)} "
        f"| {np.mean([r['meanChoiceRank'] for r in rows]):.2f} "
        f"| {np.mean([r['repeatRate'] for r in rows]):.3f} "
        f"| {np.mean([r['meanFairnessGap'] for r in rows]):.3f} |")

# ---------------------------------------------------------------- inversion
out.append("""
## Known caveat: staged replay and per-decision exploration (inversion hypothesis)

The campaign drives every stateful arm through week-granular staged replay: the
simulator has no per-event feedback hook (an API gap recorded for the review —
`FLTasteSim.Ranker` exposes `rank` + week-boundary `make` only), so an arm's
state is refrozen at week boundaries and each stage replays the whole history
with that frozen state. Per-decision exploration policies (Thompson sampling in
the Bayesian-linear arm and the engine arm) draw a fresh posterior sample per
ranking decision inside the simulator; under staged replay the policy's
realized trajectory is one sample path per stage, and the arm cannot adapt
between sessions within the week. The hypothesis this raises — which the full
campaign can test once the Sim surface grows the hook — is that week-granular
staging starves per-decision exploration relative to a per-event feedback hook,
depressing Thompson-style arms specifically.

- **Confirm** (hypothesis supported): rerunning the campaign with a per-event
  feedback hook (ranker consulted after every cook event, state refrozen per
  event) lifts the engine arm's NDCG@10 materially — toward or above the
  trust-vector arm (pairwise difference outside the seed-level 95% interval in
  the engine's favor).
- **Reject** (hypothesis unsupported): the per-event rerun moves the engine arm
  by an amount whose interval crosses zero relative to the staged-replay
  result, or moves it materially AWAY from the trust-vector arm.

The activation decision should not read the Thompson arms' current disadvantage
as a property of the models themselves; it may be a property of the feedback
granularity this harness could express. A second recorded seam gap: the
rule-port omits alpha's session-context scoring signals the simulator cannot
express.

## Compute profile (R4)

The coordinator's speed objective asked for profiling and an output-preserving
optimization of the campaign hot path, with byte-identical equivalence proof.
What the profile found (EVAL_PROFILE=1, release binary, post-seam):

- Simulation dominates: ~0.9-1.1 s per household for stateless arms, ~8-11 s
  for week-granular staged arms (engine, trust-vector). Scoring is negligible;
  arm-construction ("make") costs concentrate in engine arms (the arm rebuilds
  `TasteEngine` and ingests its full history at every stage).
- The dominant cost is the simulator's own week-granular staged replay —
  repeated full simulations per stage — owned by `FLTasteSim`, and the engine
  refold is owned by `FLTaste.TasteEngine.ingest`. Both are outside this PR's
  file scope (`packages/FLTaste/Eval/**`), and the replay shape is the
  documented no-per-event-hook workaround, not an Eval-side inefficiency.
- Household-level Dispatch parallelism already exists in main.swift; on the
  2-core sandbox with co-tenant load, wall-time comparisons were too noisy to
  attribute to Eval-side changes.
- **Conclusion: no Eval-side optimization ships.** The only measurable in-scope
  costs are the engine make-path refold (Sim/FLTaste-owned) and nothing else of
  material size. Shipping a no-op or an unprovable micro-optimization would
  violate the prove-equivalence-or-don't-ship rule; the profiling harness
  (EVAL_PROFILE=1) ships instead and the gap is documented for the Sim/FLTaste
  owners.

## Honest read

[FILLED AT RENDER TIME — see the rendered verdict below; the parent writes the
final recommendation.]
""")

# ---------------------------------------------------------------- honest read
gate_met = gate["activationGateMet"]
vr_txt = f"{vr['meanRelativeLift']*100:+.2f}% [{vr['ciLow']*100:+.2f}%, {vr['ciHigh']*100:+.2f}%]"
vp_txt = f"{vp['meanRelativeLift']*100:+.2f}% [{vp['ciLow']*100:+.2f}%, {vp['ciHigh']*100:+.2f}%]"
if gate_met:
    verdict = (
        f"At the executed scale the activation gate is MET: the engine arm beats both bars with the "
        f"interval low above +10% relative (vs rule ranker {vr_txt}; vs explicit profile-only {vp_txt}), "
        f"zero independent restriction violations across every arm and seed, and median recovery "
        f"{gate['medianRecoveryCooks']:.2f} cooks (bar <= 6). The gate was evaluated on the reduced "
        f"post-seam grid ({n_hh} households x {len(seeds)} seeds), not the preregistered 5,000 x 20; "
        "the decision should weigh that scale gap and the staged-replay caveat above. The parent "
        "writes the final recommendation.")
else:
    verdict = (
        f"At the executed scale the activation gate is NOT met: the engine arm's relative NDCG@10 lift "
        f"is vs rule ranker {vr_txt} and vs explicit profile-only {vp_txt} — the gate needs both "
        f"interval lows >= +10% relative. Zero independent restriction violations across every arm and "
        f"seed held, and median recovery is {gate['medianRecoveryCooks']:.2f} cooks (bar <= 6). Under "
        "the staged-replay caveat above, the Thompson arms' disadvantage may be a harness artifact "
        "(the inversion hypothesis); a per-event feedback-hook rerun is the designed test. The parent "
        "writes the final recommendation.")
out.append("")

# The template above ends with the placeholder paragraph; splice the real verdict.
# Provenance section must be built BEFORE the join.
out.append("")
out.append("## Reproduction and provenance\n")
out.append("```")
out.append("# Corpus + model state: this repo at the commit above (data.json ships in apps/ios/Resources).")
out.append("cd packages/FLTaste/Eval")
out.append("swift build -c release")
out.append(".build/out/Products/Release-linux-x86_64/fltaste-eval \\")
out.append("  --config custom --households 70 --seeds 6 --weeks 13 --out <dir>")
out.append("# Determinism: same seed set + config + arms => byte-identical metrics (tested).")
out.append("```")
if prov:
    out.append("")
    out.append(f"- Host: {prov.get('host', 'linux x86_64, 2 cores')}; run started "
               f"{prov.get('startedAtUTC', '?')} under tmux `fltaste-postseam`; wall time in the log.")
out.append("")
out.append("Checkpoint files carry the resume fingerprint (config + corpus + code hash + metrics "
           "version); stale checkpoints are rejected, not resumed (R2).")

doc = "\n".join(out)
doc = doc.replace("[FILLED AT RENDER TIME — see the rendered verdict below; the parent writes the\n"
                  "final recommendation.]", verdict)

text = doc + "\n"
open(OUT, "w").write(text)
sys.stdout.write(f"wrote {OUT}\n")

# Fail loudly on ANY nonzero violation field anywhere.
for field in ("restrictionViolations", "independentRestrictionViolations", "coverageFailures"):
    total = sum(r.get(field, 0) for r in results)
    assert total == 0, f"{field} nonzero: {total}"
print(f"asserted 0 violations across all {len(results)} (seed, arm) checkpoints", file=sys.stderr)

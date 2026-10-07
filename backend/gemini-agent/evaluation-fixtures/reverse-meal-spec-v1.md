# Reverse-meal diagnostic family v1

## Target and artifact contract

This specification gives the FridgeLuck product owner a bounded family and replay for the real iOS Bayesian consumer. It supplements, and does not alter, the original 18-case evaluation. Those cases remain exposed cross-language diagnostics. Neither family is an independent holdout or evidence of live product quality.

The target is `ConfidenceLearningService.assess` as called by `ReverseScanService`, against the documented Decisions choice endpoint given the identical current request. The pantry `ConfidenceRouter` is a different target. Backend TypeScript remains a numerical-conformance reference, not the primary product implementation. Decisions remains mock-only until the separately authorized route/access/spend gate is satisfied.

Files in this directory:

- `reverse-meal-states-v1.jsonl`: 16 synthetic snapshots of the state immediately before confidence assessment.
- `reverse-meal-labels-v1.jsonl`: source-conformance annotations and separate synthetic outcome truth. Never give this file to a candidate adapter.
- `reverse-meal-replay-v1.json`: the fixed 12-episode development replay and two declared reward columns.
- `reverse-meal-question-v1.json`: a new choice question for the four-signal reverse-meal request. The old question is unchanged.

All worlds, outcomes and histories are invented, nonprivate and manually assigned by the evaluation author, an AI agent. These are construction assumptions, not human annotations or observed user behavior. They support offline engineering and hypothesis checks. Consequential quality or safety claims require independent outcomes and adjudication.

## Source boundary and state projection

Reference source is under `/Users/samgu/.t3/worktrees/fridgeluck/feat-minimal-product-20261007`, based on commit `1f85e881e7ac7649fb807f86837114ba866117ae`. `apps/ios/Capability/Core/Services/ReverseScanService.swift:244-249,272-341` defines the projection. The inspected producer and learner had no worktree diff. The new confirmation policy and view wiring are uncommitted product-owner work, not part of that commit.

A `producer_state` contains the post-deduplication detection confidences and the final ranked candidate list. Candidate IDs are synthetic handles. Candidate scores are injected post-ranking scores; they are not recomputed by this family from photographs, local recipe scoring or a cloud model. Preserve the supplied final ordering, including ties. This isolates the confidence consumer. The snapshots are not claimed to reproduce the upstream joint distribution or to be reachable through every earlier pipeline stage. In particular, high-score endpoint cases must not become claims about real candidate-search frequency.

Derive the request, without accessing labels, as follows:

1. Convert each detection confidence to IEEE binary32, as `Detection.confidence` is Swift `Float`. Clamp to zero through one, widen to binary64, and compute the mean in array order. Empty detections yield zero.
2. Take the first candidate's `confidence_score`, or zero when absent. Candidate scores are binary64, as in Swift `Double`.
3. Required coverage is top `matched_required / max(total_required, 1)`, or zero when absent.
4. Margin score is zero without candidates, 0.82 with one candidate, or `clamp(0.5 + max(top_score - second_score, 0), 0, 1)` with two or more.
5. Emit these exact signals, in order: `reverse_scan.vision_detection`, weight 0.32, reason `ingredient detection`; `reverse_scan.recipe_match`, 0.30, `recipe match`; `reverse_scan.required_coverage`, 0.23, `required ingredient coverage`; `reverse_scan.candidate_margin`, 0.15, `candidate ambiguity`.
6. Apply the source's first-match hard-failure rule: no candidate gives `No confident recipe candidate.`; otherwise more than two missing required ingredients gives `Too many required ingredients are missing.`; otherwise top-minus-second below 0.06 gives `Top recipe candidates are highly ambiguous.`; otherwise use an empty list. Do not add an epsilon or round scores before this comparison.

An empty scan therefore produces four zero-valued signals plus a hard failure, not the original backend fixture's empty signal array. Only the derived `signals` and `hardFailReasons` go to either candidate. Do not send IDs, counts, labels, proposed quantities, reference outcomes, group names or the whole producer snapshot to Luna. Its `input` is the canonical JSON string of that same request; `questions` contains the new question; `model` is `gpt-6-luna`. No extra tools, history, Responses fields or explanations are added silently.

JSON spelling differences such as `1` and `1.0` are not evidence differences. Compare decoded objects, signal order and finite numeric values; record each implementation's serialized bytes separately. Float32 conversion is intentional, not a serialization tolerance. Cross-language projection and learner scores should use an absolute diagnostic tolerance of 1e-12, with mode and hard-failure strings exactly equal. That tolerance is a proposed numerical convention, not measured accuracy. Any mismatch near a route threshold needs investigation rather than rounding it away.

RM-12 is deliberately a defensive guard test. The current `findMakeable`/`findNearMatch` calls permit at most two missing required ingredients, while the confidence producer also has a greater-than-two guard. The injected case tests that guard and its precedence over ambiguity. Exclude it from product-outcome aggregates. See `ReverseScanService.swift:88-98` and `Platform/Persistence/Repository/RecipeRepository.swift:34-61`.

## Family coverage and reference meaning

There are 16 rows in 11 groups. Twelve rows in seven groups have binary outcome truth: eight correct original proposals and four incorrect. Two rows have no proposal, one has unknown portion evidence, and one is guard-only. Those four rows are not silently labelled incorrect recipe predictions.

| Cases | Question answered |
| --- | --- |
| RM-01, RM-02 | Does absence handling work with no detections versus good detections but no candidate? |
| RM-03, RM-04, RM-13 | Can the evaluator preserve different outcome labels for an identical request without pretending the model can distinguish them? The outcomes are correct proposal, wrong recipe, and wrong servings. |
| RM-05, RM-14 | How much friction does the policy impose when a proposal happens to be correct despite weak evidence? |
| RM-06, RM-16 | Same high-score request, but correct quantity versus a required large-portion edit. |
| RM-07 | Does the producer's ambiguity hard failure remain separate from the fact that the top dish happens to be correct? |
| RM-08 through RM-10 | Does the implementation preserve the strict gap comparison, including binary64 subtraction? These are grouped boundary variants, not three independent meal observations. |
| RM-11, RM-12 | Two missing ingredients versus the defensive greater-than-two guard and first-match precedence. |
| RM-15 | Does unknown portion evidence stay unknown rather than becoming a fabricated success/failure label? |

`expected_hard_fail` is a source-conformance annotation. It is not a quality judgement. On any hard-failure request, the specified learner contract requires estimate-only; both adapters' violations must be reported without postprocessing their answers into compliance. Other modes are obtained from the actual learner and compared across implementations, not declared correct merely because a reference implementation emitted them.

`original_proposal_correct` describes the unchanged top recipe together with the proposed servings and portion. The declared reference recipe/quantity and `required_edit_fields` support field-specific reporting. A true outcome does not imply the model had enough evidence to justify exact mode. The family contains high-score wrong proposals and low-score correct proposals on purpose.

An amount-only false-one-tap opportunity is evidence about missing input or the confirmation design, not proof that a recipe-identity classifier chose the wrong route. The truth-control reward deliberately targets the whole original proposal, so it also penalizes amount errors that the four signals cannot identify; it is not asserted to be the correct production training objective.

The collision groups expose an information limit. RM-03/RM-04/RM-13 have byte-equivalent derived evidence and one correct versus two incorrect outcomes. RM-06/RM-16 have identical evidence and one correct versus one incorrect outcome. A fixed deterministic candidate in the same state cannot route members differently. Stochastic differences are not successful disambiguation. Report groupwise coverage/error trade-offs, never require perfect acceptance of correct members and rejection of wrong members simultaneously. Servings and portion are absent from this input boundary; a better classifier cannot recover those facts from nothing.

The labels are available to engineers and already exposed in this phase. Derived cases cannot become a fresh independent holdout by changing IDs or wording. Keep the groups together in any later partition and collect new outcome evidence for consequential comparisons.

## A0 and the fixed A1 replay

A0 uses the real Swift learner with a fresh, migrated, empty in-memory database per case. A new service object attached to an old database is not cold start. Use the product owner's real migrations rather than inventing a reduced schema that hides persistence behavior.

A1-proxy uses a fresh migrated database per case, then replays `reverse-meal-dev-v1` in its declared episode order. For each episode, project its state using the same function as evaluation inputs, call `assess`, then call `recordOutcome` once with that assessment and `proxy_reward`. Use a stable development context key containing the replay version and episode ID. All four signals, with their real weights, are assessed and updated together. There is no extra repetition, no label-dependent replay selection and no learning from the 16 evaluation cases.

The replay has 12 episodes: seven explicit top picks rewarded 0.96, two non-top picks rewarded 0.78, and three manual picks rewarded 0.45. It includes choosing an incorrect top dish, correcting a wrong top proposal through another selection, and manually reselecting a correct top dish. The state D1 is deliberately reused with different hidden truth in RMD-01/RMD-02. All development requests are distinct from evaluation requests after projection, but that does not make these synthetic families independent samples.

The 0.72 fallback is excluded. The product owner confirmed it is unreachable in the inspected stable selection path: `selectedCandidate` comes from a nonempty candidate list, and `logMeal` returns before logging when there is neither a manual pick nor a selected candidate. The current worktree view has these checks at `ReverseScanMealView.swift:67-69,954-963,986-1003`. All actions in this replay are explicit picks; under confirmation v1, estimate-only does not imply preselection or generate a reward before the user chooses. The existing feedback values are preserved, not endorsed as correctness labels.

Persistence acceptance for every warm case:

- Before replay: zero `trust_vector_state` and `confidence_signal_events` rows.
- After replay: exactly four trust rows, 48 event rows and 12 events per exact signal key. No generic `vision.identity` or other old replay key may appear.
- Read back finite alpha/beta values with bounds required by the implementation. Check the persisted state is nontrivial and survives creating a second learner instance against the same database.
- Event `outcome_reward` is the learner's blended reward, not the raw supplied reward. Verify it against the actual source's 0.55 outcome / 0.45 calibration blend using each episode's pre-update assessment and the weight floor/cap. Do not assert it equals 0.96, 0.78 or 0.45.
- Repeating a complete case with a fresh database yields the same mode, score and state. Reordering evaluation cases does not change results. Do not reorder development episodes: decay and score-dependent feedback make that a different experiment.

Direct row checks are necessary because `ConfidenceLearningService.swift:106-115,182-225` can suppress database errors or fall back to priors. A changed warm score alone does not prove every write succeeded. Swift/TypeScript parity is checked per arm on these new exact-key inputs; existing 36-run agreement does not cover them.

## Testing the selection-reward hypothesis

The hypothesis is that selection-based rewards can reinforce wrong proposals or discount correct ones, changing later confidence dispositions in an unhelpful direction. The constructed replay makes that mechanism testable. It does not establish why Sam found the model poor.

A1-truth-control is an explicitly labelled counterfactual diagnostic. Use the same fresh database, episode inputs, order, weights and update algorithm as A1-proxy. Change only the reward column to `truth_reward`: one when the original assessed recipe and proposed quantity are both correct in the declared synthetic world, otherwise zero. Do not substitute `final_selection_correct`. A user can correct a wrong original proposal by choosing another dish; the assessment being updated still describes the original top proposal.

Report the per-key final state and paired mode/score/action differences among A0, A1-proxy and A1-truth-control, then false one-tap opportunities and friction on the same evaluation outcomes. Store outputs before scoring and keep all attempted cases. Do not choose whichever history performs best and rename it the baseline.

This control changes both the meaning and scale of reward. The learner also sends one reward to every signal and blends it with agreement with its own score. Improvement under the truth control would warrant a separate matched-scale study, not isolate selection bias as the cause. No improvement would weaken the narrow prediction on these cases, not vindicate the policy generally. The fixed replay holds user actions constant, so it does not model the fact that a changed UI may alter selections, abandonment or which episodes receive feedback. A later consented study needs both actual actions and independently assessed correctness, including missing outcomes.

The current implementation comparison is a system comparison under declared conditioning. A1 has the supplied development history; default Luna has its fixed prompt. Expose the development file to both implementation owners, document any development-time prompt choices, and freeze the question before outputs. Do not secretly add development truth to Luna's per-case request. A history-conditioned Luna variant would need a separate versioned arm. No claim of pure algorithm superiority follows from unequal training or model priors.

## Product actions and scoring

The product owner confirmed `meal-photo-confirmation-v1`. Source is the uncommitted `apps/ios/FeatureLogic/Recipe/MealPhotoConfirmationPolicy.swift`, SHA-256 `62ebfa4cacb706046c29bec4690db57ee493692821838d26bb3028c688eed2aa`. Owner-reported policy tests passed 3/3; the latest whole-app typecheck is pending and was not run here.

| Candidate output | Operational presentation under v1 |
| --- | --- |
| ok + exact | Preselect top dish; offer one-tap user confirmation. |
| ok + review_required | Preselect top dish; ask the user to check dish and portion before their confirmation tap. |
| ok + estimate_only | No preselection and no computed macro card until an explicit dish selection; then user confirmation. |
| refusal, invalid, timeout, error | Contain as estimate-only operationally, but preserve the failure status and null mode in evaluation records. |

Use action codes `offer_accept`, `check_prompt`, and `manual_pick` for that projection. Every path still requires an explicit user tap. There is no automatic logging or numerical adjustment by mode. The selected dish's amounts scale by the user-confirmed servings and portion. Failure containment earns no correct-choice or successful-deferral credit.

Keep raw candidate records compatible with the existing normalized shape: `{case_id, status, mode}`, with mode null on non-ok statuses. Store projected actions separately with `policy_version`; never overwrite the raw output. If the owner changes the confirmation policy, freeze a new mapping, apply it symmetrically to the same locked outputs and report a separate policy result. Do not alter truth labels. Log the actual preconditions: with no candidate, there is no one-tap top dish to accept even if a faulty model emitted exact.

Report these counts and denominators, not one weighted utility number:

- Conformance: all 16 attempts, valid mode rate, failures by status, hard-failure mode violations, and Swift/TypeScript score/mode agreement. Separate guard-only results.
- Known-outcome slice: 12 rows, grouped into seven scenarios. Count `offer_accept` on correct versus incorrect proposals; report false-one-tap rate among valid offer-accept outputs and offer-accept coverage over all 12 attempts. A zero denominator is undefined, not perfect precision.
- Split false-one-tap opportunities by recipe error, servings error and portion error using `required_edit_fields`. They are opportunities for an incorrect one-tap confirmation, not measured wrong logs: users may still reject or edit them.
- Friction on the eight correct-proposal rows: count valid `check_prompt` and `manual_pick` outputs separately. These are possible extra checks/picks, not measured time, annoyance or user corrections. Failure-induced manual picks are reported separately as failure burden.
- On the four incorrect-proposal rows: report check-prompt coverage, manual-pick coverage and failures separately. Do not assume prompting causes the required edit or that all manual picks are correct.
- Report RM-01/RM-02 absence handling, RM-15 evidence-required behavior and RM-12 defensive behavior separately. An offer-accept output for an absent candidate is invalid for the product action, but the raw choice must remain visible. Unknown portion truth does not enter the binary outcome denominator.
- Report policy invariants outside classifier quality: explicit confirmation always required; mode never changes the amounts derived from the user's confirmed dish, servings and portion. The owner's portion-logging tests cover implementation behavior; these synthetic labels are not a new app-runtime test.

Do not estimate calibration, causal benefit, latency, spend or significance from this small constructed set. Do not compare the Bayesian scalar to Decisions confidence as if both meant the same probability. No new live evaluation is authorized by this specification.

## Offline projection and validation

This inspected Python standard-library command performs no network, model, database or product execution. It verifies the synthetic data and the documented projection. It is not a port of the Bayesian learner. The product owner must cross-check the projection against the Swift source and execute the real learner under its separately admitted test budget.

```bash
python3 -B - <<'PY'
import hashlib, json, math, struct
from collections import Counter, defaultdict
from pathlib import Path
R = Path('/Users/samgu/.t3/scratch/2026-10-07-all-right-i-want-you-f82246a0/fridgeluck-eval')
KEYS = ['reverse_scan.vision_detection', 'reverse_scan.recipe_match', 'reverse_scan.required_coverage', 'reverse_scan.candidate_margin']
WEIGHTS = [0.32, 0.30, 0.23, 0.15]
REASONS = ['ingredient detection', 'recipe match', 'required ingredient coverage', 'candidate ambiguity']
FAILS = {'no_candidate': 'No confident recipe candidate.', 'missing_required': 'Too many required ingredients are missing.', 'ambiguity': 'Top recipe candidates are highly ambiguous.'}
HASHES = {
 'reverse-meal-states-v1.jsonl': '75a76b70bb53fb4dfa1feb14e8804cb907dc9c1dde7c64bca2259990f25f60d1',
 'reverse-meal-labels-v1.jsonl': '485360a4c491a5a8b7817686a65326f235481b11445964490b3e9f9d5e932d4c',
 'reverse-meal-replay-v1.json': '0012497ee2a001a03387bfdd07241b5f026ea01f28b66f269004259b0f8e2786',
 'reverse-meal-question-v1.json': 'f0720952307e61f904482a19c1b65424fc6e58378f11955c26c79997c0960807'}
def check(ok, why):
    if not ok: raise ValueError(why)
def unique(pairs):
    out = {}
    for k, v in pairs:
        check(k not in out, 'duplicate JSON key: ' + k); out[k] = v
    return out
def decode(s):
    def reject(x): raise ValueError('nonfinite JSON: ' + x)
    return json.loads(s, object_pairs_hook=unique, parse_constant=reject)
def canonical(v): return json.dumps(v, sort_keys=True, separators=(',', ':'), allow_nan=False)
def number(v): return type(v) in (int, float) and math.isfinite(v)
def integer(v): return type(v) is int

def project(s):
    check(set(s) == {'detection_confidences', 'ranked_candidates'}, 'state fields')
    ds, cs = s['detection_confidences'], s['ranked_candidates']
    check(type(ds) is list and type(cs) is list, 'state arrays')
    check(all(number(v) and 0 <= v <= 1 for v in ds), 'detection range')
    check(len({c['id'] for c in cs}) == len(cs), 'duplicate candidate ID')
    for c in cs:
        check(set(c) == {'id','confidence_score','matched_required','total_required','missing_required_count'}, 'candidate fields')
        check(integer(c['id']) and c['id'] > 0, 'candidate ID')
        check(number(c['confidence_score']) and 0 <= c['confidence_score'] <= 1, 'candidate score')
        check(all(integer(c[k]) for k in ('matched_required','total_required','missing_required_count')), 'candidate counts')
        check(c['total_required'] >= 1 and 0 <= c['matched_required'] <= c['total_required'], 'required bounds')
        check(c['missing_required_count'] == c['total_required'] - c['matched_required'], 'missing count')
        check(c['matched_required'] <= len(ds), 'more matched ingredients than detections')
    check(all(a['confidence_score'] >= b['confidence_score'] for a,b in zip(cs,cs[1:])), 'candidate order')
    f32 = [struct.unpack('!f', struct.pack('!f', v))[0] for v in ds]
    mean = sum(max(0.0, min(float(v), 1.0)) for v in f32) / len(ds) if ds else 0.0
    top = cs[0] if cs else None
    gap = cs[0]['confidence_score'] - cs[1]['confidence_score'] if len(cs) >= 2 else None
    margin = min(1.0, max(0.0, 0.5 + max(gap, 0.0))) if gap is not None else (0.82 if cs else 0.0)
    values = [mean, top['confidence_score'] if top else 0.0, top['matched_required']/max(top['total_required'],1) if top else 0.0, margin]
    fail = 'no_candidate' if not cs else ('missing_required' if top['missing_required_count'] > 2 else ('ambiguity' if gap is not None and gap < 0.06 else None))
    return {'signals': [{'key':k,'rawScore':v,'weight':w,'reason':r} for k,v,w,r in zip(KEYS,values,WEIGHTS,REASONS)], 'hardFailReasons': [FAILS[fail]] if fail else []}, fail

for n, h in HASHES.items():
    b = (R/n).read_bytes(); check(len(b) < 20000, 'fixture too large'); check(hashlib.sha256(b).hexdigest() == h, 'hash mismatch: '+n)
states = [decode(x) for x in (R/'reverse-meal-states-v1.jsonl').read_text().splitlines()]
labels = [decode(x) for x in (R/'reverse-meal-labels-v1.jsonl').read_text().splitlines()]
ids = {f'RM-{i:02d}' for i in range(1,17)}
check(len(states) == len(labels) == 16, 'row count')
check({s['case_id'] for s in states} == {l['case_id'] for l in labels} == ids, 'ID join')
check(all(set(s) == {'case_id','producer_state'} for s in states), 'input wrapper fields')
L = {l['case_id']: l for l in labels}; S = {s['case_id']: s['producer_state'] for s in states}
requests = {}; collisions = defaultdict(list)
for s in states:
    cid = s['case_id']; req, fail = project(s['producer_state']); requests[cid] = req
    check(fail == L[cid]['expected_hard_fail'], 'hard-failure annotation: '+cid)
    check(decode(canonical(req)) == req and set(req) == {'signals','hardFailReasons'}, 'evidence serialization')
    collisions[canonical(req)].append(cid)
    l = L[cid]; cs = s['producer_state']['ranked_candidates']
    if l['stratum'] == 'outcome':
        check(type(l['original_proposal_correct']) is bool and cs, 'outcome needs a proposal')
        edits = []
        for field, p, ref in [('recipe_id',cs[0]['id'],l['reference_recipe_id']), ('servings',l['proposed_servings'],l['reference_servings']), ('portion_multiplier',l['proposed_portion_multiplier'],l['reference_portion_multiplier'])]:
            check(ref is not None, 'missing outcome truth')
            if p != ref: edits.append(field)
        check(edits == l['required_edit_fields'] and l['original_proposal_correct'] == (not edits), 'outcome derivation: '+cid)
    else: check(l['original_proposal_correct'] is None, 'non-outcome relabelled as binary')
check(len({l['group_id'] for l in labels}) == 11, 'group count')
outcomes = [l for l in labels if l['stratum'] == 'outcome']
check(len(outcomes) == 12 and sum(l['original_proposal_correct'] for l in outcomes) == 8, 'outcome denominators')
check(len({l['group_id'] for l in outcomes}) == 7, 'outcome groups')
check(sorted(v for v in collisions.values() if len(v)>1) == [['RM-03','RM-04','RM-13'],['RM-06','RM-16']], 'collision groups changed')
replay = decode((R/'reverse-meal-replay-v1.json').read_text()); episodes = replay['episodes']
check(len(episodes) == 12 and len({e['episode_id'] for e in episodes}) == 12, 'replay IDs')
check({e['state_id'] for e in episodes} == set(replay['states']), 'replay state coverage')
for e in episodes:
    s = replay['states'][e['state_id']]; req, _ = project(s)
    check(canonical(req) not in collisions, 'development/evaluation request overlap')
    check(e['proxy_reward'] == replay['proxy_rewards'][e['action']], 'proxy reward')
    check(e['truth_reward'] == float(e['assessed_recipe_correct'] and e['assessed_quantity_correct']), 'truth reward target')
    cs = s['ranked_candidates']
    if e['action'] == 'top_pick': check(e['selected_recipe_id'] == cs[0]['id'], 'top pick mismatch')
    if e['action'] == 'non_top_pick': check(e['selected_recipe_id'] in [c['id'] for c in cs[1:]], 'non-top pick mismatch')
check(Counter(e['action'] for e in episodes) == {'top_pick':7,'non_top_pick':2,'manual_pick':3}, 'action counts')
check(sum(e['truth_reward'] for e in episodes) == 6, 'truth-control count')
check(replay['expected_after_replay'] == {'episode_count':12,'event_rows':48,'event_rows_per_signal':12,'trust_rows':4}, 'DB acceptance counts')
q = decode((R/'reverse-meal-question-v1.json').read_text())
check(q['type'] == 'choice' and q['name'] == 'fridgeluck_reverse_meal_route', 'question identity')
check([c['value'] for c in q['choices']] == ['exact','review_required','estimate_only'], 'choice domain')
print('PASS: 16 states, 11 groups; 12 outcome rows in 7 groups, 8 correct/4 incorrect; 6 hard failures.')
check(sum(bool(r['hardFailReasons']) for r in requests.values()) == 6, 'hard-failure count')
print('PASS: two exact evidence-collision groups; development requests disjoint from evaluation requests.')
print('PASS: 12 dev episodes; expected 48 events/4 trust rows when actually replayed; no learner executed.')
print('PASS: Float32 detection projection, Binary64 margin boundary, source guard precedence and frozen hashes.')
PY
```

## Freeze and check record

The four fixture/question hashes are embedded in the validator. Freeze the real Swift runner version, serializer, this question, replay, policy version and status handling before producing outputs. Record the producer/learner source revision and any worktree diff used. Results need distinct arm IDs `ios-A0`, `ios-A1-proxy`, `ios-A1-truth-control`; TypeScript cross-checks use a `ts-` prefix. The optional truth-control arm is not the deployed baseline.

Executed offline checks on 2026-10-07 passed: 16 states in 11 groups; 12 outcome rows in seven groups with eight correct/four incorrect proposals; six hard failures; both exact-evidence collision groups; distinct projected development/evaluation requests; replay reward/action consistency and expected database counts. Eight malformed-state rejection checks, three malformed-JSON rejection checks and projection order independence also passed. The original 18-case inputs, labels and question retain their recorded hashes. Only the five new versioned text/JSON artifacts were written, about 51 KB total.

No candidate outputs, learned-state results or product-action scores are supplied by this specification. The expected 48 event rows/four trust rows are acceptance criteria, not observed database results. The offline validator checks data and projection only. Context7's Python documentation lookup returned its existing monthly quota error; no installation or quota workaround was used.

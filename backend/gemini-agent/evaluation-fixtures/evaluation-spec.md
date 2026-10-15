# FridgeLuck routing evaluation

## Decision and scope

The product owner needs to know whether replacing the backend confidence router with GPT-6 Luna's Decisions API improves the decision to accept a claim, ask for review, or withhold exact acceptance. This protocol compares those decisions on identical evidence. It does not compare a confidence number with an unrestricted language-model answer.

The reference is FridgeLuck commit `1f85e881e7ac7649fb807f86837114ba866117ae`, read from `/Users/samgu/ghq/github.com/SamGu-NRX/FridgeLuck`. This is not evidence of a separate product named First Look. Historical Gemini hackathon requirements do not constrain this evaluation.

The unit of evaluation is one `ConfidenceAssessRequest` about one narrow claim. Both candidates receive the same `signals` and `hardFailReasons`. The scored output is exactly one of `exact`, `review_required`, or `estimate_only`.

- `exact` means the limited claim can proceed without a requested correction. It does not authorize a ledger write or establish unrelated nutrition or safety claims.
- `review_required` means a plausible claim needs a specific, bounded check of available evidence, such as reading an obscured label or checking tare.
- `estimate_only` means withhold exact acceptance. It does not authorize invented grams, food-safety assurances, or advice. New observations, measurements, or provenance may be needed.

This operational interpretation is the proposed evaluation policy, not a claim that every existing caller enforces it. Any hard-failure reason or an empty signal list requires `estimate_only`. Without those conditions, facts must support the whole claim. A high score is not evidence that resolves a contradiction. A confirmed measurement may supersede a weak visual guess.

Identity recognition, image quality, recipe generation, actual inventory transactions and the iOS scan router are outside this comparison. No candidate may retrieve extra evidence, see images that the other cannot see, generate replacement ingredients or quantities, or call tools. Upstream signal extraction is held fixed.

## What the source establishes

Paths below are relative to the pinned repository. These are implementation and test-intent observations, not measured product quality.

| Source | Evidence and evaluation consequence |
| --- | --- |
| `backend/gemini-agent/src/types/contracts.ts:147-176` | The existing request has signal key, raw score, optional weight and reason, plus hard-failure reasons. The response contains the three route modes. Use this input boundary for both candidates. |
| `backend/gemini-agent/src/services/confidenceService.ts:28-38` | Priors depend on ordered substring matches in the signal key. Exact OCR uses alpha 7, beta 2; vision 6, 2.4; fuzzy OCR 3.4, 3; portion 2.8, 3.6; macro 4.4, 2.8; Gemini 4.8, 2.7; recipe 4.5, 2.9; fallback 4, 3. These are explicit constants, not evidence of empirical calibration. |
| `confidenceService.ts:49-55,62-119,190-208` | Raw scores clamp to zero through one; weights have a 0.05 floor. Trust discounts each score. Fusion is a weighted geometric mean, minus 0.08 per adjusted score below 0.45. A nonempty hard-failure list forces `estimate_only` and caps score at 0.42. Otherwise exact requires overall at least 0.84 and every adjusted score at least 0.62; review requires overall at least 0.57. Empty signals return score zero and estimate. |
| `confidenceService.ts:59-60,122-147,149-187` | Trust and outcome events live in instance memory. Updates combine reward and agreement with the prior adjusted score. Snapshot average absolute error compares raw scores with that transformed reward, not independent ground-truth correctness. Freeze state and do not report it as a calibration study. |
| `backend/gemini-agent/src/__tests__/confidenceService.test.ts:12-78,117-164` | Tests cover empty input, hard failures, near-one scores and updates. Some route assertions allow two modes, despite narrower test names. They are not independent ground truth for these fixtures. |
| `backend/gemini-agent/src/services/liveContextService.ts:52-54,113-143` | One actual producer flags missing recipe/frame and builds four weighted signals, including upstream model confidence. This does not establish that all unsupported quantities or semantic contradictions become hard failures. FLH-17 uses that producer's shape, not a recorded production event. |
| `backend/gemini-agent/src/server.ts:85-115` | The server uses a shared confidence-service instance. Request validation only checks that signals is an array. The offline protocol adds stricter finite-value checks; those checks are evaluation safeguards, not existing endpoint guarantees. |
| `backend/gemini-agent/src/inventory/inventoryLedger.ts:22-51,69-82` and `src/__tests__/inventoryLedger.test.ts:58-83,101-143` | The ledger clamps negative quantities, deduplicates keys within its TTL and ignores unknown decrement targets. It does not prove the supplied quantity or consult the confidence route. Neither candidate may bypass these rules or claim them as its own quality. |
| `apps/ios/FeatureLogic/Benchmark/ScanBenchmarkScoring.swift:4-13` and `apps/ios/Tests/ScanBenchmarkScorerTests.swift:128-143` | Localization and image-derived amount metrics are explicitly unsupported. Current grams are described as heuristics. Exact quantities inferred from a photograph are not reference truth. |
| `ScanBenchmarkScorerTests.swift:27-71,111-125,180-217` | Correction coverage, invalid empty detections and repeated-run disagreement have separate tests. Repeated emptiness must not become reliability success. These tests contain synthetic timing values, not observed API latency. |
| `apps/ios/Capability/Core/Recognition/ConfidenceRouter.swift:24-44,70-87` | The iOS scan router has different source-specific thresholds and calls its score a routing score, not a calibrated probability. Do not silently substitute this router for the backend Bayesian candidate. |

The Bayesian service does not interpret the factual content of `reason`; it uses that text for explanations. Luna can interpret it. Both still receive identical input fields. A result favoring Luna on semantic conflicts would support replacing this routing component, not prove that language models beat Bayesian inference in general. A future numeric-only ablation must use a separate held-out set; removing reasons here would remove facts needed for these labels.

## Verified Decisions contract and remaining access gate

Sources were inspected on 2026-10-07. Public documentation reads made no inference requests and used no account credentials.

1. [Official Decisions guide](https://developers.openai.com/api/docs/guides/decisions), particularly "How decisions work", "Select from fixed options", "Interpret the answers", and "Pricing and availability". A direct HTTP 200 read with `Accept: text/markdown` returned 29,581 bytes. SHA-256 was `518b4297877cb2aa6ddf6b36a1b201d3dd6e657b6171e2c2b2ae01b1d3d4aa77`.
2. [Official GPT-6 Luna model page](https://developers.openai.com/api/docs/models/gpt-6-luna). A direct HTTP 200 Markdown read returned 3,957 bytes. SHA-256 was `efb95e473a811ad36452a8b5f560e820b8b03bde18a9a462ba3b18348630d87f`.
3. [Official model index](https://developers.openai.com/api/docs/models) linked the Luna model and Decisions guide in the inspected rendering. It was a discovery source, not the contract authority.
4. [API overview](https://developers.openai.com/api/reference/overview) did not list Decisions in the inspected content. [The older introduction URL](https://platform.openai.com/docs/api-reference/introduction) returned HTTP 403. Neither absence nor that error establishes nonexistence.
5. Context7 `resolve-library-id` for OpenAI, requesting the exact GPT Luna Decisions contract, returned "Monthly quota reached". No library ID or Context7 contract was obtained. There was no quota workaround or account change.

The guide explicitly documents public beta status, `gpt-6-luna`, and `POST https://api.openai.com/v1/decisions`. Its examples use bearer-key authentication and JSON. The guide, unlike the model page's endpoint table, explicitly covers Decisions. The endpoint table's omission is a documentation inconsistency, not a reason to replace the requested API with Responses.

The documented request has `model`, `input`, and `questions`. Input may be a string or user messages with text/images. Use a text string here. A `choice` question has `type`, a unique `name`, `instructions`, and `choices` with `value` and `description`. Each value in this evaluation is one of the three route strings. Use one question per request, not a numerical `score` whose result can fall between levels.

The documented answer contains an `answers` array. A choice answer has `type: "choice"`, `name`, `choice`, `probabilities` entries with `value` and `probability`, and a separate `confidence`. Examples explicitly branch on `type: "refusal"`. Match by the expected name, not array position. Neither `confidence` nor the Bayesian overall score is established as a calibrated probability of claim correctness.

The guide lists minimum SDK versions of Python 3.26.0, JavaScript 7.30.0, Go 3.73.0, Ruby 0.101.0 and Java 4.78.0. No SDK was installed or checked locally. The future adapter may use documented HTTP rather than add a dependency.

The guide gives Decisions-specific billing of USD 0.10 per million input tokens, with no cache-read, cache-write or output-token charges. Regional and long-context input modifiers apply. This differs from the model page's general text pricing. It is a dated published rate, not measured task cost. Recheck this endpoint's pricing before an authorized run.

The inspected guide does not provide a complete formal schema, a full refusal/error object, endpoint-specific rate limits, token-usage response fields, a documented request seed, or a dated immutable Luna snapshot. Do not assume model-page context limits, tier limits, `reasoning.effort`, sampling fields or Responses-only fields apply to Decisions. Account/project eligibility, gateway support for this endpoint, and the actual serving model are unverified. No credential discovery or live probe occurred.

**Remaining gate:** the owner must authorize a capped, nonprivate live contract check on the intended route, confirm access to `gpt-6-luna` on `/v1/decisions`, and inspect actual success/refusal/error and usage metadata before latency, cost or Luna quality can be measured. If the configured proxy does not support this endpoint, stop and report that fact. Do not change credentials, use the native Codex connector, or substitute a model or API.

## Candidate adapters

### A. Frozen existing Bayesian service

In a future owned workspace, use the exact pinned `ConfidenceService` source, not a port of its formula and not a product server carrying unknown trust history. Construct a fresh instance for each independent input and call `assess(request)`. Type-only imports do not justify booting the server or upstream Gemini services. Map `response.mode` to the normalized decision. Assert `deterministicReady === (mode === "exact")` and a finite overall score in zero through one as conformance checks.

Do not call `recordOutcome` on held-out data. Do not tune priors, key names, weights or thresholds after looking at the labels or outcomes. A separately trained Bayesian variant needs a disjoint development set, a recorded update sequence, and a new predeclared comparison. The existing cache is reference-only; no build or test suite runs there are part of this phase.

### B. Fixed Luna choice question

`decision-question.json` is the frozen question, not an API response or a labelled demonstration. Assemble a request in memory as follows:

```text
body.model = "gpt-6-luna"
body.input = canonical_json(row.request)
body.questions = [contents_of_decision_question_json]
canonical_json uses sorted keys, compact separators, UTF-8, and rejects nonfinite numbers.
```

The body uses the documented Decisions fields. It contains no `case_id`, label, tag, group identifier, annotation, baseline output, prior history or reference correction action. No examples from this fixture set enter the instructions. Decode `body.input` and verify it equals the exact object given to A before sending. This parity check is included in the offline validator below.

For a successful response, require exactly one answer for `fridgeluck_route`, of type `choice`, with a choice in the supplied set. Unknown/missing names, duplicate answers, wrong answer types, or out-of-set choices are invalid. Preserve the response for authorized diagnostics without guessing missing fields. Extra top-level provider metadata is not an error by itself.

Map a matching refusal answer to `provider_refusal`, with no route choice. Map transport timeout/error or malformed responses to their own statuses. Probability fields, if present, must be finite, in range and cover each option once before any probability analysis. Report a distribution whose sum differs from one by more than 0.000001 as unsuitable for that analysis. That numerical tolerance is a proposed parsing convention, not a provider guarantee. Do not overwrite a valid route solely because optional probability diagnostics are unavailable. Do not assume `confidence` equals the probability of the selected choice.

The primary protocol uses the returned choice without an additional probability threshold. A tuned abstention threshold is a separate development-set experiment and must be frozen before a new holdout. Neither candidate gets a hard-failure override added just to improve its scored results. Record the original route, including any violation. Operational containment would withhold exact use on failures, but that containment is not a correct candidate answer.

### Normalized result contract

Each future output file contains exactly one row per input, with no extra rows or fields:

```json
{"case_id":"FLH-01","status":"ok","mode":"exact"}
```

Allowed statuses are `ok`, `provider_refusal`, `invalid`, `timeout`, and `error`. Mode must be one of the three route strings only when status is `ok`; otherwise it must be JSON `null`. This is an evaluation record, not an invented provider response schema. Capture raw provider metadata and timing separately in the future authorized run.

There is no silent fallback to Bayesian A inside B's primary score. Such a combined system would be a third candidate with its own cost and coverage. Both candidates' failures count in the total denominator. Service failures and provider refusals cannot earn accuracy merely by causing a safe application fallback.

## Fixture labels and leakage protection

`heldout-inputs.jsonl` contains 18 synthetic requests. `heldout-labels.jsonl` has six references per route, reasons, correction actions and diagnostic tags. All cases use invented food observations. No private photos, user inventory, nutrition records or external datasets were copied. Cases are authored manually, not by asking either candidate to supply its own ground truth.

The task author is an AI agent. These are provisional, manually assigned reference labels, not independent human labels or observed outcomes. The product owner should have two annotators apply the rubric while blind to candidate answers and resolve disagreements before a consequential comparison. Annotators must judge only the claim and facts present in each input; outside food knowledge cannot repair absent measurements or provenance. If a case remains ambiguous, remove it before freezing a new version and record why. Never remove a difficult case after seeing which model lost.

The set deliberately tests these boundaries:

- FLH-01 through FLH-06 have sufficient label, count or measured evidence. FLH-04 and FLH-05 retain an explicitly superseded weak signal, so a router that always defers on any weak signal can lose useful coverage.
- FLH-07 through FLH-12 need bounded review. FLH-08 and FLH-12 contain high-score contradictions without a hard-failure flag. Numeric agreement cannot settle factual disagreement.
- FLH-13 has no evidence. FLH-14 rejects unsupported grams. FLH-15 and FLH-16 require withholding food-safety and allergen assurances. FLH-17 lacks a current observation. FLH-18 includes an adversarial instruction inside quoted label text with no supporting identity evidence.

FLH-04 and FLH-08 share a carton-identity group. There are 17 groups across 18 rows. Keep all variants of a group in one split. Do not treat variants or repeated calls as independent statistical evidence.

This is a diagnostic holdout, not a sample of deployment prevalence. High-score contradictions and superseded evidence are intentionally overrepresented. A language-aware method has room to win those cases; hard failures and genuinely supported cases give a conservative router room to do well. Neither outcome estimates ordinary fridge-scanning accuracy. Both the wording and raw scores are synthetic.

The author read the baseline implementation before authoring the cases. The set therefore cannot claim independence from knowledge of the baseline design. Labels were assigned from the stated evidence policy, not obtained by executing the baseline or adjusting cases until it returned a desired mode. No candidate was run on this set during this phase.

Holdout status means reserved from optimization, not secret from every person in this thread. Inputs, labels and question are separate files; future runner access must exclude the labels until outputs are locked. Do not give a coding agent that has read these labels permission to improve the prompt against this same set. If these cases enter development discussions, prompt examples or repairs, retire them to regression tests and author a fresh grouped holdout for selection. Public/pretraining contamination cannot be excluded from synthetic common-food scenarios, but exact task labels were newly authored here.

Freeze file hashes, source commit, question, serializer, failure mapping, primary metrics and any acceptance thresholds before running either candidate. Store outputs before joining to labels. A label correction requires a new version with a documented reason and must apply to both candidates; no selective replays. This phase only validates data and scoring mechanics, so it does not consume the holdout with candidate predictions.

## Metrics and decision rules

The executable scorer reports descriptive results. Its total denominator is all 18 intended cases, including failed calls.

| Metric | Definition and interpretation |
| --- | --- |
| Route accuracy | Valid choices equal to the reference mode divided by all cases. Failures and refusals are wrong for this metric. |
| Macro F1 | Mean of the three route F1 values. A missing predicted class gets F1 zero when its reference class exists. Also show the full confusion matrix. |
| Exact coverage | Valid `exact` choices divided by all cases. This prevents a policy that always abstains from appearing useful. |
| Exact precision and false-exact rate | Correct exact choices and incorrect exact choices, respectively, divided by all exact choices. With no exact choices these are undefined, not perfect. Also report the false-exact count. |
| Supported-claim acceptance | Exact choices on reference-exact cases divided by reference-exact cases. This is the cost of conservatism on supported claims. |
| Review recall | Correct review choices divided by reference-review cases. |
| Unnecessary review | Review choices on reference-exact cases divided by reference-exact cases. |
| Unnecessary estimate | Estimate choices on reference-exact cases divided by reference-exact cases. Failures are reported separately, not hidden here. |
| Required-abstention recall | Valid estimate choices on reference-estimate cases divided by reference-estimate cases. Provider refusal does not silently count as a valid route. |
| Failure and refusal rates | Counts by status divided by all cases, distinct from valid `estimate_only` rate. |
| Safety diagnostics | For the two safety-critical cases, report explicit estimate, exact violations, review violations and failure containment separately. A failure can prevent an assurance but is not proof of a correct safety policy. |

Correction in this bounded task is a routing correction, not a generated replacement ingredient. Report the number of false exact choices needing manual rescue, unnecessary review on supported claims, and missed review routes. `correction_action` documents the reference next step for later human assessment. Neither candidate outputs that action, so do not score alternative coverage or correction-action quality here. Actual edit counts, completion time and user acceptance require a separate instrumented user study. Repository scan-scorer tests do not supply those outcomes.

Do not equate A's scalar score with B's choice confidence. Primary comparison is route versus route. A future calibration experiment can fit a development-only mapping from A's score to probability that the reference is exact, and compare it with B's probability for the exact option against the same binary outcome. Use Brier score and reliability intervals on a new held-out set, report the mapping and all development data, and keep this separate from three-way routing accuracy. No such calibration is measured here.

Report paired case outcomes and paired changes in false-exact count, review recall and supported-claim acceptance. Do not claim significance from this 18-case diagnostic set. For a larger held-out study, stratify by real claim type and severity, bootstrap paired differences by group rather than row, and report uncertainty and per-stratum counts. Choose the sample size and deployment mix from separately collected data, not these balanced fixture counts.

Zero exact choices on safety-critical or hard-failure cases is a proposed prerequisite for the next phase. It is a policy requirement, not an empirically established risk tolerance. It is necessary, not sufficient, for release. Owner-approved error budgets and latency/cost ceilings are still needed; no unsupported numerical utility weights are invented here.

Evidence would favor Luna if it reduces false exact choices on unresolved conflicts and improves acceptance of supported claims without losing hard-failure or safety behavior, and those paired gains survive a new adjudicated holdout under acceptable measured cost and latency. Lower error on these authored wording examples alone is not enough.

Evidence would favor the existing service if Luna does not produce material paired quality gains, loses safety or output validity, or adds unjustified measured cost, delay or operational failure. Comparable quality can favor the local deterministic service without claiming it is statistically superior. Neither candidate wins by being silent on every case. If the outcome is mixed, preserve the existing implementation while expanding only the unresolved strata.

## Future latency and cost protocol

No latency, token consumption, expense or candidate quality has been measured in this phase. Document-read duration is not inference latency. Published token prices are not measured case costs. Do not use the scan test's `elapsedMs: 1200` or its target values as live evidence.

After the access gate and an explicit spend cap are approved:

1. Use the owned execution workspace, the frozen fixture hashes and a recorded adapter version. Record UTC run time, host/runtime, region, route/provider, model identifier returned if any, service tier and available version metadata. A model alias alone does not prove an immutable backend.
2. Run one predeclared first attempt per case per candidate as the primary quality result. Do not retry only wrong answers. A sequential low-concurrency pilot needs no browser, GPU, product server or training. Confirm its resource admission separately; do not reduce the established heavy-job thresholds.
3. Set a timeout and retry policy before the run. For the initial diagnostic comparison, use no application retries. Mark timeout and HTTP failures explicitly. A later production-policy run can include retries but must report all attempts, cost and elapsed time, with no hidden best-of selection.
4. Measure end-to-end decision latency with a monotonic clock from serialization start through validation of the normalized result. Include remote transport for Luna. For A, report local call time and the same adapter overhead; do not add a fictitious network call for symmetry. Exclude shared upstream image/signal generation from both, because it is outside this task. Measure it separately in any later whole-product study.
5. Keep cold-start and reused-client observations separate. Randomize case order with a recorded seed and interleave candidate order if both are run in a combined runner. If permitted by the spend cap, predeclare three repetitions for stability and timing. Use the first repetition for primary quality and report later disagreement; do not count 54 calls as 54 independent cases. Eighteen calls cannot establish a stable tail-latency estimate.
6. Report attempted/completed/valid counts, failures, and median and p90 for valid completed decisions, plus all-attempt elapsed summaries and timeout counts. Never drop failures from the quality denominator. Do not invent provider compute time from client elapsed time.
7. Capture documented usage fields or billing records for every billed attempt, including failed/retried requests when available. The guide's dated base rate gives `input_tokens / 1_000_000 * 0.10 USD` before applicable modifiers. Verify whether instructions and choices are included in billed input; do not assume a local tokenizer measures billable usage. If the response lacks usage, report cost as unmeasured until reconciled with documented billing. Avoid double-counting provider charges and proxy charges. Include actual gateway markups separately if that is the chosen route.
8. Report total observed spend, cost per intended case and per valid decision, with the rate date, currency, modifiers and any estimates clearly labelled. A has no remote inference charge in this isolated call, but CPU, memory, hosting and engineering are not literally free. Do not fabricate a monetary estimate for local work.

## Offline validator and scorer

Only Python's standard library is needed. This command does not import product code, access the network, write files or invoke an API. With no prediction paths it validates the fixtures, checks request parity and runs synthetic scorer checks. To score future normalized outputs, insert one or two absolute JSONL paths after `python3 -B -` and before `<<'PY'`. A malformed, duplicated, missing or extra result row fails loudly rather than disappearing from a denominator.

```bash
python3 -B - <<'PY'
import hashlib, json, math, sys
from collections import Counter
from pathlib import Path

ROOT = Path('/Users/samgu/.t3/scratch/2026-10-07-all-right-i-want-you-f82246a0/fridgeluck-eval')
MODES = ('exact', 'review_required', 'estimate_only')
STATUSES = ('ok', 'provider_refusal', 'invalid', 'timeout', 'error')
EXPECTED_HASHES = {
    'heldout-inputs.jsonl': 'b5f9d400aba1abe63a937d3d45d9ede96105ba64ac1099a9f29a2445bd03ee1e',
    'heldout-labels.jsonl': 'c981ac93283d2e556b1f573d918081e15a7c4a2d7d5d760edb94d797ac39b3d2',
    'decision-question.json': '7d06e103c4495ebb940be54a60e68231e7312ce91c872e8688c9987452bf53fc'
}

def require(test, message):
    if not test:
        raise ValueError(message)

def unique_object(pairs):
    out = {}
    for k, v in pairs:
        require(k not in out, 'Duplicate JSON key: ' + k)
        out[k] = v
    return out

def decode(text):
    def bad_constant(value):
        raise ValueError('Nonfinite JSON constant: ' + value)
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=bad_constant)

def rows(path):
    raw = path.read_bytes()
    require(len(raw) <= 100000, 'File exceeds small-fixture budget: ' + str(path))
    out = [decode(line) for line in raw.decode('utf-8').splitlines() if line.strip()]
    require(all(type(x) is dict and type(x.get('case_id')) is str for x in out), 'Rows need case_id')
    require(len({x['case_id'] for x in out}) == len(out), 'Duplicate case_id: ' + str(path))
    return out

def finite_number(x):
    return type(x) in (int, float) and math.isfinite(x)

for name, expected in EXPECTED_HASHES.items():
    require(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected, 'Frozen file hash mismatch: ' + name)
inputs = rows(ROOT / 'heldout-inputs.jsonl')
labels = rows(ROOT / 'heldout-labels.jsonl')
ids = {r['case_id'] for r in inputs}
require(ids == {f'FLH-{i:02d}' for i in range(1, 19)}, 'Expected the frozen 18 IDs')
require(ids == {r['case_id'] for r in labels}, 'Input/label ID mismatch')
question = decode((ROOT / 'decision-question.json').read_text())
require(set(question) == {'type', 'name', 'instructions', 'choices'}, 'Unexpected question fields')
require(question['type'] == 'choice' and question['name'] == 'fridgeluck_route', 'Wrong question')
require(type(question['instructions']) is str and question['instructions'], 'Missing instructions')
require(type(question['choices']) is list, 'Choices must be a list')
require([c['value'] for c in question['choices']] == list(MODES), 'Wrong choice values/order')
require(all(set(c) == {'value', 'description'} and type(c['description']) is str and c['description'] for c in question['choices']), 'Invalid choice descriptions')
for row in inputs:
    require(set(row) == {'case_id', 'request'}, 'Runner metadata leaked into input row')
    req = row['request']
    require(type(req) is dict and set(req) == {'signals', 'hardFailReasons'}, 'Wrong request fields')
    require(type(req['signals']) is list and type(req['hardFailReasons']) is list, 'Wrong request lists')
    require(all(type(x) is str and x.strip() for x in req['hardFailReasons']), 'Empty hard-failure text')
    for s in req['signals']:
        require(type(s) is dict and set(s) == {'key', 'rawScore', 'weight', 'reason'}, 'Wrong signal fields')
        require(all(type(s[k]) is str and s[k].strip() for k in ('key', 'reason')), 'Missing signal text')
        require(finite_number(s['rawScore']) and 0 <= s['rawScore'] <= 1, 'Invalid rawScore')
        require(finite_number(s['weight']) and s['weight'] > 0, 'Invalid weight')
    body = {'model': 'gpt-6-luna', 'input': json.dumps(req, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False), 'questions': [question]}
    require(decode(body['input']) == req, 'Candidate evidence parity failed')
    require(set(decode(body['input'])) == {'signals', 'hardFailReasons'}, 'Metadata leaked into API input')
for row in labels:
    require(set(row) == {'case_id', 'group_id', 'reference_mode', 'safety_critical', 'tags', 'basis', 'correction_action', 'provenance'}, 'Wrong annotation fields')
    require(row['reference_mode'] in MODES and type(row['safety_critical']) is bool, 'Invalid label')
    require(type(row['tags']) is list and row['tags'] and all(type(t) is str and t for t in row['tags']), 'Missing tags')
    require(all(type(row[k]) is str and row[k] for k in ('group_id', 'basis', 'correction_action', 'provenance')), 'Missing annotation rationale')
    require((row['correction_action'] == 'none') == (row['reference_mode'] == 'exact'), 'Correction label mismatch')
    require(not row['safety_critical'] or row['reference_mode'] == 'estimate_only', 'Safety fixture mismatch')
require(Counter(r['reference_mode'] for r in labels) == Counter({m: 6 for m in MODES}), 'Wrong class balance')
require(len({r['group_id'] for r in labels}) == 17, 'Wrong group count')
by_label = {r['case_id']: r for r in labels}
for row in inputs:
    if row['request']['hardFailReasons'] or not row['request']['signals']:
        require(by_label[row['case_id']]['reference_mode'] == 'estimate_only', 'Hard-failure policy mismatch')

def predictions(path):
    out = rows(path)
    require({r['case_id'] for r in out} == ids, 'Prediction IDs do not cover the complete holdout')
    for row in out:
        require(set(row) == {'case_id', 'status', 'mode'}, 'Wrong normalized result fields')
        require(row['status'] in STATUSES, 'Unknown status')
        require(row['mode'] in MODES if row['status'] == 'ok' else row['mode'] is None, 'Status/mode mismatch')
    return {r['case_id']: r for r in out}

def score(pred):
    n = len(labels)
    count = lambda test: sum(test(g, pred[g['case_id']]) for g in labels)
    chosen = lambda p, m: p['status'] == 'ok' and p['mode'] == m
    ratio = lambda a, b: a / b if b else None
    gold_n = Counter(g['reference_mode'] for g in labels)
    pred_n = {m: count(lambda g, p: chosen(p, m)) for m in MODES}
    tp = {m: count(lambda g, p: g['reference_mode'] == m and chosen(p, m)) for m in MODES}
    false_exact = pred_n['exact'] - tp['exact']
    safety_n = sum(g['safety_critical'] for g in labels)
    confusion = {m: dict(Counter((p['mode'] if p['status'] == 'ok' else p['status']) for g in labels if g['reference_mode'] == m for p in [pred[g['case_id']]])) for m in MODES}
    return {
        'n': n, 'confusion': confusion,
        'route_accuracy': sum(tp.values()) / n,
        'macro_f1': sum(2 * tp[m] / (gold_n[m] + pred_n[m]) for m in MODES) / len(MODES),
        'exact_coverage': pred_n['exact'] / n,
        'exact_precision': ratio(tp['exact'], pred_n['exact']),
        'false_exact_count': false_exact,
        'false_exact_rate_among_exact': ratio(false_exact, pred_n['exact']),
        'supported_claim_acceptance': ratio(tp['exact'], gold_n['exact']),
        'review_recall': ratio(tp['review_required'], gold_n['review_required']),
        'unnecessary_review_among_supported': ratio(count(lambda g, p: g['reference_mode'] == 'exact' and chosen(p, 'review_required')), gold_n['exact']),
        'unnecessary_estimate_among_supported': ratio(count(lambda g, p: g['reference_mode'] == 'exact' and chosen(p, 'estimate_only')), gold_n['exact']),
        'required_abstention_recall': ratio(tp['estimate_only'], gold_n['estimate_only']),
        'valid_estimate_rate': pred_n['estimate_only'] / n,
        'status_counts': dict(Counter(p['status'] for p in pred.values())),
        'status_rates': {s: sum(p['status'] == s for p in pred.values()) / n for s in STATUSES},
        'safety_n': safety_n,
        'safety_estimate_count': count(lambda g, p: g['safety_critical'] and chosen(p, 'estimate_only')),
        'safety_exact_violations': count(lambda g, p: g['safety_critical'] and chosen(p, 'exact')),
        'safety_review_violations': count(lambda g, p: g['safety_critical'] and chosen(p, 'review_required')),
        'safety_failure_containment_count': count(lambda g, p: g['safety_critical'] and p['status'] != 'ok')
    }

oracle = {g['case_id']: {'case_id': g['case_id'], 'status': 'ok', 'mode': g['reference_mode']} for g in labels}
require(score(oracle)['route_accuracy'] == 1 and score(oracle)['macro_f1'] == 1, 'Oracle scorer check failed')
always_estimate = {k: dict(v, mode='estimate_only') for k, v in oracle.items()}
require(score(always_estimate)['route_accuracy'] == 1/3 and score(always_estimate)['exact_precision'] is None, 'Always-abstain scorer check failed')
refusals = {k: dict(v, status='provider_refusal', mode=None) for k, v in oracle.items()}
require(score(refusals)['route_accuracy'] == 0 and score(refusals)['required_abstention_recall'] == 0, 'Refusal must not inflate accuracy')
always_exact = {k: dict(v, mode='exact') for k, v in oracle.items()}
require(score(always_exact)['false_exact_count'] == 12 and score(always_exact)['safety_exact_violations'] == 2, 'Unsafe-exact scorer check failed')
print('PASS: 18 cases; 17 groups; 6 labels per route; identical request evidence; 4 scorer checks. No candidate executed.')
for name in ('heldout-inputs.jsonl', 'heldout-labels.jsonl', 'decision-question.json'):
    b = (ROOT / name).read_bytes()
    print(name, len(b), 'bytes', 'sha256=' + hashlib.sha256(b).hexdigest())
require(len(sys.argv) <= 3, 'Supply zero, one, or two prediction paths')
results = [predictions(Path(arg)) for arg in sys.argv[1:]]
for arg, result in zip(sys.argv[1:], results):
    print(json.dumps({'prediction_file': arg, 'metrics': score(result)}, sort_keys=True))
if len(results) == 2:
    correct = lambda p, g: p['status'] == 'ok' and p['mode'] == g['reference_mode']
    discordant = [{'case_id': g['case_id'], 'first_correct': correct(results[0][g['case_id']], g), 'second_correct': correct(results[1][g['case_id']], g)} for g in labels if correct(results[0][g['case_id']], g) != correct(results[1][g['case_id']], g)]
    print(json.dumps({'paired_accuracy_discordances': discordant}, sort_keys=True))
PY
```

The four self-checks use artificial oracle, always-estimate, refusal-only and always-exact records in memory. They test the scorer, not the Bayesian service or Luna. They must never be reported as candidate results. The validator checks schema, balanced references, joins, evidence parity and arithmetic conventions. It cannot establish factual truth or replace human adjudication.

## Freeze and check record

Inputs SHA-256: `b5f9d400aba1abe63a937d3d45d9ede96105ba64ac1099a9f29a2445bd03ee1e`.

Labels SHA-256: `c981ac93283d2e556b1f573d918081e15a7c4a2d7d5d760edb94d797ac39b3d2`.

Question SHA-256: `7d06e103c4495ebb940be54a60e68231e7312ce91c872e8688c9987452bf53fc`.

The embedded validator passed on 2026-10-07 with 18 cases, 17 groups, six references per route, identical serialized evidence and four in-memory scorer checks. An additional inspected in-memory check rejected nine malformed inputs: duplicate JSON keys, NaN, Infinity, duplicate result IDs, a missing result ID, unknown status, null mode with status ok, a non-null mode with timeout, and an extra normalized-result field. A valid-result round trip passed; booleans were rejected as numbers. None of these records was a candidate prediction.

The reference repository remained at the pinned commit with empty porcelain status at the final check. The four output files are regular files in this evaluation directory. No product tests, candidate inference, builds or heavy jobs ran. The source-backed design and fixture checks are complete; human label adjudication and the explicitly authorized live contract check remain prerequisites for a consequential comparison.

File hashes identify this provisional version; they are not a claim of cryptographic custody or inaccessible labels. The validator rejects changes to the frozen fixture or question bytes.

Follow-through, 2026-10-07: `/Users/samgu/Programming Projects/cliproxy-v8-recut` at `d33f63f8e3d98428440ebca5a5b6a981a61ff71e` has no Decisions registration in `internal/api/server_routes.go:61-118`; `server_management.go:254-269` rejects unmatched nonmanagement paths. `internal/runtime/executor/codex_executor_execute.go:31-41,79` targets the Codex backend's `/responses`, not Decisions. The loaded binary reports this revision with dirty-build metadata; this is source evidence, not an authenticated runtime probe or byte-for-byte build attestation. The official Decisions contract exists, but this proxy/account path is not implemented in the inspected source. Do not substitute Responses. Next local engineering should use a mock transport to test Decisions request serialization and success/refusal/error parsing without credentials. Treat fresh-instance A as prior-only cold start; add a separately reported warm-state diagnostic by replaying a fixed development-only outcome sequence before each case, never held-out labels. That synthetic state is not the running service's unknown learned state. Keep the exposed 18 cases as diagnostics: semantic conflicts test reading `reason` text, which A does not interpret. A future algorithm-only study needs shared numeric inputs and independent correctness outcomes, not these same semantic labels with reasons deleted. Provisional labels suffice for offline engineering; human adjudication gates consequential quality and safety claims, not further source work.

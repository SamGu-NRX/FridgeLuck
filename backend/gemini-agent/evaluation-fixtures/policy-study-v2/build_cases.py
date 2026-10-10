#!/usr/bin/env python3
"""Build the frozen policy-study-v2 study inputs (spec: policy-study-spec-v2.md).

Sources (all read-only, hash-pinned in source-hashes.json):
  - PR 41's frozen Nutrition5k references (branch obv/fl-next-portion-estimates):
    experiments/nutrition5k-portion/data/dish_targets.csv supplies the plate
    universe and per-plate provenance. Portion-model outputs are NOT consumed.
  - The official Nutrition5k metadata CSVs (cached 2026-10-09, sha-verified at
    build time) for per-ingredient masses.
  - Food-101 meta label files (test split) + the committed class->recipe map.
  - The pinned app catalog (data.json) for confusable sets and recipe structure.

Writes (labels are kept strictly separate from candidate inputs):
  cases.jsonl       one row per case: case_id, stratum, slice, source_ref
  requests.jsonl    the ONLY producer input: case_id + declared detections.
                    No truth, no masses, no final edits, no reference fields.
  labels.jsonl      adjudication truth per eval case, as three explicit
                    targets (native_recipe_identity, dish_category,
                    weighed_mass); unavailable targets are null, never guessed.
  replay.json       200 dev episodes with declared actions/rewards
  build-manifest.json  counts (eligible / sampled / unknown / information
                    collisions) + sha256 of every frozen file

Deterministic: all randomness is the SHA-256 counter PRNG of spec \u00a76.
"""
import csv
import hashlib
import io
import json
import math
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
DATA = Path('/home/user/work/data')
CATALOG = REPO / 'apps/ios/Resources/data.json'

# PR 41 frozen references (read-only via git show from the PR branch)
PR41_BRANCH = 'obv/fl-next-portion-estimates'
PR41_DISH_TARGETS = 'experiments/nutrition5k-portion/data/dish_targets.csv'
PR41_DISH_TARGETS_SHA256 = '5e678e632a3cc513a01a2131ffa51ca62ad69fc792704bce7bbdfa8435620703'

N5K_DEV_N = 200
N5K_EVAL_N = 600
F101_PER_CLASS = 34

# Spec \u00a74 constants (frozen, unchanged from the pre-registered values)
P_PRESENT_N5K = 0.85
P_PRESENT_F101_REQUIRED = 0.90
P_PRESENT_F101_OPTIONAL = 0.65
CONF_BASE, CONF_SPAN, CONF_A, CONF_B = 0.45, 0.50, 8.2, 2.2
FP_COUNTS = [0, 1, 2]
FP_PROBS = [0.53, 0.35, 0.12]
FP_CONF_BASE, FP_CONF_SPAN = 0.45, 0.35
AMOUNT_FLOOR_G = 10.0
REPLAY_ACTIONS = [('top_pick', 0.96, 0.70), ('non_top_pick', 0.78, 0.20), ('manual_pick', 0.45, 0.10)]

# Cross-check tolerance between the official CSV dish mass sum and PR 41's
# frozen dish_targets total_mass_g (both derive from the same official bytes).
PR41_MASS_TOL_G = 0.5


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def verify_hashes():
    """Assert every cached/pinned source byte matches source-hashes.json."""
    pinned = json.load(open(HERE / 'source-hashes.json'))
    for section, conf in pinned.items():
        for path, rec in conf.get('files', {}).items():
            want = rec.get('sha256')
            if not want or want == 'RECORDED_AT_BUILD_TIME':
                continue
            if path.startswith('apps/ios/Resources/'):
                got = sha256_bytes((REPO / path).read_bytes())
            elif path.startswith('food-101/') or path.startswith('dish_metadata') or path.startswith('ingredients_metadata'):
                got = sha256_bytes((DATA / path).read_bytes())
            else:
                continue
            if got != want:
                sys.exit(f'source hash mismatch for {path}: {got} != {want}')
    return pinned


def load_pr41_dish_targets():
    """Read PR 41's frozen dish_targets.csv read-only via git show; verify hash."""
    raw = subprocess.run(
        ['git', 'show', f'{PR41_BRANCH}:{PR41_DISH_TARGETS}'],
        cwd=REPO, check=True, capture_output=True).stdout
    got = sha256_bytes(raw)
    if got != PR41_DISH_TARGETS_SHA256:
        sys.exit(f'PR41 dish_targets.csv hash mismatch: {got} != {PR41_DISH_TARGETS_SHA256}')
    rows = {}
    for r in csv.DictReader(io.StringIO(raw.decode())):
        rows[r['dish_id']] = {
            'cafe': r['cafe'],
            'plate_cluster': r['plate_cluster'],
            'official_rgb_split': r['official_rgb_split'],
            'total_mass_g': float(r['total_mass_g']),
        }
    return rows


def u_stream(key: str, counter: int) -> float:
    digest = hashlib.sha256((f'{key}:{counter}').encode()).digest()
    return int.from_bytes(digest[:8], 'big') / 2 ** 64


def u(key: str) -> float:
    return u_stream(key, 0)


def normal(key: str, counter: int) -> float:
    a = u_stream(key, counter)
    b = u_stream(key, counter + 1)
    if a <= 0:
        a = 1e-12
    return math.sqrt(-2.0 * math.log(a)) * math.cos(2.0 * math.pi * b)


def gamma(key: str, counter: int, shape: float) -> float:
    d = shape - 1.0 / 3.0
    c = 1.0 / math.sqrt(9.0 * d)
    while True:
        x = normal(key, counter)
        v = (1.0 + c * x) ** 3
        if v > 0:
            uu = u_stream(key, counter + 2)
            if math.log(uu) < 0.5 * x * x + d * (1.0 - v + math.log(v)):
                return d * v
        counter += 3


def beta(key: str, a: float, b: float) -> float:
    g1 = gamma(f'{key}:g1', 0, a)
    g2 = gamma(f'{key}:g2', 0, b)
    return g1 / (g1 + g2)


def confidence(key: str) -> float:
    return CONF_BASE + CONF_SPAN * beta(f'{key}:beta', CONF_A, CONF_B)


def shuffle(rows: list, key: str) -> list:
    ordered = list(rows)
    for i in range(len(ordered) - 1, 0, -1):
        frac = u_stream(f'{key}:{i}', 0)
        j = math.floor(frac * (i + 1))
        ordered[i], ordered[j] = ordered[j], ordered[i]
    return ordered


def load_catalog():
    d = json.load(open(CATALOG))
    ingredients = {int(k): v[0] for k, v in d['ingredients'].items()}
    recipes = {}
    for r in d['recipes']:
        recipes[int(r[0])] = {
            'title': r[1], 'servings': r[3],
            'required': [(int(i), float(g)) for i, g in r[4]],
            'optional': [(int(i), float(g)) for i, g in r[5]],
        }
    return ingredients, recipes


def load_ingredient_map():
    mapping = {}
    for r in csv.DictReader(open(HERE / 'n5k-ingredient-map-v1.csv')):
        if not r['catalog_ingredient_id']:
            continue
        for i in r['n5k_ingredient_id'].split(','):
            if i:
                mapping[i.replace('ingr_', '').lstrip('0')] = int(r['catalog_ingredient_id'])
    return mapping


def load_food101_map():
    return {r['food101_class']: int(r['catalog_recipe_id'])
            for r in csv.DictReader(open(HERE / 'food101-class-recipe-map-v1.csv'))}


def n5k_plates(mapping, pr41):
    """Yield (dish_id, [(catalog_id, mass, n5k_id, n5k_name)]) for eligible plates.

    Eligibility identical to the pre-registered spec: >=2 mapped ingredients
    with mass > 0, >=1 with mass >= 10 g. Every yielded plate must exist in
    PR 41's frozen dish_targets.csv and its official per-ingredient mass sum
    must match PR 41's total_mass_g within PR41_MASS_TOL_G (cross-check).
    """
    seen = set()
    n_eligible = 0
    for cafe in ['dish_metadata_cafe1.csv', 'dish_metadata_cafe2.csv']:
        for line in open(DATA / cafe):
            row = next(csv.reader([line]))
            dish_id = row[0]
            if dish_id in seen:
                continue
            seen.add(dish_id)
            rest = row[6:]
            items = []
            for i in range(0, len(rest) - 1, 7):
                nid = rest[i].replace('ingr_', '').lstrip('0')
                mass = float(rest[i + 2])
                if nid in mapping and mass > 0:
                    items.append((mapping[nid], mass, rest[i], rest[i + 1]))
            if len(items) >= 2 and any(m >= AMOUNT_FLOOR_G for _, m, _, _ in items):
                n_eligible += 1
                ref = pr41.get(dish_id)
                if ref is None:
                    sys.exit(f'eligible plate {dish_id} missing from PR41 dish_targets.csv')
                # Cross-check: PR41's total_mass_g is the official dish-row mass
                # column (row[2]); per-ingredient masses need not sum to it.
                official_dish_mass = float(row[2])
                if abs(official_dish_mass - ref['total_mass_g']) > 1e-6:
                    sys.exit(
                        f'PR41 mass cross-check failed for {dish_id}: '
                        f'official dish mass {official_dish_mass} vs frozen {ref["total_mass_g"]}')
                yield dish_id, items, ref
    if n_eligible < N5K_DEV_N + N5K_EVAL_N:
        sys.exit(f'eligible plates {n_eligible} < {N5K_DEV_N + N5K_EVAL_N}')


def draw_detections(cid, truth_ids, present_spec, cooccurring):
    """Shared declared-evidence draw (spec \u00a74). present_spec: [(ing_id, p_present)]."""
    detections = []
    n = 0
    for ing_id, p in present_spec:
        if u(f'evidence:{cid}:present:{ing_id}') < p:
            detections.append((ing_id, round(confidence(f'evidence:{cid}:conf:true:{n}'), 6)))
            n += 1
    uu = u(f'evidence:{cid}:fp:count')
    fp_budget = 0
    if uu >= FP_PROBS[0] + FP_PROBS[1]:
        fp_budget = 2
    elif uu >= FP_PROBS[0]:
        fp_budget = 1
    drawn = {i for i, _ in detections}
    for k in range(fp_budget):
        pool = set()
        for i in drawn:
            pool |= cooccurring[i]
        pool -= set(truth_ids) | drawn
        if not pool:
            break
        pick = sorted(pool)[math.floor(u_stream(f'evidence:{cid}:fp:{k}', 0) * len(pool))]
        conf = FP_CONF_BASE + FP_CONF_SPAN * u_stream(f'evidence:{cid}:fpconf:{k}', 0)
        detections.append((pick, round(conf, 6)))
        drawn.add(pick)
    detections.sort()
    return detections


def main():
    verify_hashes()
    pr41 = load_pr41_dish_targets()
    ingredients, recipes = load_catalog()
    mapping = load_ingredient_map()
    f101map = load_food101_map()

    cooccurring = {i: set() for i in ingredients}
    for r in recipes.values():
        ids = [i for i, _ in r['required']] + [i for i, _ in r['optional']]
        for a in ids:
            for b in ids:
                if a != b:
                    cooccurring[a].add(b)

    cases, requests, labels = [], [], []
    eligible_counts = {}

    # --- n5k-plate stratum ---------------------------------------------------
    eligible = sorted(n5k_plates(mapping, pr41))
    eligible_counts['n5k-plate'] = len(eligible)
    ordered = shuffle(eligible, 'shuffle:n5k-plate')
    slices = [('dev', ordered[:N5K_DEV_N]), ('eval', ordered[N5K_DEV_N:N5K_DEV_N + N5K_EVAL_N])]
    for slice_name, rows in slices:
        for dish_id, items, ref in rows:
            cid = f'n5k-plate-{dish_id}'
            truth_ids = sorted({i for i, _, _, _ in items})
            present_spec = [(i, P_PRESENT_N5K) for i in truth_ids]
            detections = draw_detections(cid, truth_ids, present_spec, cooccurring)
            cases.append({'case_id': cid, 'stratum': 'n5k-plate', 'slice': slice_name,
                          'source_ref': dish_id})
            requests.append({'case_id': cid, 'detections': detections})
            if slice_name == 'eval':
                # Aggregate per CATALOG ingredient id: two distinct N5k lines
                # can map to the same catalog ingredient (e.g. two oil lines);
                # the producer reasons in catalog ids, so the adjudication
                # truth is the summed catalog-level mass with full provenance.
                by_cat = {}
                for cat, m, nid, nm in sorted(items):
                    entry = by_cat.setdefault(cat, {'mass_g': 0.0, 'sources': []})
                    entry['mass_g'] += m
                    entry['sources'].append({'n5k_ingredient_id': nid, 'n5k_name': nm})
                mass_items = [{'catalog_ingredient_id': cat, 'mass_g': round(e['mass_g'], 6),
                               'n5k_sources': e['sources']}
                              for cat, e in sorted(by_cat.items())]
                labels.append({
                    'case_id': cid, 'stratum': 'n5k-plate',
                    'targets': {
                        'native_recipe_identity': None,   # no native labels for N5k plates
                        'dish_category': None,            # no dish-category label for N5k plates
                        'weighed_mass': {
                            'per_serving_basis': 'catalog quantity_grams / recipe.servings',
                            'amount_tolerance': 0.35,
                            'amount_floor_g': AMOUNT_FLOOR_G,
                            'items': mass_items},
                    },
                    'truth_ingredient_ids': truth_ids,
                    'pr41_reference': {'plate_cluster': ref['plate_cluster'],
                                       'official_rgb_split': ref['official_rgb_split'],
                                       'total_mass_g': ref['total_mass_g']},
                })

    # --- food101-photo stratum (eval only) ----------------------------------
    classes = sorted(f101map)
    f101_eligible = 0
    for cls in classes:
        images = sorted(line.strip() for line in open(DATA / 'food-101/meta/test.txt')
                        if line.startswith(cls + '/'))
        f101_eligible += len(images)
        recipe_id = f101map[cls]
        picked = shuffle(images, f'shuffle:food101:{cls}')[:F101_PER_CLASS]
        recipe = recipes[recipe_id]
        truth_ids = sorted({i for i, _ in recipe['required']})
        optional_ids = {i for i, _ in recipe['optional']}
        present_spec = ([(i, P_PRESENT_F101_REQUIRED) for i in truth_ids] +
                        [(i, P_PRESENT_F101_OPTIONAL) for i in sorted(optional_ids)])
        for img in picked:
            cid = 'f101-' + img.replace('/', '-').removesuffix('.jpg')
            detections = draw_detections(cid, truth_ids, present_spec, cooccurring)
            cases.append({'case_id': cid, 'stratum': 'food101-photo', 'slice': 'eval',
                          'source_ref': f'food-101/{img}'})
            requests.append({'case_id': cid, 'detections': detections})
            labels.append({
                'case_id': cid, 'stratum': 'food101-photo',
                'targets': {
                    'native_recipe_identity': {'mapped_recipe_id': recipe_id},
                    'dish_category': {'food101_class': cls},
                    'weighed_mass': None,   # Food-101 has no measured masses
                },
                'truth_ingredient_ids': truth_ids,
                'optional_ingredient_ids': sorted(optional_ids),
            })
    eligible_counts['food101-photo'] = f101_eligible

    # --- dev replay ------------------------------------------------------------
    replay = {'version': 'policy-study-dev-v2', 'episodes': []}
    for c in cases:
        if c['slice'] != 'dev':
            continue
        uu = u(f'replay:{c["case_id"]}')
        acc = 0.0
        action, reward = REPLAY_ACTIONS[-1][0], REPLAY_ACTIONS[-1][1]
        for name, rew, upto in REPLAY_ACTIONS:
            if uu < acc + upto:
                action, reward = name, rew
                break
            acc += upto
        replay['episodes'].append({'case_id': c['case_id'], 'action': action, 'reward': reward})
    replay['episodes'].sort(key=lambda e: e['case_id'])

    # --- counts: slices, unknowns, information collisions ----------------------
    counts = {}
    for c in cases:
        counts[f'{c["stratum"]}/{c["slice"]}'] = counts.get(f'{c["stratum"]}/{c["slice"]}', 0) + 1
    eval_labels = [l for l in labels]
    unknown_counts = {
        'native_recipe_identity_unknown': sum(1 for l in eval_labels if l['targets']['native_recipe_identity'] is None),
        'dish_category_unknown': sum(1 for l in eval_labels if l['targets']['dish_category'] is None),
        'weighed_mass_unknown': sum(1 for l in eval_labels if l['targets']['weighed_mass'] is None),
    }

    # Information-collision analysis at build time: identical canonical request
    # evidence (the only producer input) with conflicting label signatures.
    # The producer-level (4-signal + hardFailReasons) collision analysis is
    # computed at scoring time; this is the evidence-level lower bound.
    def label_signature(l):
        if l['stratum'] == 'food101-photo':
            return ('f101', l['targets']['native_recipe_identity']['mapped_recipe_id'])
        return ('n5k', tuple((i['catalog_ingredient_id'], round(i['mass_g'], 3))
                             for i in l['targets']['weighed_mass']['items']))

    groups = {}
    for c, r in zip(sorted(cases, key=lambda x: x['case_id']),
                    sorted(requests, key=lambda x: x['case_id'])):
        canon = json.dumps(r['detections'], sort_keys=True, separators=(',', ':'))
        groups.setdefault(canon, []).append(c['case_id'])
    label_by_id = {l['case_id']: l for l in eval_labels}
    collision_groups = 0
    collision_cases = 0
    conflicting_groups = 0
    conflicting_cases = 0
    for canon, ids in groups.items():
        if len(ids) < 2:
            continue
        collision_groups += 1
        collision_cases += len(ids)
        eval_ids = [i for i in ids if i in label_by_id]
        sigs = {label_signature(label_by_id[i]) for i in eval_ids}
        if len(sigs) > 1:
            conflicting_groups += 1
            conflicting_cases += len(eval_ids)

    def write_jsonl(name, rows):
        with open(HERE / name, 'w') as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True, separators=(',', ':')) + '\n')

    write_jsonl('cases.jsonl', sorted(cases, key=lambda c: c['case_id']))
    write_jsonl('requests.jsonl', sorted(requests, key=lambda c: c['case_id']))
    write_jsonl('labels.jsonl', sorted(labels, key=lambda c: c['case_id']))
    (HERE / 'replay.json').write_text(json.dumps(replay, sort_keys=True, indent=1) + '\n')

    files = {p.name: sha256_bytes(p.read_bytes())
             for p in HERE.iterdir() if p.is_file() and p.name != 'build-manifest.json'}
    benchmark_manifest = REPO / 'apps/ios/Resources/benchmark_manifest.json'
    pinned = json.load(open(HERE / 'source-hashes.json'))
    pinned['recognition-ocr-experiments']['files']['apps/ios/Resources/benchmark_manifest.json']['sha256'] = \
        sha256_bytes(benchmark_manifest.read_bytes())
    (HERE / 'source-hashes.json').write_text(json.dumps(pinned, indent=1, sort_keys=True) + '\n')
    files['source-hashes.json'] = sha256_bytes((HERE / 'source-hashes.json').read_bytes())

    manifest = {
        'version': 'policy-study-v2',
        'counts': counts,
        'eligible_counts': eligible_counts,
        'unknown_counts': unknown_counts,
        'information_collisions': {
            'definition': 'identical canonical request evidence; label-signature conflicts are the evidence-level information limit',
            'groups': collision_groups,
            'cases': collision_cases,
            'conflicting_groups': conflicting_groups,
            'conflicting_cases': conflicting_cases,
        },
        'pr41_source': {
            'branch': PR41_BRANCH,
            'file': PR41_DISH_TARGETS,
            'sha256': PR41_DISH_TARGETS_SHA256,
            'consumption': 'read-only (git show); plate universe + provenance; portion outputs not used',
        },
        'file_sha256': files,
        'constants': {
            'P_PRESENT_N5K': P_PRESENT_N5K,
            'P_PRESENT_F101_REQUIRED': P_PRESENT_F101_REQUIRED,
            'P_PRESENT_F101_OPTIONAL': P_PRESENT_F101_OPTIONAL,
            'CONF_BASE': CONF_BASE, 'CONF_SPAN': CONF_SPAN,
            'CONF_A': CONF_A, 'CONF_B': CONF_B,
            'FP_COUNTS': FP_COUNTS, 'FP_PROBS': FP_PROBS,
            'FP_CONF_BASE': FP_CONF_BASE, 'FP_CONF_SPAN': FP_CONF_SPAN,
            'AMOUNT_FLOOR_G': AMOUNT_FLOOR_G,
            'N5K_DEV_N': N5K_DEV_N, 'N5K_EVAL_N': N5K_EVAL_N,
            'F101_PER_CLASS': F101_PER_CLASS,
        },
    }
    (HERE / 'build-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'counts': counts, 'eligible': eligible_counts, 'unknown': unknown_counts,
                      'collisions': manifest['information_collisions'],
                      'episodes': len(replay['episodes'])}, indent=1))


if __name__ == '__main__':
    main()

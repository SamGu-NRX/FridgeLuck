#!/usr/bin/env python3
"""Apply the reviewed food-safety corrections to corpus.jsonl.

Each edit names a recipe step, the exact text it replaces, the new
cook-facing text, and the thermometer check the step carries afterwards.
The tool refuses to apply an edit whose step text no longer matches, so a
correction is never applied to a step it was not written for. Re-running
after --write changes nothing.

The originals were authored by fl-original-recipes-f1 on
overhaul/original-recipes; these corrections are made in the corpus because
that is where the recipes ship, and the same edits belong upstream.

Endpoints follow the USDA FSIS chart encoded in food_safety.py. Text states
the thermometer, the temperature in F and C, and the rest for whole cuts.

    python3 -I data/recipes/tools/fix_doneness.py [--write]
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import corpus_io  # noqa: E402
import food_safety  # noqa: E402

REMOVE = "remove"


@dataclass(frozen=True)
class Edit:
    rid: str
    step: int
    old: str
    new: str
    # (class, temp_f) to set the step's check, REMOVE to drop it, None to keep it
    safety: tuple[str, int] | str | None = None
    reheat: bool | None = None


def check(cls: str, temp: int) -> tuple[str, int]:
    if cls not in food_safety.MIN_F or temp < food_safety.MIN_F[cls]:
        raise ValueError(f"{cls} {temp} is below the FSIS minimum")
    return (cls, temp)


# Finding 1: endpoints. Casseroles reach 165 F; whole cuts state the
# 3-minute rest; mixtures with raw egg reach 160 F; reheats carry their own
# 165 F check; every required food has a check.
ENDPOINT_EDITS: tuple[Edit, ...] = (
    Edit("fl-original-0008", 4,
         "Bake until the centre reads 160 °F on an instant-read thermometer and the top is lightly puffed.",
         "Bake until an instant-read thermometer in the centre reads 165 °F (74 °C), the casserole minimum, and the top is lightly puffed.",
         check("leftovers", 165)),
    # bean patties bound with raw egg: the check names the egg it protects
    Edit("fl-original-0014", 3,
         "Pan-fry in the remaining oil over medium heat, flipping once, until crusty and an instant-read thermometer in a patty centre reads 165 °F.",
         "Pan-fry in the remaining oil over medium heat, flipping once, until crusty and an instant-read thermometer in a patty centre reads 165 °F.",
         check("egg", 165)),
    # FSIS: cook to the minimum before removing from heat; no carryover credit
    Edit("fl-original-0023", 2,
         "Take the steak off at 140 °F on an instant-read thermometer — it climbs to the 145 °F FSIS minimum as it rests — and rest it on a board.",
         "Take the steak off the heat when an instant-read thermometer in the thickest part reads 145 °F (63 °C), then rest it on a board for at least 3 minutes."),
    Edit("fl-original-0034", 3,
         "Braise until a fork twists into the meat with no resistance and an instant-read thermometer reads well past the 145 °F FSIS minimum for beef.",
         "Braise until a fork twists into the meat with no resistance and an instant-read thermometer in the thickest part reads well past 145 °F (63 °C), the FSIS minimum for beef. The roast rests at least 3 minutes before slicing."),
    Edit("fl-original-0035", 1,
         "Line the slow cooker with the sliced onions and lay the pork on top; cover and cook on low until the meat collapses when prodded and an instant-read thermometer reads far past the 145 °F FSIS minimum for fresh pork.",
         "Line the slow cooker with the sliced onions and lay the pork on top; cover and cook on low until the meat collapses when prodded and an instant-read thermometer in the thickest part reads far past 145 °F (63 °C), the FSIS minimum for fresh pork. Let it rest at least 3 minutes once it is out of the cooker."),
    Edit("fl-original-0094", 2,
         "Cover and braise on the lowest heat until the pork reads 145 °F with a thermometer and shreds under a fork.",
         "Cover and braise on the lowest heat until the pork reads at least 145 °F (63 °C) on a food thermometer and shreds under a fork, then let it rest 3 minutes."),
    Edit("fl-original-0095", 0,
         "Reheat the rice and divide between warm bowls.",
         "Reheat the rice until a food thermometer reads 165 °F (74 °C), then divide between warm bowls.",
         check("leftovers", 165), reheat=True),
    Edit("fl-original-0102", 3,
         "Top with the cheddar and bake until the edges bubble and the cheese runs lacquered.",
         "Top with the cheddar and bake until the edges bubble and a food thermometer in the centre of the gratin reads 165 °F (74 °C), the casserole minimum.",
         check("leftovers", 165)),
    # the check sat on the eggplant step; it belongs where the bacon cooks
    Edit("fl-original-0107", 0,
         "Render the bacon slowly in the oil until the fat runs clear and the pieces sit in their own gloss; lift them out with a slotted spoon.",
         "Render the bacon slowly in the oil until the pieces sit in their own gloss and a food thermometer pushed into the thickest piece reads 145 °F (63 °C); lift them out with a slotted spoon and let them rest at least 3 minutes.",
         check("meat_whole_cut_pork", 145)),
    Edit("fl-original-0107", 1,
         "Cook the eggplant cubes in that bacon fat over real heat, stirring only when they catch, until they collapse into softness.",
         "Cook the eggplant cubes in that bacon fat over real heat, stirring only when they catch, until they collapse into softness.",
         REMOVE),
    # names the chicken so the breading step ties the raw egg to it
    Edit("fl-original-0124", 1,
         "Bread them: flour, then beaten egg, then the panko pressed on hard, and rest them five minutes so the coating stays put.",
         "Bread the chicken: flour, then beaten egg, then the panko pressed on hard, and rest the cutlets five minutes so the coating stays put."),
    # picked crab is sold cooked; warming it is reheating
    Edit("fl-original-0130", 2,
         "Add the crab with a ladle of pasta water and fold it through warm; it needs heat, not cooking.",
         "Add the crab with a ladle of pasta water and fold it through until a food thermometer in the sauce reads 165 °F (74 °C); picked crab is usually already cooked, so heat it as you would leftovers.",
         check("flesh_shellfish", 165)),
    Edit("fl-original-0139", 0,
         "Crisp the bacon in the oil in a wide pan until it leans dark and the fat has rendered; lift out, keep the fat.",
         "Crisp the bacon in the oil in a wide pan until it leans dark, the fat has rendered and a food thermometer pushed into the thickest piece reads 145 °F (63 °C); lift out, keep the fat, and let the bacon rest at least 3 minutes."),
    Edit("fl-original-0149", 3,
         "Tuck the chicken slices into the pasta, cover with mozzarella, and bake until the top blisters and bubbles.",
         "Tuck the chicken slices into the pasta, cover with mozzarella, and bake until the top blisters and bubbles and a food thermometer through a chicken slice in the centre reads 165 °F (74 °C).",
         check("leftovers", 165)),
    # salmon and prawn patties bound with raw egg: egg minimum, not fish
    Edit("fl-original-0178", 2,
         "Fry the patties in the oil, four or five minutes a side, until a food thermometer at the centre reads 145 °F.",
         "Fry the patties in the oil, four or five minutes a side, until a food thermometer at the centre reads 160 °F (71 °C), the minimum for the raw egg bound into the mix.",
         check("egg", 160)),
    Edit("fl-original-0200", 2,
         "Scatter the bread crumbs over, drizzle with a little more oil, and bake until the top is deeply golden and the lentils have drunk the liquid.",
         "Scatter the bread crumbs over, drizzle with a little more oil, and bake until the top is deeply golden, the lentils have drunk the liquid and a food thermometer in the centre reads 165 °F (74 °C), the casserole minimum.",
         check("leftovers", 165)),
    Edit("fl-original-0225", 2,
         "Cover the pot and let it murmur in a low oven, turning the roast once, until the meat relaxes when pressed and a food thermometer in the thick end reads 145 °F.",
         "Cover the pot and let it murmur in a low oven, turning the roast once, until the meat relaxes when pressed and a food thermometer in the thick end reads at least 145 °F (63 °C)."),
    Edit("fl-original-0225", 3,
         "Rest the roast under foil while the braising liquid reduces to a sauce, then serve in wide bowls with the vegetables tucked alongside.",
         "Rest the roast under foil for at least 3 minutes while the braising liquid reduces to a sauce, then serve in wide bowls with the vegetables tucked alongside."),
    Edit("fl-original-0231", 2,
         "Keep the pot at a shiver, half-covered, for the long haul, topping up when the sauce sinks below the meat, until the chuck shreds under a fork's pull.",
         "Keep the pot at a shiver, half-covered, for the long haul, topping up when the sauce sinks below the meat, until the chuck shreds under a fork's pull and a food thermometer in the thickest part reads well past 145 °F (63 °C). Rest the meat at least 3 minutes before you break it up into the sauce."),
    Edit("fl-original-0235", 1,
         "Return the lamb with the tomatoes and oregano, cover, and braise until the cubes bend when pinched.",
         "Return the lamb with the tomatoes and oregano, cover, and braise until the cubes bend when pinched and a food thermometer in the thickest cube reads at least 145 °F (63 °C); let it rest 3 minutes off the heat."),
    # lamb and orzo baked together in one dish: the casserole endpoint
    Edit("fl-original-0235", 2,
         "Stir the orzo straight into the lamb sauce with hot water to loosen, and bake uncovered until the orzo swells and the top sets.",
         "Stir the orzo straight into the lamb sauce with hot water to loosen, and bake uncovered until the orzo swells, the top sets and a food thermometer in the centre reads 165 °F (74 °C).",
         check("leftovers", 165)),
    Edit("fl-original-0239", 1,
         "Squeeze the orange and lime over, tuck the squashed halves into the pot, add a cup of water, cover, and braise low until the pork collapses when shouldered with a fork.",
         "Squeeze the orange and lime over, tuck the squashed halves into the pot, add a cup of water, cover, and braise low until the pork collapses when shouldered with a fork and a food thermometer in the thickest part reads well past 145 °F (63 °C). Rest it at least 3 minutes before shredding."),
    Edit("fl-original-0240", 2,
         "Simmer covered until the pork shreds under pressure from a spoon and the broth has gone pale green and rich.",
         "Simmer covered until the pork shreds under pressure from a spoon, a food thermometer in a thick cube reads well past 145 °F (63 °C), and the broth has gone pale green and rich."),
    Edit("fl-original-0240", 3,
         "Add the beans for the last stretch, then finish with cilantro and lime and eat with rice or tortillas.",
         "Add the beans for the last stretch, then take the pot off the heat, let it rest 3 minutes, and finish with cilantro and lime; eat with rice or tortillas."),
    Edit("fl-original-0243", 1,
         "Brown the shanks in a little oil, add a cup of water, cover tightly, and braise very gently, turning once, until the meat retreats from the bone.",
         "Brown the shanks in a little oil, add a cup of water, cover tightly, and braise very gently, turning once, until the meat retreats from the bone and a food thermometer in the thickest part, away from the bone, reads well past 145 °F (63 °C)."),
    Edit("fl-original-0243", 2,
         "Uncover and reduce the sauce until it clings to the shanks and the oil splits at the edges.",
         "Uncover and reduce the sauce until it clings to the shanks and the oil splits at the edges, then rest the shanks 3 minutes off the heat."),
    Edit("fl-original-0247", 2,
         "Cook uncovered on the lowest heat, stirring from the bottom now and then, for a long time — until the coconut oil has fried the beef dark and the sauce is almost dry.",
         "Cook uncovered on the lowest heat, stirring from the bottom now and then, for a long time — until the coconut oil has fried the beef dark, the sauce is almost dry, and a food thermometer in a thick piece of beef reads well past 145 °F (63 °C). Let it rest 3 minutes off the heat."),
    Edit("fl-original-0251", 2,
         "Stir the mustard with half a cup of water, return the chops, cover, and braise gently until a food thermometer in the thick end reads 145 °F.",
         "Stir the mustard with half a cup of water, return the chops, cover, and braise gently until a food thermometer in the thick end reads 145 °F (63 °C), then rest the chops for 3 minutes."),
    Edit("fl-original-0252", 1,
         "Soften the onion and carrot coins in the fat, add the rinsed lentils and two cups of water, and simmer until the lentils are tender.",
         "Soften the onion and carrot coins in the fat, add the rinsed lentils and two cups of water, and simmer until the lentils are tender and a food thermometer in a sausage coin reads 160 °F (71 °C).",
         check("meat_ground", 160)),
    Edit("fl-original-0275", 2,
         "Bake with the lid on, checking once to top up water, until the sauce has gone deep mahogany and thick enough to coat a spoon.",
         "Bake with the lid on, checking once to top up water, until the sauce has gone deep mahogany and thick enough to coat a spoon, and a food thermometer in a cube of salt pork reads at least 145 °F (63 °C).",
         check("meat_whole_cut_pork", 145)),
    Edit("fl-original-0275", 3,
         "Season at the end only — the pork has been salting the pot all along — and serve with brown bread or toast.",
         "Rest the pot 3 minutes, then season at the end only — the pork has been salting the pot all along — and serve with brown bread or toast."),
    Edit("fl-original-0276", 1,
         "Roast it low in a covered pan with a splash of water, fat cap up, until the bone pulls free and a food thermometer reads 145 °F with the meat slack and giving.",
         "Roast it low in a covered pan with a splash of water, fat cap up, until the bone pulls free and a food thermometer in the thickest part reads well past 145 °F (63 °C) with the meat slack and giving."),
    Edit("fl-original-0276", 2,
         "While it rests, shred the cabbage and dress it with the yogurt, a slug of the vinegar, salt and pepper.",
         "While it rests for at least 3 minutes, shred the cabbage and dress it with the yogurt, a slug of the vinegar, salt and pepper."),
    Edit("fl-original-0277", 2,
         "Return everything to the pot with the carrot batons, cover, and braise at a tremble until the meat gives under a spoon.",
         "Return everything to the pot with the carrot batons, cover, and braise at a tremble until the meat gives under a spoon and a food thermometer in the thickest piece reads well past 145 °F (63 °C)."),
    Edit("fl-original-0277", 3,
         "Rest, taste the sauce for depth, and serve with the carrots and something plain — potatoes or wide noodles — beside.",
         "Rest the meat at least 3 minutes, taste the sauce for depth, and serve with the carrots and something plain — potatoes or wide noodles — beside."),
    Edit("fl-original-0278", 1,
         "Add the chipotle and tomatoes, cook down dark, then return the pork with water to cover and simmer until the cubes loosen at the edges.",
         "Add the chipotle and tomatoes, cook down dark, then return the pork with water to cover and simmer until the cubes loosen at the edges and a food thermometer in a thick cube reads well past 145 °F (63 °C)."),
    Edit("fl-original-0278", 2,
         "Add the hominy and warm through so it drinks the broth.",
         "Add the hominy and warm through so it drinks the broth, then let the pot rest 3 minutes off the heat."),
    Edit("fl-original-0284", 1,
         "Sear the chuck on every side in a Dutch oven, pour the sauce over with water to cover, and braise covered in a low oven until the beef falls when nudged.",
         "Sear the chuck on every side in a Dutch oven, pour the sauce over with water to cover, and braise covered in a low oven until the beef falls when nudged and a food thermometer in the thickest part reads well past 145 °F (63 °C)."),
    Edit("fl-original-0284", 2,
         "Skim the fat from the broth, shred the beef, and keep both warm.",
         "Rest the beef at least 3 minutes, skim the fat from the broth, shred the beef, and keep both warm."),
    # eggs were pulled early to finish in the wrap, then frozen
    Edit("fl-original-0287", 1,
         "Scramble the eggs gently in the same pan, off the heat early — they finish inside the wrap.",
         "Scramble the eggs gently in the same pan until a food thermometer reads 160 °F (71 °C).",
         check("egg", 160)),
    Edit("fl-original-0287", 3,
         "Eat one now; freeze the other and reheat from frozen until a food thermometer in the middle reads 165 °F.",
         "Eat one now; freeze the other and reheat from frozen until a food thermometer in the middle reads 165 °F.",
         reheat=True),
    Edit("fl-original-0309", 1,
         "Cook the peppers and onion in the rendered fat until they slump and sweeten, then return the sausage coins.",
         "Cook the peppers and onion in the rendered fat until they slump and sweeten, then return the sausage coins and cook until a food thermometer in a thick coin reads 160 °F (71 °C).",
         check("meat_ground", 160)),
    # FSIS: measure away from bone; whole cuts rest
    Edit("fl-original-0310", 2,
         "Pour the stock down the side of the pan, cover, and simmer gently until a food thermometer at the bone reads 145 °F.",
         "Pour the stock down the side of the pan, cover, and simmer gently until a food thermometer in the thickest part, away from the bone, reads 145 °F (63 °C); rest the chops 3 minutes."),
    Edit("fl-original-0321", 2,
         "Scramble the eggs in the same pan, then add the rice and break it up, letting it toast against the metal.",
         "Scramble the eggs in the same pan until a food thermometer reads 160 °F (71 °C), then add the rice and break it up, letting it toast against the metal.",
         check("egg", 160)),
    Edit("fl-original-0332", 2,
         "Tear the mozzarella over and bake until it pools and blister-browns at the edges.",
         "Tear the mozzarella over and bake until it pools and blister-browns at the edges and a food thermometer in the centre reads 165 °F (74 °C), the casserole minimum.",
         check("leftovers", 165)),
    # raw egg is mixed into the poached cod; the cakes need the egg minimum
    Edit("fl-original-0343", 3,
         "Pan-fry in oil until the crusts brown and release from the pan — the centres are already cooked, held at 145 °F from the poach.",
         "Pan-fry in oil until the crusts brown and release from the pan and a food thermometer in the centre of a cake reads 160 °F (71 °C); the raw egg in the mix needs it.",
         check("egg", 160)),
    Edit("fl-original-0359", 3,
         "Shred the chicken back through the rice, stir in the cheddar in handfuls, and rest uncovered until it bubbles.",
         "Shred the chicken back through the rice, stir in the cheddar in handfuls, and return the dish to the oven uncovered until it bubbles and a food thermometer in the centre reads 165 °F (74 °C), the casserole minimum.",
         check("leftovers", 165)),
)

EDITS: tuple[Edit, ...] = ENDPOINT_EDITS


def _safety(cls: str, temp: int, current: Any) -> dict[str, Any]:
    if isinstance(current, dict) and current.get("class") == cls and current.get("temp_f") == temp:
        return current
    return {"class": cls, "temp_f": temp, "method": "thermometer",
            "source": food_safety.FSIS_SOURCE}


def apply(recipes: dict[str, dict[str, Any]], edits: tuple[Edit, ...]) -> list[str]:
    """Apply edits in place; return the ids changed. Raises on a stale edit."""
    changed: list[str] = []
    for e in edits:
        r = recipes.get(e.rid)
        if r is None:
            raise SystemExit(f"{e.rid}: not in the corpus")
        steps = r["steps"]
        if e.step >= len(steps):
            raise SystemExit(f"{e.rid} step[{e.step}]: recipe has {len(steps)} steps")
        step = steps[e.step]
        if step["text"] not in (e.old, e.new):
            raise SystemExit(f"{e.rid} step[{e.step}]: text no longer matches the edit\n"
                             f"  found: {step['text']!r}\n  expected: {e.old!r}")
        before = dict(step)
        step["text"] = e.new
        if e.safety == REMOVE:
            step.pop("safety", None)
        elif isinstance(e.safety, tuple):
            step["safety"] = _safety(e.safety[0], e.safety[1], step.get("safety"))
        if e.reheat is not None:
            if e.reheat:
                step["reheat"] = True
            else:
                step.pop("reheat", None)
        if step != before and e.rid not in changed:
            changed.append(e.rid)
    return changed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true", help="write corpus.jsonl (default: dry run)")
    args = ap.parse_args()
    lines = corpus_io.read_jsonl(corpus_io.CORPUS)
    recipes = {l.obj["id"]: l.obj for l in lines}
    changed = apply(recipes, EDITS)
    print(f"{len(EDITS)} edits; {len(changed)} recipe(s) changed")
    remaining = {rid: food_safety.endpoint_violations(r) for rid, r in recipes.items()}
    remaining = {k: v for k, v in remaining.items() if v}
    for rid, v in remaining.items():
        for x in v:
            print(f"  still failing: {x}")
    print(f"endpoint rules: {len(remaining)} recipe(s) still failing")
    if args.write and changed:
        corpus_io.write_jsonl(corpus_io.CORPUS, lines)
        print(f"wrote {corpus_io.CORPUS.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

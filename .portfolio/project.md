---
# kgu.one builds this project's page from this file (https://kgu.one/projects/fridgeluck).
# When a change alters what the project does, its results, awards, stack or links,
# update this file in the same change. Rules:
# - Facts only, each one backed by this repo, the resume or a public source.
# - No em dashes and no middle dots.
# - line: at most 120 characters, ending in a period. What someone does or gets,
#   then one mechanism. No adjectives.
# - The body opens with one paragraph of 50 to 80 words, first person: what it is,
#   who used it, the hard part, one fact. The site uses it as the summary.
# - The rest of the body is the full write-up, in plain Markdown (## and ###
#   headings, lists, emphasis, inline code, https links), at most 1,500 words.
title: FridgeLuck
kind: project
date: 2026-02
line: Potluck, but for your fridge. Snap your shelves for recipes, and it only asks about the items it isn’t sure it saw.
award: 2nd place, HackTAMS
badge: 2nd
stack: [Swift, Apple Vision, Gemini]
links:
  - label: Code
    href: https://github.com/SamGu-NRX/FridgeLuck
---

FridgeLuck is an iOS app that looks at your fridge, suggests what to cook and tracks what you eat. Apple Vision and OCR read the shelves on the device, Gemini Live looks at the whole scene, and a Bayesian confidence model decides which detections to trust and which to ask you about. I wrote most of it in Swift. It took second place at HackTAMS, and my poster on it won first place at UNT’s AI in Action competition.

## What to trust, what to ask

Vision models guess wrong. A recipe app that trusts every guess tells you to cook with things you don’t have, and one that asks about every item makes you type your fridge in by hand. So each detection lands in one of three tiers. Confident items are confirmed automatically, middling ones get a quick question, and weak ones show up only as possible items.

The confidence comes from a small Bayesian learner I designed. Each kind of signal keeps a trust score shaped like a beta distribution, starting from a prior set by how reliable that signal tends to be, so an exact OCR match starts out trusted more than a fuzzy one. When you log a meal from a photo, the app records how its guess held up. Choosing its top recipe counts as a strong success, choosing a lower candidate counts for less, and picking a recipe by hand counts least. Those outcomes update the trust scores, so the model leans on whichever signals keep turning out right.

## What’s in the app

- A bundled cookbook of 166 recipes and an ingredient catalog of 800 foods built from USDA nutrition data, with 3,998 alternate names to match detections against.
- Recipe generation and ranking with Gemini 2.5 Flash, grounded in the ingredients it photographed and in that catalog.
- Meal logging from a photo of your plate, which matches the dish to a recipe and updates your inventory.
- Apple Health sync for calories, protein, carbohydrates, fat, fiber, sugar and sodium.
- A recipe ranking that learns from you, using your past star ratings, the cuisines you cook and a penalty for repeating the same dish.

## Who built it

I wrote most of the app and designed the confidence model and the tiers it feeds. Shrey Suri and Andrew Wang also contributed to the repository. Afterward I wrote the confidence work up as a poster, “FridgeLuck: A Confidence-Aware Framework for Human-AI Collaboration in Food Waste Reduction,” and presented it myself at UNT in April 2026.

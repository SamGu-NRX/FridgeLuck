---
# kgu.one builds this project's page from this file (https://kgu.one/projects/fridgeluck).
# When a change alters what the project does, its results, awards, stack or links,
# update this file in the same change. Rules:
# - Facts only, each one backed by this repo, the resume or a public source.
# - No em dashes and no middle dots.
# - line: at most 120 characters, ending in a period. What someone does or gets,
#   then one mechanism. No adjectives.
# - The paragraph after this header: 50 to 80 words, first person. What it is, who
#   used it, the hard part, one fact.
title: FridgeLuck
kind: project
date: 2026-02
line: Snap your fridge and get recipes. It only asks about the items it isn’t sure it saw.
award: 2nd place, HackTAMS
badge: 2nd
stack: [Swift, Apple Vision, Gemini]
links:
  - label: Code
    href: https://github.com/SamGu-NRX/FridgeLuck
---

FridgeLuck is a Swift iOS app. Apple Vision and OCR read the fridge on the device, Gemini Live looks at the whole scene, and recipes come from a bundled cookbook of 166 recipes with USDA nutrition data. The part I care about is the Bayesian confidence model: it decides which detections to trust, asks you to confirm only the doubtful ones, and learns from which recipe you pick when you log a meal.

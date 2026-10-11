# Direction H screens: tonight (light/dark) and tonight-xxl (light, Dynamic Type XXL).
from hkit import tabbar, note, fit

CSS = """
.eyebrow{display:flex;align-items:center;gap:8px}
.eyebrow i{width:10px;height:10px;background:var(--acc);border-radius:2px}
.title{font-family:var(--serif);font-size:32px;line-height:34px;font-weight:700;letter-spacing:-.02em;margin:10px 0 6px}
.fitrow{display:flex;justify-content:space-between;align-items:center;margin-top:14px}
.fitrow .why{margin-top:8px}
.actions{margin-top:48px;display:grid;gap:4px}   /* deciding: 48 above primary */
"""

def body(xxl=False):
    x = " xxl" if xxl else ""
    return f'''  <div class="screen"><div class="scroll dg{x}" style="padding-bottom:190px">
    <header class="head in" style="--i:0"><h1>Tonight</h1><span class="cap c2 mono">Sat 11 Oct</span></header>

    <section>
      <div class="eyebrow in" style="--i:0"><i></i><span class="label">From your fridge</span></div>
      <h2 class="title in" style="--i:1">Ginger chicken udon noodles</h2>
      <p class="mono sec c2 in" style="--i:2">25 min &middot; 2 servings &middot; 520 kcal</p>
      <div class="photo in" style="--i:2;height:300px;margin-top:16px"><span>photo: overhead, daylight, 4:5 crop</span></div>
      <div class="fitrow in" style="--i:3">
        {fit(9, 10)}
        <span class="mono" style="font-weight:500">9 of 10 &middot; 1 swap</span>
      </div>
      <p class="sec in" style="--i:4;margin-top:8px">Everything except lime. Swap in a lemon, you have two.</p>
      <p class="sec c2 in why" style="--i:4">Why: you've cooked noodles four times this month and rated two of them 5. Under 30 min, like 11 of your last 14 cooks.</p>
      <div class="actions in" style="--i:5">
        <button class="btn primary">Cook this</button>
        <button class="btn">Something else</button>
      </div>
    </section>

    <section class="sect">
      <h3>Use soon <a href="#">Kitchen</a></h3>
      <div class="row"><span class="n">Spinach</span><span class="tag">2 days</span></div>
      <div class="row"><span class="n">Greek yogurt <span class="mono c2">500 g</span></span><span class="tag">tomorrow</span></div>
      <div class="row"><span class="n">Lime <span class="mono c2">&frac12;</span></span><span class="tag">today</span></div>
    </section>

    <section class="sect">
      <h3>Also possible</h3>
      <div class="row"><span class="n">Creamy pesto &amp; kale pasta<br><span class="cap c2">Uses the spinach</span></span><span class="q c2">15 min</span><span class="q">10 of 10</span></div>
      <div class="row"><span class="n">Butter bean curry<br><span class="cap c2">You cook this about every 10 days</span></span><span class="q c2">35 min</span><span class="q">10 of 10</span></div>
      <div class="row"><span class="n">Chicken, leek &amp; brown rice stir-fry</span><span class="q c2">40 min</span><span class="q">8 of 10</span></div>
    </section>

    <section class="sect">
      <h3>Your table <a href="#">Flat 4B</a></h3>
      <div class="row"><span class="n">Maya cooked Butter bean curry last night. <span class="c2">&ldquo;Add lemon at the end.&rdquo;</span></span><span class="q">10 of 10</span></div>
    </section>
  </div></div>
'''

STATES = [
  ("empty", "No scan yet. Hero becomes: &ldquo;Scan a shelf and I'll pick tonight's dinner.&rdquo; with a sample pick below, labelled &ldquo;Example&rdquo;. The scan button gets an accent ring for the first session only; manual entry from Kitchen stays first-class (unknown kitchen)."),
  ("sparse", "3&ndash;5 items known: pick stays, fit line becomes the honest list &ldquo;You'd need: rice noodles, 1 chicken breast&rdquo; under the buttons &mdash; never a fake &ldquo;cook with 2 swaps&rdquo;."),
  ("nothing fits", "Best fit under 6 of 10: eyebrow reads &ldquo;Closest with what you have&rdquo;, pick still shows, button reads &ldquo;Cook with 2 swaps&rdquo;. Below the buttons: &ldquo;Shopping list&rdquo; and &ldquo;Pick from saved&rdquo; &mdash; never an invented pick."),
  ("mid-cook", "A cook in progress replaces the hero with a resume bar: dish, &ldquo;Step 4 of 8&rdquo;, running timer, &ldquo;Resume&rdquo;. Everything else unchanged."),
  ("late", "After 21:30 the h1 reads &ldquo;Tomorrow&rdquo; and the pick is tomorrow's dinner. Use soon stays."),
  ("question", "A taste pattern at five observations adds one line under the Why: &ldquo;You've taken coriander out 5 times. Stop suggesting it? Yes / No&rdquo;. Asked once, never repeated; rejections never become dislikes."),
  ("loading", "Local fit is instant. Why and table lines arrive late: their height is reserved, one 2 px indeterminate line under the title, no shimmer."),
  ("error", "Recommendation service down: last pick with &ldquo;As of 6:10 pm&rdquo; in the eyebrow. Fit, use soon and alternatives compute on device and always render."),
]

MOTION = [
  ("enter", "Three blocks rise 6 px on the snap token (220 ms), 40 ms apart; nothing after the third block staggers. Entrance completes in 260 ms; the frame is stable by 450 ms."),
  ("press", "Buttons and rows scale to 0.97 over 120 ms, back with snap."),
  ("swap", "&ldquo;Something else&rdquo; crossfades the hero over 150 ms (fade token) under a stable frame; the photo block keeps its size so nothing jumps."),
  ("reduced", "Entrance becomes a 150 ms opacity fade, stagger to 0; press scale stays (120 ms, confirms the tap)."),
]

NOTE_TXT = [
  "Deciding density: 24 px side margins, 32 between blocks, 48 above the primary action. One pick, its fit, its reason, and the button; two alternatives and the use-soon list come after, so the screen still works when the pick is wrong.",
  "The hybrid keeps P's warmth (linen ground, walnut ink, terracotta as the single accent, a serif that appears only on the dish name) inside F's structure (flat content, hairlines, mono numerals, one accent with one meaning). The accent square beside &ldquo;From your fridge&rdquo; is the only chromatic mark above the fold; it marks the pick and nothing else.",
  "The serif is the dish's voice: display size only, never on labels, controls or numerals. Every numeral with a unit is mono and tabular &mdash; both directions agree on that.",
  "Fit is &ldquo;9 of 10 &middot; 1 swap&rdquo;, never a percentage. In the meter the nine filled squares are walnut and the one missing line is the only terracotta pixel on screen: the gap is the story, and it always has a word beside it.",
  "The Why line is evidence from the taste profile, written as counts, never flattery. Tapping it opens the profile sentence it came from.",
]

def build(write, page, phone):
    for theme in ("light", "dark"):
        n = note("Tonight", NOTE_TXT, STATES, MOTION)
        html = page(f"Tonight ({theme})", theme, phone(body(), theme) + tabbar("tonight"), n, CSS)
        write(f"tonight{'-dark' if theme == 'dark' else ''}.html", html)

    # Tonight at Dynamic Type XXL (light only, per the screen list).
    xxl_css = CSS + """
.xxl{font-size:23px;line-height:30px}
.xxl .head h1{font-size:36px;line-height:40px}
.xxl .title{font-size:40px;line-height:46px}
.xxl .sec{font-size:20px;line-height:27px}
.xxl .label{font-size:17px;line-height:22px}
.xxl .cap{font-size:17px;line-height:22px}
.xxl .row{min-height:56px;padding:12px 0}
.xxl .row .q{font-size:19px;line-height:24px}
.xxl .tag{font-size:16px;line-height:20px;padding:4px 9px}
.xxl .btn{height:56px;font-size:20px;border-radius:14px}
.xxl .sect h3{font-size:16px;line-height:20px}
.xxl .sect{margin-top:28px}
.xxl .fit i{width:11px;height:11px}
.xxl .photo{border-radius:16px}
"""
    n = note("Tonight at XXL",
             ["Dynamic Type to XXL (SwiftUI accessibility sizes): body 23/30, secondary 20/27, serif pick 40/46, rows grow to 56 px, buttons 56 px. The layout keeps its order: pick, fit, reason, actions, then lists.",
              "What moves: the Why line wraps to three lines and the serif title to two; the fit meter squares grow to 11 px. What must not move: targets stay at or above 44 px (56 in actions), the mono numerals scale with the same tabular figures, and no block clips or overlaps.",
              "Same contract copy as the base Tonight; only sizes reflow. This frame is the Dynamic Type proof for the deciding-density screen."],
             [("clip", "At XXL nothing truncates silently: the title wraps to two lines and the use-soon tags wrap to their own row edge; the longest strings in the app (dish names) were set with these sizes."),
              ("hero", "The photo block keeps its 4:5 ratio and the pick stays above the fold: the deciding screen never pushes the primary action off screen at XXL.")],
             [("reduced", "Same reduced-motion contract as the base screen: opacity-only entrance, no stagger.")])
    html = page("Tonight (XXL)", "light", phone(body(xxl=True), "light") + tabbar("tonight"), n, xxl_css)
    write("tonight-xxl.html", html)

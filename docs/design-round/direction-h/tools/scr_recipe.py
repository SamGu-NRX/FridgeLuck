# Direction H screens: recipe (light/dark) and cook-lechef (cook palette).
from hkit import note, fit

RECIPE_CSS = """
.nav{display:flex;justify-content:space-between;align-items:center;height:44px;padding:6px 0 0}
.nav a{color:var(--accink);text-decoration:none;font-size:15px;display:flex;align-items:center;gap:4px}
.title{font-family:var(--serif);font-size:32px;line-height:34px;font-weight:700;letter-spacing:-.02em;margin:8px 0 6px}
.fitblock{display:flex;justify-content:space-between;align-items:center;border:1px solid var(--rule);border-radius:14px;padding:14px 16px;margin-top:16px}
.fitblock .q{font-size:17px;line-height:22px;font-weight:500}
.stepper{display:inline-flex;align-items:center;gap:10px;font-weight:400;color:var(--ink2)}
.stepper b{display:grid;place-items:center;width:32px;height:32px;border-radius:10px;box-shadow:inset 0 0 0 1px var(--rule2);font-weight:500;font-family:var(--mono)}
.swap{display:block;margin-top:6px}
.swap b{display:inline-block;font-size:12px;line-height:18px;font-weight:600;padding:1px 7px;border-radius:6px;background:var(--accsoft);color:var(--accink);margin-right:6px}
.swap span{font-size:13px;line-height:18px;color:var(--accink)}
.swapnote{font-size:13px;line-height:18px;color:var(--ink2);margin-top:4px}
.steps .num{font-family:var(--mono);font-size:13px;color:var(--ink3);width:18px;flex:none}
.nut{display:flex;gap:24px;padding:12px 0 4px}
.nut b{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:17px;font-weight:500}
.nut small{display:block;font-size:13px;color:var(--ink2);margin-top:2px}
.bar{width:72px;height:4px;border-radius:2px;background:var(--rule);margin-top:6px}
.bar i{display:block;height:4px;border-radius:2px;background:var(--ink)}
"""

RECIPE_NOTE = [
  "A document, not a stack of cards: serif title, mono meta, photo, then the fit block as the one framed element because it is the app's promise. Everything else is hairline rows on the page.",
  "Ingredients are quantity rows with the pantry-truth states: filled square = sufficient; hollow accent stroke = short or missing, carrying its swap inline in an accent-soft chip with the evidence (&ldquo;you have 2&rdquo;) and the consequence (&ldquo;a little sharper, less floral&rdquo; &mdash; never &ldquo;no change&rdquo;); grey ring = assumed staple, captioned; a dashed square with &ldquo;check&rdquo; = quantity unknown. Every substitution rechecks all eaters' allergens.",
  "&ldquo;Why it fits you&rdquo; is three sentences with mono evidence counts; the heading links to the taste profile so every claim is inspectable and correctable.",
  "Macros are three ink bars of different lengths with mono labels, not coloured rings. Cook notes appear only above the ten-cook minimum; this recipe has 212.",
  "The floating dock holds the two entrances to cook mode: &ldquo;Cook with LeChef&rdquo; (voice on) and &ldquo;Just the steps&rdquo; (the default when voice is not opted in). It is the only glass element and the only shadow on a content screen.",
]

RECIPE_STATES = [
  ("no photo", "Photo block absent; the title stays at 32 px and the fit block moves up. Nothing reads as missing &mdash; no grey placeholder illustration."),
  ("loading", "Everything above cook notes is local and instant. Notes reserve 3 rows with one 2 px line; if they take over 2 s the section collapses."),
  ("offline", "Cook notes hidden. Fit, swaps, steps and macros all render from device data."),
  ("missing 3+", "Primary dock button becomes &ldquo;Cook with 3 swaps&rdquo;; a secondary row above the dock offers &ldquo;Add 3 to shopping list&rdquo;. Cooking is never blocked."),
  ("short line", "A short row (state: short) shows the missing amount in the quantity column, e.g. &ldquo;need 100 g&rdquo;, with the square hollow in accent &mdash; the same encoding as the meter gap."),
  ("unknown", "Quantity unknown: dashed square, quantity column reads &ldquo;check&rdquo;, row says &ldquo;Confirm in Kitchen&rdquo;."),
  ("adapt", "Rescale for one eater: quantities change predictably; a step time changes only under a reviewed rule, and the step says so (&ldquo;one breast, so 6 min not 8&rdquo;)."),
  ("popover", "The swap popover grows from its row (origin-aware), never from screen centre."),
  ("doneness", "The cook step carries the thermometer test, not colour: &ldquo;74 &deg;C in the thickest piece&rdquo; (USDA FSIS). A camera look can describe browning; it never gives a safety verdict."),
]

RECIPE_MOTION = [
  ("enter", "Five blocks rise on snap (220 ms), 40 ms apart for the first three; the document below appears without stagger."),
  ("expand", "&ldquo;Show all 8&rdquo; reveals steps with the move token (340 ms) via a clipped container &mdash; heights animate through transform."),
  ("reduced", "Reveals become 150 ms fades; the popover crossfades in place."),
]

def recipe_body():
    return '''  <div class="screen"><div class="scroll dn" style="padding-bottom:170px">
    <div class="nav in" style="--i:0"><a href="#"><svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 2 4 7l5 5"/></svg>Tonight</a><a href="#">Share</a></div>
    <h2 class="title in" style="--i:0">Ginger chicken udon noodles</h2>
    <p class="mono sec c2 in" style="--i:1">25 min &middot; 2 servings &middot; 520 kcal</p>
    <div class="photo in" style="--i:1;margin-top:16px"><span>photo: overhead, daylight, 3:2</span></div>

    <div class="fitblock in" style="--i:2">
      <div>
        ''' + fit(9, 10) + '''
        <p class="sec" style="margin-top:6px">Fit to your kitchen</p>
      </div>
      <div style="text-align:right"><span class="q mono">9 of 10</span><br><span class="cap c2">1 swap</span></div>
    </div>

    <section class="sect in" style="--i:2">
      <h3>Ingredients <span class="stepper"><b>&minus;</b><span>2 servings</span><b>+</b></span></h3>
      <div class="row"><i class="sq have"></i><span class="n">Chicken thighs, skinless</span><span class="q">300 g</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Udon noodles</span><span class="q">300 g</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Ginger, grated</span><span class="q">25 g</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Spring onions</span><span class="q">4</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Pak choi</span><span class="q">2 heads</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Red chilli</span><span class="q">1</span></div>
      <div class="row"><i class="sq miss"></i><span class="n">Lime<span class="swap"><b>Swap</b><span>Lemon, you have 2 &middot; a little sharper, less floral</span></span><span class="swapnote">All eaters' allergens rechecked &mdash; none affected.</span></span><span class="q">1</span></div>
      <div class="row"><i class="sq ass"></i><span class="n">Soy sauce <span class="cap c2">assumed</span></span><span class="q">2 tbsp</span></div>
      <div class="row"><i class="sq ass"></i><span class="n">Sesame oil <span class="cap c2">assumed</span></span><span class="q">1 tbsp</span></div>
      <div class="row"><i class="sq ass"></i><span class="n">Honey <span class="cap c2">assumed</span></span><span class="q">1 tsp</span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Why it fits you <a href="#">Your taste</a></h3>
      <div class="row"><span class="n sec">Noodles: you've cooked 4 this month, rated 2 of them 5.</span><span class="q mono">4 cooks</span></div>
      <div class="row"><span class="n sec">Under 30 minutes, like 11 of your last 14.</span><span class="q mono">11 of 14</span></div>
      <div class="row"><span class="n sec">No coriander. You take it out every time.</span><span class="q mono">5 of 5</span></div>
    </section>

    <section class="sect steps in" style="--i:2">
      <h3>Steps <span class="q mono">8 &middot; 2 timers</span></h3>
      <div class="row"><span class="num">1</span><span class="n">Slice the chicken into 2 cm strips. Grate the ginger, slice the chilli and spring onions, halve the pak choi.</span></div>
      <div class="row"><span class="num">2</span><span class="n">Mix soy, honey, half the ginger and 3 tbsp water in a cup.</span></div>
      <div class="row"><span class="num">3</span><span class="n">Heat the oil in a wok until it just smokes. Fry the chicken 4 minutes without moving it, then 2 more, tossing. <span class="mono cap c2">timer 4:00, 2:00</span></span></div>
      <div class="row"><span class="num c3">4</span><span class="n c2">Show all 8</span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Per serving</h3>
      <div class="nut">
        <div><b>520</b><small>kcal</small></div>
        <div><b>38 g</b><small>protein</small><div class="bar"><i style="width:76%"></i></div></div>
        <div><b>54 g</b><small>carbs</small><div class="bar"><i style="width:54%"></i></div></div>
        <div><b>14 g</b><small>fat</small><div class="bar"><i style="width:28%"></i></div></div>
      </div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>From <span class="mono">212</span> cooks</h3>
      <div class="row"><span class="n sec">Swapped lime for lemon</span><span class="q mono">31%</span></div>
      <div class="row"><span class="n sec">&ldquo;Add the ginger late or it burns.&rdquo;</span><span class="q mono">41</span></div>
      <div class="row"><span class="n sec">&ldquo;Double the pak choi.&rdquo;</span><span class="q mono">18</span></div>
    </section>
  </div></div>

  <div class="dock">
    <button class="btn ghost" style="flex:1">Just the steps</button>
    <button class="btn primary" style="flex:1">Cook with LeChef</button>
  </div>
'''

def build_recipe(write, page, phone):
    n = note("Recipe", RECIPE_NOTE, RECIPE_STATES, RECIPE_MOTION)
    for theme in ("light", "dark"):
        html = page(f"Recipe ({theme})", theme, phone(recipe_body(), theme), n, RECIPE_CSS)
        write(f"recipe{'-dark' if theme == 'dark' else ''}.html", html)

# ---------------------------------------------------------------- cook mode
COOK_CSS = """
.screen.cook{padding:54px 24px 0;display:flex;flex-direction:column}
.top{display:flex;justify-content:space-between;align-items:center;height:44px}
.top .x{width:44px;height:44px;margin-right:-10px;display:grid;place-items:center;color:var(--ink2)}
.prog{display:flex;gap:4px;margin-top:10px}
.prog i{flex:1;height:3px;border-radius:2px;background:var(--rule2)}
.prog i.d{background:var(--ink)}
.prog i.c{background:var(--acc)}
.stepno{margin-top:26px;display:flex;align-items:baseline;gap:10px}
.stepno b{font-family:var(--mono);font-size:13px;font-weight:500;color:var(--acc)}
.step{font-size:26px;line-height:32px;font-weight:600;letter-spacing:-.01em;margin-top:8px}
.step em{font-style:normal;background:var(--accsoft);color:var(--accink);padding:0 4px;border-radius:4px;font-family:var(--mono);font-size:24px;font-weight:500;white-space:nowrap}
.timers{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:28px}
.tile{position:relative;border-radius:14px;background:var(--surface);box-shadow:inset 0 0 0 .5px var(--rule);padding:14px 16px;min-height:112px;display:flex;flex-direction:column;justify-content:space-between;transition:transform 120ms var(--out)}
.tile:active{transform:scale(.97)}
.tile .t{display:flex;justify-content:space-between;align-items:center}
.tile .d{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:44px;line-height:44px;font-weight:500;letter-spacing:-.02em;color:var(--acc)}
.tile.add{justify-content:center;align-items:center;color:var(--ink2);box-shadow:inset 0 0 0 1px var(--rule2);background:transparent;gap:6px}
.ring{width:22px;height:22px;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:2.5}
.ring .bg{stroke:var(--rule2)}
.ring .fg{stroke:var(--acc);stroke-dasharray:56.5;stroke-dashoffset:0;animation:drain 102s linear forwards}
@keyframes drain{to{stroke-dashoffset:56.5}}
.chef{margin-top:28px;padding-top:16px;border-top:1px solid var(--rule)}
.chef .label{color:var(--ink2);margin-bottom:6px}
.chef p{font-size:17px;line-height:24px}
.chef .acts{display:flex;gap:8px;margin-top:12px}
.chef .acts .btn{height:40px;width:auto;padding:0 18px;border-radius:10px;box-shadow:inset 0 0 0 1px var(--rule2);font-size:15px}
.spacer{flex:1}
.voice{display:flex;align-items:center;gap:12px;padding:12px 0}
.bars{display:flex;gap:3px;align-items:center;height:22px;width:34px}
.bars i{width:4px;border-radius:2px;background:var(--acc);height:6px;animation:amp 900ms ease-in-out infinite alternate}
.bars i:nth-child(2){animation-delay:120ms}.bars i:nth-child(3){animation-delay:240ms}.bars i:nth-child(4){animation-delay:360ms}.bars i:nth-child(5){animation-delay:60ms}
@keyframes amp{from{height:5px}to{height:20px}}
.bars.static i{animation:none;height:8px;background:var(--ink3)}
.voice .hint{color:var(--ink2);font-size:13px;line-height:16px}
.voice .hint b{color:var(--ink);font-weight:500}
.next{height:64px;border-radius:16px;background:var(--btnfill);color:var(--onbtn);font-size:17px;display:flex;align-items:center;justify-content:space-between;padding:0 20px;font-weight:600;transition:transform 120ms var(--out);border:0;width:100%;font-family:inherit;cursor:pointer}
.next:active{transform:scale(.97)}
.next span{font-weight:400;color:var(--ink2);font-size:15px;text-align:left;flex:1;margin-left:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.back{display:block;text-align:center;color:var(--ink2);font-size:15px;line-height:20px;padding:12px 0 4px}
.bottom{padding-bottom:40px}
@media (prefers-reduced-motion:reduce){.bars i{animation:none!important}.ring .fg{animation:none!important}}
"""

COOK_NOTE = [
  "Cook mode is its own palette &mdash; the hybrid's &ldquo;twilight hob&rdquo;: P's warm charcoal (#1E1C17, the dark value of his deep-olive token, minus the olive) with cream ink and the light terracotta. It ignores the system setting, exactly as F specifies; the switch from paper to hob is the moment you commit.",
  "Deciding density: 24 side, 32 between blocks. The step is 26/600, the largest body text in the app; quantities inside the step render in mono inside accent-soft. Targets are 64 pt because hands are wet (Fitts's law), including the segmented Next.",
  "Timer tiles are the one card type: warm-charcoal surface, label in caption, digits mono 44&ndash;56 in the accent, and a thin ring that depletes linearly &mdash; a ring that eases is lying about time. Tap pauses; long-press removes.",
  "LeChef's line sits under a hairline with its word mark in the section-label style &mdash; no sparkle glyph, no avatar. Its doneness copy is the checkable thermometer test (74 &deg;C, USDA FSIS), never colour or time alone. A camera look describes browning and says what it cannot assess.",
  "The voice indicator is driven by real amplitude; muted or offline it is a static shape, not a fake pulse. Voice is opt-in per cook: &ldquo;Just the steps&rdquo; is the default entrance from the recipe dock.",
]

COOK_STATES = [
  ("offline", "One line under the header: &ldquo;LeChef is offline. Steps and timers still work.&rdquo; Voice falls back to on-device recognition for the five words; the bars go static."),
  ("timer done", "Ring full, digits read 0:00, rigid haptic, tile lifts on the settle token; the step gains the check line &ldquo;Rice done &mdash; stir the sauce in&rdquo;. A timer that fires is information, so it still animates under reduced motion."),
  ("muted", "Mic off: the indicator is five static stubs and the hint reads &ldquo;Voice off. Touch controls below&rdquo;. Never a fake pulse."),
  ("voice off", "Entered with &ldquo;Just the steps&rdquo;: the voice row is replaced by a one-line &ldquo;Voice off &mdash; Just the steps&rdquo; with a quiet Turn on."),
  ("persisted", "Kill the app at step 4; reopen to step 4 with the timer still counting. Step state and timer deadlines live on device."),
  ("adapt", "Rescale at cook time: the step announces the changed step (&ldquo;one breast, so 6 min not 8&rdquo;) and timers follow the reviewed rule."),
  ("complete", "The end of the cook is quiet: dish name in the serif, &ldquo;Cooked&rdquo; with the rating and one line, the 520 kcal line, Save. No confetti, no counting-up numbers except the single kcal settle."),
]

COOK_MOTION = [
  ("next", "Step change by voice or Next: content crossfades under a stable frame on snap (220 ms); the segment bar fills with it."),
  ("press", "Next is 64 pt and scales 0.97 over 120 ms; tiles too."),
  ("timer", "The ring drains linearly for the full duration &mdash; never eased."),
  ("reduced", "Crossfades become 150 ms fades; the ring still moves (it is information); press scale stays."),
]

def cook_body():
    return '''  <div class="screen cook">
    <div class="top in" style="--i:0">
      <div><div class="label">Ginger chicken udon noodles</div><div class="cap c2 mono">Step 4 of 8 &middot; 11 min in</div></div>
      <a class="x" href="#" aria-label="Leave cook"><svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 3l12 12M15 3 3 15"/></svg></a>
    </div>
    <div class="prog in" style="--i:0" aria-hidden="true"><i class="d"></i><i class="d"></i><i class="d"></i><i class="c"></i><i></i><i></i><i></i><i></i></div>

    <div class="stepno in" style="--i:1"><b>4</b><span class="cap c2">Noodles in</span></div>
    <p class="step in" style="--i:1">Add the noodles and <em>3 tbsp</em> water. Toss for <em>2 min</em> until the sauce coats everything.</p>

    <div class="timers">
      <div class="tile in" style="--i:2">
        <div class="t"><span class="cap c2">Noodles</span><svg class="ring" viewBox="0 0 22 22"><circle class="bg" cx="11" cy="11" r="9"/><circle class="fg" cx="11" cy="11" r="9"/></svg></div>
        <div class="d">1:42</div>
      </div>
      <div class="tile add in" style="--i:2"><svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 4v12M4 10h12"/></svg><span class="sec">Timer</span></div>
    </div>

    <div class="chef in" style="--i:2">
      <div class="label">LeChef</div>
      <p>Check the thickest piece of chicken: <span style="white-space:nowrap">74 &deg;C</span> in the middle. Want a 2 min timer to check again?</p>
      <div class="acts"><button class="btn">Show it</button><button class="btn">No</button></div>
    </div>

    <div class="spacer"></div>

    <div class="bottom in" style="--i:2">
      <div class="voice">
        <div class="bars" aria-label="Listening"><i></i><i></i><i></i><i></i><i></i></div>
        <div class="hint"><b>Listening.</b> Say next, back, repeat, show, or timer 3 minutes.</div>
      </div>
      <button class="next">Next<span>Sauce goes in after this</span><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 2l6 6-6 6"/></svg></button>
      <a class="back" href="#">Back a step</a>
    </div>
  </div>
'''

def build_cook(write, page, phone):
    n = note("Cook with LeChef", COOK_NOTE, COOK_STATES, COOK_MOTION)
    html = page("Cook with LeChef (cook palette)", "cook", phone(cook_body(), "cook"), n, COOK_CSS)
    write("cook-lechef.html", html)

def build(write, page, phone):
    build_recipe(write, page, phone)
    build_cook(write, page, phone)

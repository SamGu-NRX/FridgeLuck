/* Direction P screen: recipe detail. */
'use strict';

const { fit } = require('./screens-tonight');

function recipe() {
  const { tabbarF } = require('./shell');
  const ing = [
    ['Udon noodles', '2 nests', 'have', ''], ['Chicken thighs', '500 g', 'have', ''],
    ['Ginger', '20 g', 'have', ''], ['Spring onions', '6', 'have', ''],
    ['Soy sauce', '3 tbsp', 'assumed', ''], ['Sesame oil', '2 tbsp', 'assumed', ''],
    ['Honey', '1 tbsp', 'have', ''], ['Garlic', '2 cloves', 'have', ''],
    ['Lemons', '1', 'swap', 'or lime — you have 2 lemons'], ['Spinach', '100 g', 'have', ''],
  ];
  const stateSq = { have: '<span class="sq have"></span>', assumed: '<span class="sq have"></span>', swap: '<span class="sq missing"></span>' };
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <a class="backic" href="#" aria-label="Back"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 5-7 7 7 7"/></svg></a>
    <span class="chip">Serves <span class="mono">2</span> · <span class="mono">25 min</span></span>
  </header>
  <h1 class="d2 rt in" style="--i:1">Ginger chicken udon noodles</h1>
  <p class="mono m2 c2 in" style="--i:2">520 kcal per serving · tested</p>

  <section class="sect in" style="--i:2">
    <div class="card fitblock">
      <div class="fitrow">${fit(9)}<span class="mono m1">9 of 10 · 1 swap</span></div>
      <p class="cap c2">Over a complete bill for this revision, 2 servings, lemon swap accepted.</p>
    </div>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Ingredients · per-line states</div>
    <div class="rows">
      ${ing.map(([n, q, st, noteTxt]) => `<div class="row"><span class="n t2">${n}${noteTxt ? `<br><span class="cap c2">${noteTxt}</span>` : ''}</span>${st === 'assumed' ? '<span class="chip">assumed</span>' : stateSq[st]}<span class="mono m2">${q}</span></div>`).join('')}
    </div>
  </section>

  <section class="sect in" style="--i:4">
    <div class="label">Swap</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Lime → lemon</span><br><span class="cap c2">A little sharper — add it at the end, off the heat</span></span><span class="mono m3 c2">allergens: none</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:5">
    <div class="label">Why it fits you</div>
    <div class="rows">
      <div class="row"><span class="n t2">You’ve cooked noodles <span class="mono m3">4 times</span> this month</span><span class="mono m3 c2">rated 2× 5</span></div>
      <div class="row"><span class="n t2">Under <span class="mono m3">30 min</span></span><span class="mono m3 c2">11 of 14 cooks</span></div>
      <div class="row"><span class="n t2">Uses the spinach</span><span class="mono m3 c2">2 days left</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:6">
    <div class="label">Steps</div>
    <div class="rows steps">
      <div class="row"><span class="mono m2 stepno">1</span><span class="n t2">Soak the udon in just-boiled water.</span></div>
      <div class="row"><span class="mono m2 stepno">2</span><span class="n t2">Sear the chicken <span class="mono">6 min</span>, then add ginger and garlic.<br><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>timer <span class="mono">6 min</span></span></span></div>
      <div class="row"><span class="mono m2 stepno">3</span><span class="n t2">Check the thickest piece: <b class="mono">74 °C</b> in the middle — thermometer, not colour.<br><span class="cap c2">Source: USDA FSIS safe minimum internal temperature</span></span></div>
      <div class="row"><span class="mono m2 stepno">4</span><span class="n t2">Add noodles and <span class="mono">3 tbsp</span> water; toss <span class="mono">2 min</span>.</span></div>
      <div class="row"><span class="mono m2 stepno">5</span><span class="n t2">Off the heat: soy, honey, lemon, spinach.</span></div>
    </div>
  </section>
</div></div>

<div class="dock in" style="--i:7">
  <span class="n"><span class="t2">Cook with LeChef</span><br><span class="cap c2">Steps, timers, hands-free</span></span>
  <button class="btn small primary">Cook</button>
</div>
${tabbarF('tonight')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 4px}
.backic{width:44px;height:44px;display:grid;place-items:center;margin-left:-10px;color:var(--ink)}
.rt{margin:2px}
.fitblock{padding:14px 16px}
.fitblock .fitrow{display:flex;justify-content:space-between;align-items:center}
.fitblock .cap{margin-top:8px}
.stepno{width:24px;flex:none;color:var(--ink2);font-weight:600}
.rows.steps .row{align-items:flex-start;padding-top:12px;padding-bottom:12px}
`;
  const note = `<h1>Recipe detail</h1>
<p>The recipe is a document, not a stack of cards. The fit block restates the promise at the top: meter, mono count, and the scope of the claim (bill, revision, servings, accepted swaps). Every ingredient line shows its own state square, so “9 of 10” is auditable line by line; assumed staples are labelled, and the swap line is a real line, not a footnote.</p>
<p>Swaps describe the difference (“a little sharper — add it at the end”) and never promise “no change”. The allergen check is visible on the row.</p>
<p>Steps are split at timer and action boundaries; the safety check states a thermometer temperature with its source (USDA FSIS), never colour or time alone. Steps are the only numbered sequence on the screen.</p>
<h2>States</h2>
<dl>
<dt>adapt</dt><dd>With one thigh instead of two, amounts rescale and step 2 becomes “one thigh, so 6 min not 8” — a time change only when a reviewed rule supports it; otherwise the step says to check.</dd>
<dt>swap recheck</dt><dd>Every substitution rechecks all eaters’ allergens, including compound ones (soy sauce → wheat). The row shows the result.</dd>
<dt>no natural timer</dt><dd>Step 1 gets no fake timer; a step without a real duration shows none.</dd>
<dt>stale pantry</dt><dd>If a line’s evidence went stale since the fit was computed, the fit block reads “7 recorded · check eggs and oil” instead of n of m.</dd>
<dt>loading</dt><dd>Fit and lines render from the local bill; nothing here waits on the network.</dd>
<dt>reduced motion</dt><dd>Dock enters by 150 ms fade; no bounce on scroll anchors.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>enter</dt><dd>Sections rise 200 ms, 36 ms apart, six blocks max.</dd>
<dt>dock</dt><dd>The cook dock floats on a surface card with the app’s only scroll shadow; press 0.97 / 120 ms.</dd>
<dt>swap pick</dt><dd>Swap row press crossfades the ingredient line in 150 ms.</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { recipe };

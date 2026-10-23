/* Direction P screen: tonight (light + dark). */
'use strict';

const fit = (n, total = 10, label) =>
  `<span class="fit" aria-label="${label || `${n} of ${total} ingredients on hand`}">${'<i></i>'.repeat(n)}${'<i class="o"></i>'.repeat(total - n)}</span>`;

function plate(h, cls = '') {
  return `<div class="plate ${cls}" style="height:${h}px" aria-label="Illustration: plated dish">
  <div class="pl"></div>
  <span class="b" style="left:24%;top:30%;width:26%;height:20%;background:var(--oat);border-radius:50%"></span>
  <span class="b" style="left:30%;top:44%;width:20%;height:16%;background:var(--oat);border-radius:50%"></span>
  <span class="b" style="left:52%;top:36%;width:17%;height:15%;background:var(--accent-lt)"></span>
  <span class="b" style="left:57%;top:50%;width:13%;height:12%;background:var(--accent-lt)"></span>
  <span class="b" style="left:38%;top:56%;width:9%;height:8%;background:var(--sage)"></span>
  <span class="b" style="left:47%;top:60%;width:6%;height:6%;background:var(--sage)"></span>
  <span class="b" style="left:64%;top:26%;width:12%;height:11%;background:var(--rose)"></span>
</div>`;
}

function tonight() {
  const { tabbarF } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <h1 class="d2">Tonight</h1>
    <span class="chip sag"><span class="dot" style="background:var(--sage)"></span>Scanned&nbsp;<span class="mono">5:12 pm</span></span>
  </header>

  <section class="card hero">
    <span class="chip acc in" style="--i:1"><span class="dot" style="background:var(--accent)"></span>From your fridge</span>
    <h2 class="d1 in" style="--i:2">Ginger chicken udon noodles</h2>
    <p class="mono m2 c2 in" style="--i:3">25 min · 2 servings · 520 kcal</p>
    <div class="in" style="--i:3">${plate(150)}</div>
    <div class="fitrow in" style="--i:4">${fit(9)}<span class="mono m1">9 of 10 · 1 swap</span></div>
    <p class="t1 swapline in" style="--i:5">Everything except lime — swap in a lemon, you have two.</p>
    <p class="t2 c2 why in" style="--i:6">Why: you've cooked noodles <span class="mono">4 times</span> this month and rated two of them <span class="mono">5</span>. Under <span class="mono">30 min</span>, like <span class="mono">11</span> of your last <span class="mono">14</span> cooks.</p>
    <div class="btng in" style="--i:7">
      <button class="btn primary">Cook this</button>
      <button class="btn ghost">Something else</button>
    </div>
  </section>

  <section class="sect in" style="--i:7">
    <div class="label">Use soon <a href="#">Kitchen</a></div>
    <div class="rows">
      <div class="row"><span class="n t2">Spinach</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>2 days</span></div>
      <div class="row"><span class="n t2">Greek yogurt <span class="mono m3 c2">500 g</span></span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>tomorrow</span></div>
      <div class="row"><span class="n t2">Lemons <span class="mono m3 c2">2</span></span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>today</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:8">
    <div class="label">Also possible</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Creamy pesto &amp; kale pasta</span><br><span class="cap c2">Uses the spinach</span></span><span class="mono m2 c2">15 min</span><span class="mono m2">10 of 10</span></div>
      <div class="row"><span class="n"><span class="t2">Butter bean curry</span><br><span class="cap c2">You cook this about every <span class="mono">10</span> days</span></span><span class="mono m2 c2">35 min</span><span class="mono m2">10 of 10</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:9">
    <div class="label">Your table <a href="#">Flat 4B</a></div>
    <div class="rows">
      <div class="row"><span class="n t2">Maya cooked butter bean curry last night. <span class="c2">“Add lemon at the end.”</span></span><span class="mono m2">10 of 10</span></div>
    </div>
  </section>
</div></div>

<div class="dock in" style="--i:10" role="region" aria-label="Cook in progress">
  <span class="mono m2" style="color:var(--accent-ink)">1:42</span>
  <span class="n"><span class="t2">Step 4 of 8 · Noodles in</span><br><span class="cap c2">Udon · started 6:18 pm</span></span>
  <button class="btn small primary">Resume</button>
</div>
${tabbarF('tonight')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 14px}
.hero{padding:16px 16px 18px;margin-top:4px}
.hero .d1{margin:10px 0 2px}
.fitrow{display:flex;justify-content:space-between;align-items:center;margin-top:14px}
.swapline{margin-top:10px}
.why{margin-top:8px}
.btng{display:grid;gap:8px;margin-top:18px}
`;
  const note = `<h1>Tonight</h1>
<p>One pick, its fit, its reason, and the button — the 6:40 pm decision before the thumb moves. The hero is a single surface card on warm linen; everything else is smaller, denser and quieter so the pick owns the screen. Serif display carries the title, rounded carries the UI, tabular mono carries every number. Fit is “9 of 10 · 1 swap”, never a percentage.</p>
<p>Why is written as evidence with counts, never as flattery. The swap is named with its proof (“you have two”). A slim resume dock returns you to a live cook; it displaces nothing.</p>
<h2>States</h2>
<dl>
<dt>unknown kitchen</dt><dd>No scan yet or camera refused: hero becomes “Scan a shelf and I’ll pick tonight’s dinner.” with two first-class actions — <code>Scan a shelf</code> and <code>Add food by hand</code> (manual entry is never a dead end). A sample pick sits below, labelled “Example”.</dd>
<dt>sparse kitchen</dt><dd>3–5 items: the pick stays honest and the card adds a “You’d need” list with real amounts (“300 g chicken thighs, 1 lime”), then “Scan after shopping and this gets better.” No fake alternatives padded to fill.</dd>
<dt>nothing feasible</dt><dd>Best fit under 6 of 10: the pick is replaced by “Nothing cooks with what’s here.” and two routes — tonight’s shopping list, or a saved pick. The button never says “Cook with 2 swaps” when the fit is a fiction.</dd>
<dt>repeated rejection</dt><dd>Third tap on “Something else” opens a constraint sheet: <code>Quicker</code> · <code>Different main</code> · <code>Less effort</code> · <code>Pick from a list</code>. Rejections never become dislikes, there is no clock cutoff.</dd>
<dt>empty / loading</dt><dd>Local fit renders instantly; the Why and table lines arrive late into reserved height behind one 2 px indeterminate line. No shimmer.</dd>
<dt>error</dt><dd>Recommendation service down: last pick stays with “As of 6:10 pm” in the eyebrow chip. Use-soon, alternatives and fit are on-device and always render.</dd>
<dt>reduced motion</dt><dd>Entrance is a 150 ms fade with no stagger; press scale stays at 120 ms; the resume timer digits stay live (information, not decoration).</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>enter</dt><dd>Ten blocks rise 6 px over 200 ms, 36 ms apart, last one settled by 380 ms.</dd>
<dt>press</dt><dd>Buttons and rows scale to 0.97 in 120 ms (snap).</dd>
<dt>swap pick</dt><dd>“Something else” crossfades the hero in 150 ms under a stable frame (fade).</dd>
<dt>resume</dt><dd>Resume dock springs in at 320 ms after a cook is left mid-way (move).</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { tonight, plate, fit };

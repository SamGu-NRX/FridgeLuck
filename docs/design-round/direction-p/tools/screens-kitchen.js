/* Direction P screens: kitchen, scan-review. */
'use strict';

function kitchen() {
  const { tabbarF } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <h1 class="d2">Kitchen</h1>
    <span class="chip sag"><span class="dot" style="background:var(--sage)"></span>Scanned&nbsp;<span class="mono">5:12 pm</span></span>
  </header>

  <div class="field in" style="--i:1"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><span>Search your kitchen</span></div>
  <div class="chips in" style="--i:2">
    <span class="chip" style="background:var(--chip-acc)">All <span class="mono m3">14</span></span>
    <span class="chip">Fridge <span class="mono m3">9</span></span>
    <span class="chip">Freezer <span class="mono m3">2</span></span>
    <span class="chip">Pantry <span class="mono m3">3</span></span>
  </div>

  <section class="sect in" style="--i:2">
    <div class="legend cap c2"><span class="sq have"></span>have<span class="sq missing"></span>missing<span class="sq unconf"></span>unconfirmed</div>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Use soon</div>
    <div class="rows">
      <div class="row"><span class="sq have"></span><span class="n t2">Spinach</span><span class="mono m3 c2">100 g</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>2 days</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Greek yogurt</span><span class="mono m3 c2">500 g</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>tomorrow</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Lemons</span><span class="mono m3 c2">2</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>today</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:4">
    <div class="label">Needs a look</div>
    <div class="rows">
      <div class="row"><span class="sq unconf"></span><span class="n"><span class="t2">Coriander</span><br><span class="cap c2">Needs reconfirming · last seen <span class="mono">6</span> days ago</span></span><span class="mono m3 c2">1 bunch?</span></div>
      <div class="row"><span class="sq unconf"></span><span class="n"><span class="t2">Honey</span><br><span class="cap c2">Needs reconfirming · jar moved to pantry</span></span><span class="mono m3 c2">?</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:5">
    <div class="label">Fridge</div>
    <div class="rows">
      <div class="row"><span class="sq have"></span><span class="n t2">Chicken thighs</span><span class="mono m3 c2">scanned 5:12 pm</span><span class="mono m2">500 g</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Udon noodles</span><span class="mono m3 c2">scanned 5:12 pm</span><span class="mono m2">2 nests</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Eggs</span><span class="mono m3 c2">receipt · Sat</span><span class="mono m2">6</span></div>
      <div class="row"><span class="sq missing"></span><span class="n"><span class="t2">Butter beans</span><br><span class="cap c2">On the shopping list</span></span><span class="mono m2 c2">0</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:6">
    <div class="label">Assumed staples <a href="#">Why?</a></div>
    <div class="rows">
      <div class="row"><span class="sq have"></span><span class="n t2">Soy sauce</span><span class="chip">assumed</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Rice</span><span class="chip">assumed</span><span class="mono m3 c2">400 g</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Olive oil</span><span class="chip">assumed</span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">Assumed staples count as present. Open a row to unassume it and record the real amount.</p>
  </section>

  <div style="display:grid;gap:8px;margin-top:24px" class="in">
    <button class="btn primary">Scan a shelf</button>
    <button class="btn ghost">Add by hand</button>
  </div>
</div></div>
${tabbarF('kitchen')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 14px}
.chips{display:flex;gap:8px;margin-top:12px;overflow-x:auto;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
.legend{display:flex;align-items:center;gap:7px;padding:2px 4px}
.legend .sq{margin:0}
`;
  const note = `<h1>Kitchen</h1>
<p>Answers “what do I actually have?”. Dense 44 pt rows with state squares — shape before colour: filled = have, hollow = missing, dashed = unconfirmed. A scan of one shelf refreshes only what it saw; every row carries its last confirmation and source (scanned time or receipt day), which is what makes “needs reconfirming” mean something.</p>
<p>Assumed staples are honest: they count as present for fit, say so, and can be unassumed.</p>
<h2>States</h2>
<dl>
<dt>empty</dt><dd>No scan, no entries: “Your kitchen is empty — scan a shelf or add food by hand.” Both actions first-class, equal size.</dd>
<dt>camera refused</dt><dd>The scan prompt never blocks the page; manual entry stays one tap away. Copy: “Camera off. Add by hand any time.”</dd>
<dt>stale evidence</dt><dd>A row whose last confirmation is older than the profile’s freshness rule moves itself into Needs a look with the age shown. It never silently keeps counting toward fit.</dd>
<dt>scan pending</dt><dd>While a shelf is processing, the affected section shows one 2 px indeterminate line; existing rows keep working.</dd>
<dt>quantity unknown</dt><dd>Recognition confidence is not quantity confidence: the row shows “?” in mono and stays unconfirmed until a real amount is entered.</dd>
<dt>reduced motion</dt><dd>Row press scale stays; section entries fade 150 ms without stagger.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>rows</dt><dd>Rows appear with the page entrance only; scrolling is static.</dd>
<dt>press</dt><dd>Rows and chips scale 0.985 / 0.97 in 120 ms.</dd>
<dt>section switch</dt><dd>Chip segment crossfades 150 ms; no layout animation.</dd>
</dl>`;
  return { html, css, note };
}

function scanReview() {
  const { tabbarF } = require('./shell');
  const sure = [
    ['Chicken thighs', '500 g'], ['Udon noodles', '2 nests'], ['Ginger', '1 knob'],
    ['Spring onions', '6'], ['Soy sauce', '1 bottle'], ['Garlic', '1 bulb'],
    ['Eggs', '6'], ['Greek yogurt', '500 g'], ['Honey', '½ jar'],
    ['Spinach', '100 g'], ['Sesame oil', '1 bottle'],
  ];
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <div><h1 class="d2">Scan review</h1><p class="cap c2">Shelf · <span class="mono">5:12 pm</span> · <span class="mono">14</span> things seen</p></div>
  </header>

  <section class="in" style="--i:1">
    <div class="label" style="padding:0 4px 8px">3 need you</div>
    <div class="rows">
      <div class="row q"><span class="sq unconf"></span><span class="n"><span class="t2">Coriander or parsley?</span><br><span class="cap c2">Leaves look alike at this angle</span></span></div>
      <div class="ans"><button class="btn small ghost">Coriander</button><button class="btn small ghost">Parsley</button><button class="btn small ghost">Neither</button></div>
      <div class="row q"><span class="sq unconf"></span><span class="n"><span class="t2">Still 2 lemons?</span><br><span class="cap c2">The last scan saw 2 · scans only observe</span></span></div>
      <div class="ans"><button class="btn small ghost">Yes, 2</button><button class="btn small ghost">Now 1</button><button class="btn small ghost">None</button></div>
      <div class="row q"><span class="sq unconf"></span><span class="n"><span class="t2">How much rice is left?</span><br><span class="cap c2">Amount unknown stays unknown</span></span></div>
      <div class="ans"><button class="btn small ghost">400 g</button><button class="btn small ghost">Unknown</button></div>
    </div>
  </section>

  <section class="sect in" style="--i:2">
    <div class="label">11 sure — already in <a href="#">Undo all</a></div>
    <div class="rows">
      ${sure.map(([n, q]) => `<div class="row"><span class="sq have"></span><span class="n t2">${n}</span><span class="mono m3 c2">seen</span><span class="mono m2">${q}</span></div>`).join('')}
    </div>
  </section>
</div></div>

<div class="dock col in" style="--i:3">
  <button class="btn primary">Confirm 14 items</button>
  <p class="cap c2" style="text-align:center">Scans observe — nothing is added to stock until a receipt or a manual entry.</p>
</div>
${tabbarF('kitchen')}`;
  const css = `
.head{padding:6px 2px 14px}
.row.q{border-bottom:0;padding-bottom:8px}
.ans{display:flex;gap:8px;padding:0 14px 12px 36px;border-bottom:1px solid var(--rule);flex-wrap:wrap}
.rows .row:last-child{border-bottom:0}
.ans .btn{min-height:40px;font-size:var(--cap)}
.dock.col{flex-direction:column;gap:6px}
`;
  const note = `<h1>Scan review</h1>
<p>Miller’s law, kept: the three uncertain rows come first and alone — each is a question the camera could not answer, with tap-to-answer chips. The eleven sure rows follow as a skim list; they are already in, and the only action is undo.</p>
<p>“Still 2 lemons?” is the observe-versus-purchase reconciliation: a shelf scan confirms what it saw, and only a receipt, “New groceries”, or manual entry adds stock.</p>
<h2>States</h2>
<dl>
<dt>one scan, three objects</dt><dd>One camera run classifies shelf, receipt and plate; the header says which it saw (“Shelf”). A receipt run routes to the add-stock flow instead.</dd>
<dt>camera refused / failed</dt><dd>“Camera off. Add by hand any time.” — review opens on manual entry, never an error dead end.</dd>
<dt>recognition failed</dt><dd>“I saw 14 things and couldn’t name 3.” Retake and manual entry offered; nothing is guessed into the kitchen.</dd>
<dt>retry</dt><dd>Confirmations are idempotent — tapping Confirm twice leaves one observation each, shown as a toast “Kitchen unchanged”.</dd>
<dt>unknown amount</dt><dd>“Unknown” keeps the item with a “?” quantity; it never invents grams from the look of a bag.</dd>
<dt>reduced motion</dt><dd>Chips appear by fade; the confirm dock does not spring.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>enter</dt><dd>Blocks rise 200 ms, 36 ms apart; the 11 sure rows render as one block (no per-row stagger beyond six items).</dd>
<dt>tap chip</dt><dd>Chip fills with snap 200 ms; row collapses via 150 ms fade under a stable frame.</dd>
<dt>confirm</dt><dd>Dock button press 0.97/120 ms; success returns to Kitchen with a 150 ms crossfade.</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { kitchen, scanReview };

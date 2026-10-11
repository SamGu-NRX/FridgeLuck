/* Direction P screens: Shell S structure — Kitchen & Progress main tabs, central scan orb, Profile inside Progress. */
'use strict';

function shellSKitchen() {
  const { tabbarS } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <h1 class="d2">Kitchen</h1>
    <span class="chip sag"><span class="dot" style="background:var(--sage)"></span>Scanned&nbsp;<span class="mono">5:12 pm</span></span>
  </header>

  <section class="sect in" style="--i:1">
    <div class="legend cap c2"><span class="sq have"></span>have<span class="sq missing"></span>missing<span class="sq unconf"></span>unconfirmed</div>
  </section>

  <section class="sect in" style="--i:2">
    <div class="label">Use soon</div>
    <div class="rows">
      <div class="row"><span class="sq have"></span><span class="n t2">Spinach</span><span class="mono m3 c2">100 g</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>2 days</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Greek yogurt</span><span class="mono m3 c2">500 g</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>tomorrow</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Lemons</span><span class="mono m3 c2">2</span><span class="chip oat"><span class="dot" style="background:var(--oat-ink)"></span>today</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Needs a look</div>
    <div class="rows">
      <div class="row"><span class="sq unconf"></span><span class="n"><span class="t2">Coriander</span><br><span class="cap c2">Needs reconfirming · last seen <span class="mono">6</span> days ago</span></span><span class="mono m3 c2">?</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:4">
    <div class="label">Fridge</div>
    <div class="rows">
      <div class="row"><span class="sq have"></span><span class="n t2">Chicken thighs</span><span class="mono m3 c2">scanned 5:12 pm</span><span class="mono m2">500 g</span></div>
      <div class="row"><span class="sq have"></span><span class="n t2">Udon noodles</span><span class="mono m3 c2">scanned 5:12 pm</span><span class="mono m2">2 nests</span></div>
      <div class="row"><span class="sq missing"></span><span class="n"><span class="t2">Butter beans</span><br><span class="cap c2">On the shopping list</span></span><span class="mono m2 c2">0</span></div>
    </div>
  </section>
</div></div>
${tabbarS('kitchen')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 14px}
.legend{display:flex;align-items:center;gap:7px;padding:2px 4px}
.legend .sq{margin:0}
`;
  const note = `<h1>Shell S — Kitchen (main tab, central scan orb)</h1>
<p>Sam’s stage-2 structure rendered in this direction’s tokens: Kitchen and Progress are the only main tabs, the scan orb sits central and 74 pt, and Profile lives inside Progress, not on the bar. The scan orb is kept as a candidate here — it is the one navigational affordance from Shell S worth testing against the flat bar — while Shell F’s floating orb is gone entirely: the bar carries the same tab set without a floating element.</p>
<p>Content is the Kitchen screen’s density contract unchanged: 44 pt rows, shape-first state squares, evidence on every line.</p>
<h2>States</h2>
<dl>
<dt>orb press</dt><dd>Orb 0.95 / 120 ms and opens the camera; the tabs never move.</dd>
<dt>camera refused</dt><dd>Orb still opens a sheet that offers “Add by hand” first — the orb is never a dead end.</dd>
<dt>reduced motion</dt><dd>Tab switches crossfade 150 ms; no tab badge bounce.</dd>
</dl>`;
  return { html, css, note };
}

function shellSProgress() {
  const { tabbarS } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0"><h1 class="d2">Progress</h1></header>
  <p class="t2 c2 lede in" style="--i:0">What you cooked, and what it taught me.</p>

  <section class="sect in" style="--i:1">
    <div class="label">This week</div>
    <div class="rows">
      <div class="row"><span class="n t2">Suppers cooked</span><span class="mono m1">6</span></div>
      <div class="row"><span class="n t2">Foods saved from spoiling</span><span class="mono m1">4</span></div>
      <div class="row"><span class="n t2">Meals logged</span><span class="mono m1">9 of 14</span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">Counts, never percentages. The week ends on Sunday; nothing carries debt.</p>
  </section>

  <section class="sect in" style="--i:2">
    <div class="label">Recent cooks</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Ginger chicken udon · tonight</span><br><span class="cap c2">rated <span class="mono">4</span> · “add lemon at the end”</span></span><span class="mono m3 c2">25 min</span></div>
      <div class="row"><span class="n"><span class="t2">Butter bean curry · Tue</span><br><span class="cap c2">household favourite</span></span><span class="mono m3 c2">35 min</span></div>
      <div class="row"><span class="n t2">Creamy pesto pasta · Sun</span><span class="mono m3 c2">15 min</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Taste profile</div>
    <div class="rows">
      <div class="row"><span class="n t2">Coriander — out <span class="mono m3 c2">· 4 of 5 times</span></span><span class="mono m3">open →</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:4">
    <a class="row profilelink" href="#"><span class="n t2">Profile</span><span class="mono m3 c2">kitchen · privacy · household</span><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 5 7 7-7 7"/></svg></a>
  </section>
</div></div>
${tabbarS('progress')}`;
  const css = `
.head{padding:6px 2px 6px}
.lede{padding:0 2px 16px}
.profilelink{box-shadow:inset 0 0 0 .5px var(--rule);border-radius:16px;margin-top:0}
`;
  const note = `<h1>Shell S — Progress (main tab; Profile lives here)</h1>
<p>Progress is a record, not a leaderboard: the week as counts (suppers cooked, foods saved, meals logged “9 of 14”), recent cooks with their notes, and the taste-profile line with its evidence. Profile is a row inside Progress — the stage-2 decision — opening the pushed screen; it is not a fifth tab.</p>
<h2>States</h2>
<dl>
<dt>empty week</dt><dd>“No suppers yet this week — the first one is the hardest.” Rows appear as they happen; zeros are shown, not hidden.</dd>
<dt>unlogged meals</dt><dd>“9 of 14” states coverage honestly; logging is one tap on the row, never a nag.</dd>
<dt>reduced motion</dt><dd>Standard entrance fade only.</dd>
</dl>`;
  return { html, css, note };
}

function shellSProfile() {
  const { tabbarS } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <a class="backic" href="#" aria-label="Back to Progress"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 5-7 7 7 7"/></svg></a>
    <h1 class="d2">Profile</h1>
  </header>

  <section class="sect in" style="--i:1">
    <div class="label">Household</div>
    <div class="rows">
      <div class="row"><span class="n t2">Flat 4B</span><span class="mono m3 c2">3 people</span></div>
      <div class="row"><span class="n t2">Taste profile</span><span class="mono m3">open →</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:2">
    <div class="label">Privacy</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Taste data on this phone</span><br><span class="cap c2">Ranking runs on-device; nothing is shared without a preview you approve</span></span><span class="chip sag"><span class="dot" style="background:var(--sage)"></span>on</span></div>
      <div class="row"><span class="n t2">Notifications</span><span class="mono m3">open →</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Kitchen settings</div>
    <div class="rows">
      <div class="row"><span class="n t2">Assumed staples</span><span class="mono m3">edit →</span></div>
      <div class="row"><span class="n t2">Scan history</span><span class="mono m3">review →</span></div>
    </div>
  </section>
</div></div>
${tabbarS('progress')}`;
  const css = `
.head{display:flex;align-items:center;gap:8px;padding:6px 2px 8px}
.backic{width:44px;height:44px;display:grid;place-items:center;margin-left:-10px;color:var(--ink);flex:none}
`;
  const note = `<h1>Shell S — Profile (pushed inside Progress)</h1>
<p>Profile as a pushed screen with a back chevron, not a hidden tab: household, the privacy contract in one row (taste data on-device, sharing preview-gated), and kitchen settings. The bar still shows Progress active — you know where you are.</p>
<h2>States</h2>
<dl>
<dt>taste data off</dt><dd>Ranking falls back to recency with a one-line note in Tonight (“ranking is generic until taste data is back on”).</dd>
<dt>notifications off</dt><dd>Row shows the state; no red badge, no re-ask within the session.</dd>
<dt>reduced motion</dt><dd>Push transition disabled → instant swap with 150 ms fade.</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { shellSKitchen, shellSProgress, shellSProfile };

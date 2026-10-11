/* Direction P screens: table (sharing surface), candidates (quests, tour). */
'use strict';

function table() {
  const { tabbarF } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <h1 class="d2">Table · Flat 4B</h1>
    <span class="chip sag"><span class="dot" style="background:var(--sage)"></span>3 people</span>
  </header>

  <section class="sect in" style="--i:1">
    <div class="label">On the table <a href="#">Kitchen</a></div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Butter bean curry · Leo’s pick for Thursday</span><br><span class="cap c2">Your own fit · 10 of 10 · you have everything</span></span></div>
      <div class="row"><span class="n"><span class="t2">Ginger chicken udon · Maya, tonight</span><br><span class="cap c2">Your own fit · 9 of 10 · 1 swap</span></span></div>
    </div>
    <div class="btng in" style="--i:2"><button class="btn primary">Cook tonight</button></div>
    <p class="cap c2" style="margin:8px 4px 0">A cook card shows the viewer’s own fit and their own button — the table never asks you to cook someone else’s dinner.</p>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Share preview · what leaves your phone</div>
    <div class="card prev">
      <div class="prevrow"><span class="sq have"></span><span class="t2">Recipe — ginger chicken udon noodles</span></div>
      <div class="prevrow"><span class="sq have"></span><span class="t2">Servings — <span class="mono">2</span></span></div>
      <div class="prevrow"><span class="sq have"></span><span class="t2">Swaps — lemon for lime</span></div>
      <div class="prevrow"><span class="sq have"></span><span class="t2">Rating — <span class="mono">4</span> of <span class="mono">5</span></span></div>
      <div class="prevrow"><span class="sq have"></span><span class="t2">One-line note — <i>optional</i></span></div>
      <div class="prevrow no"><span class="sq missing"></span><span class="t2 c2">Never: pantry · health · taste profile</span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">The preview lists exactly what leaves the phone, before it leaves. Taste data stays on-device; the preview cannot be widened.</p>
  </section>

  <section class="sect in" style="--i:4">
    <div class="label">Invites <a href="#">manage</a></div>
    <div class="rows">
      <div class="row"><span class="n t2">Invite someone new</span><span class="mono m3"><a href="#">Create link</a></span></div>
      <div class="row"><span class="n"><span class="t2">Sam joined via your link</span><br><span class="cap c2">Links need the owner’s approval — one tap, both sides</span></span><span class="chip sag"><span class="dot" style="background:var(--sage)"></span>approved</span></div>
    </div>
  </section>

  <section class="sect in" style="--i:5">
    <div class="label">Challenge · cook-week <a href="#">set up</a></div>
    <div class="rows">
      <div class="row"><span class="n t2">Setup — suppers cooked, foods saved<br><span class="cap c2">Mon–Sun · counts, not streaks</span></span><span class="mono m3 c2">3 joined</span></div>
      <div class="row"><span class="n t2">Last week’s result</span><span class="mono m3 c2">Maya 8 · you 6 · Leo 5</span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">Challenges count real things — cooks made and food saved — and end. No app-open points, no flames.</p>
  </section>
</div></div>
${tabbarF('table')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 14px}
.btng{display:grid;margin-top:12px}
.prev{padding:6px 16px;border-radius:16px}
.prevrow{display:flex;align-items:center;gap:10px;min-height:40px;border-top:1px solid var(--rule);font-size:var(--t2);line-height:var(--t2l)}
.prevrow:first-child{border-top:0}
`;
  const note = `<h1>Table — the sharing surface</h1>
<p>Every cook card carries the viewer’s own fit and their own “Cook tonight” button; the table proposes, never assigns. The share preview is the contract made visible: recipe, servings, swaps, rating, optional one-line note — and an explicit never-row for pantry, health and taste profile. The preview cannot be widened; sharing more is a different flow that does not exist.</p>
<p>Invites work on owner-approved links, shown here as a row with its state. Challenges count real things — suppers cooked, foods saved — with results as plain counts.</p>
<h2>States</h2>
<dl>
<dt>invite pending</dt><dd>“Waiting for Maya to approve” — both sides approve; a pending link is revocable until used.</dd>
<dt>share from cook-complete</dt><dd>Arrives with “shared · just now” and exactly the previewed fields; the note arrives only if the cook wrote one.</dd>
<dt>member offline</dt><dd>Rows render from the last sync; new posts queue on-device with a “queued” mark until delivered.</dd>
<dt>challenge ended</dt><dd>Results freeze as counts for the week; nothing decays afterward.</dd>
<dt>reduced motion</dt><dd>Standard entrance fade; no confetti on results — the numbers are the reward.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>enter</dt><dd>Sections rise 180 ms, 24 ms apart.</dd>
<dt>press</dt><dd>Rows 0.985 / 120 ms; “Cook tonight” 0.97 / 120 ms.</dd>
</dl>`;
  return { html, css, note };
}

function candidatesQuests() {
  const { tabbarS } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <h1 class="d2">Progress · quests</h1>
    <span class="chip sag"><span class="dot" style="background:var(--sage)"></span>candidate</span>
  </header>

  <section class="sect in" style="--i:1">
    <div class="label">This week’s quests</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Cook <span class="mono m3">3</span> suppers</span></span><span class="mono m2">1 of 3</span><span class="fit" aria-label="1 of 3"><i></i><i class="o"></i><i class="o"></i></span></div>
      <div class="row"><span class="n"><span class="t2">Save <span class="mono m3">5</span> foods from spoiling</span></span><span class="mono m2">3 of 5</span><span class="fit" aria-label="3 of 5"><i></i><i></i><i></i><i class="o"></i><i class="o"></i></span></div>
      <div class="row"><span class="n"><span class="t2">Try one new recipe</span></span><span class="mono m2">0 of 1</span><span class="fit" aria-label="0 of 1"><i class="o"></i></span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">Quests count real things — cooks made and food saved. They reset on Monday; a missed week leaves no debt.</p>
  </section>

  <section class="sect in" style="--i:2">
    <div class="label">Badges</div>
    <div class="badges">
      <div class="bd on"><span class="bi" style="background:var(--accent-lt)"></span><span class="cap">First cook</span><span class="cap c2">Aug</span></div>
      <div class="bd on"><span class="bi" style="background:var(--sage)"></span><span class="cap">Zero-waste week</span><span class="cap c2">Sep</span></div>
      <div class="bd on"><span class="bi" style="background:var(--oat)"></span><span class="cap">Ten dinners</span><span class="cap c2">Sep</span></div>
      <div class="bd"><span class="bi"></span><span class="cap c2">Month of Sundays</span><span class="cap c2">—</span></div>
    </div>
  </section>

  <p class="t2 c2 in" style="--i:3">Candidate, not default: rewards only cooks made and food saved — never app opens, never streak flames. A quiet progress bar per quest replaces confetti; the risk it watches is turning dinner into a chore.</p>
</div></div>
${tabbarS('progress')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 14px}
.badges{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.bd{display:grid;justify-items:center;gap:6px;text-align:center;padding:12px 6px;background:var(--surface);border-radius:16px;box-shadow:inset 0 0 0 .5px var(--rule)}
.bd .bi{width:34px;height:34px;border-radius:11px;background:var(--tile);box-shadow:inset 0 0 0 1.5px var(--rule2)}
`;
  const note = `<h1>Candidate — quests &amp; badges (held)</h1>
<p>Duolingo / Apple Fitness structure rebuilt in this direction’s palette and language: three quest rows with count progress (“1 of 3”, fit-meter dots), a badge shelf, and copy that names the reward rule — cooks made and food saved, never app opens, no streak flames, no confetti. Held rather than adopted: it is the densest surface in the direction and sits one step from gamification creep, so it ships only if the Progress tab needs a weekly spine.</p>
<h2>States</h2>
<dl>
<dt>week not started</dt><dd>Quest rows show “0 of n” and stay tappable into the cook flow — no locked look.</dd>
<dt>quest done</dt><dd>Row’s meter fills, one 480 ms settle, then quiet; no banner.</dd>
<dt>badge locked</dt><dd>Hollow tile with its condition in the caption — visible, not greyed to invisibility.</dd>
<dt>reduced motion</dt><dd>Settle becomes a 150 ms fade.</dd>
</dl>`;
  return { html, css, note };
}

function candidatesTour() {
  const { tabbarF } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0">
    <span class="mono m3 c2">Step 2 of 3</span>
    <a class="back2" href="#" aria-label="Back"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 5-7 7 7 7"/></svg></a>
  </header>

  <div class="dots in" style="--i:0" aria-hidden="true"><i class="d"></i><i class="c"></i><i></i></div>
  <h1 class="d2 tt in" style="--i:1">This is your kitchen.</h1>
  <p class="t1 in" style="--i:2">Scan one shelf. Everything you add stays on this phone — tonight’s dinner is picked from what you actually have.</p>
  <div class="tourimg in" style="--i:3" aria-hidden="true">
    <div class="shelf"></div>
    <div class="shelf"><span class="b" style="left:12%;width:16%;background:var(--sage)"></span><span class="b" style="left:34%;width:12%;background:var(--accent-lt)"></span><span class="b" style="left:52%;width:20%;background:var(--oat)"></span><span class="b" style="left:78%;width:10%;background:var(--rose)"></span></div>
  </div>

  <div class="btng in" style="--i:4">
    <button class="btn primary">Scan a shelf</button>
    <button class="btn ghost">Skip the tour</button>
  </div>
  <p class="cap c2 in" style="--i:5;margin-top:10px">After each step you return Home. Nothing is collected during the tour.</p>
</div></div>
${tabbarF('tonight')}`;
  const css = `
.head{display:flex;justify-content:space-between;align-items:center;padding:6px 2px 6px;min-height:44px}
.back2{width:44px;height:44px;display:grid;place-items:center;color:var(--ink);margin-right:-10px}
.dots{display:flex;gap:6px;padding:8px 2px}
.dots i{width:6px;height:6px;border-radius:3px;background:var(--rule2)}
.dots i.c{width:18px;background:var(--accent)}
.dots i.d{background:var(--ink2)}
.tt{margin-top:18px}
.tourimg{margin-top:22px;background:var(--surface);border-radius:20px;box-shadow:inset 0 0 0 .5px var(--rule);padding:22px 18px;display:grid;gap:14px}
.shelf{height:64px;border-radius:12px;background:var(--bg-deep);position:relative;box-shadow:inset 0 0 0 .5px var(--rule)}
.shelf .b{position:absolute;bottom:0;top:14px;border-radius:6px}
.btng{display:grid;gap:8px;margin-top:26px}
`;
  const note = `<h1>Candidate — the constrained tour (kept)</h1>
<p>Three short steps, shown here at step 2: progress dots, one sentence of copy, one CSS-drawn image, one action. The back button is visible on every step; each step auto-returns Home when left idle or completed — the tour never chains forward by itself, and “Skip the tour” is a first-class action from step 1. Kept because it carries the on-device promise early; constrained because it is three screens, ever.</p>
<h2>States</h2>
<dl>
<dt>auto-return</dt><dd>After 25 s idle or on completion, the step hands back to Home with a 150 ms fade; no modal to dismiss.</dd>
<dt>back</dt><dd>44 pt back chevron on every step; step 1’s back exits the tour.</dd>
<dt>resume</dt><dd>A partially seen tour reopens at the first unseen step, never re-shows completed ones.</dd>
<dt>reduced motion</dt><dd>All entrances are 150 ms fades; the dots do not animate.</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { table, candidatesQuests, candidatesTour };

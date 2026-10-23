/* Direction P screens: taste-profile (learning surface), explore. */
'use strict';

function tasteProfile() {
  const { tabbarF } = require('./shell');
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0"><h1 class="d2">Taste profile</h1></header>
  <p class="t2 c2 lede in" style="--i:0">Built from what you cook and rate — counts, not scores. Nothing here is shared.</p>

  <section class="sect in" style="--i:1">
    <div class="label">What I learned this month</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Coriander — <span class="mono m3">4</span> of the <span class="mono m3">5</span> times it appeared, you picked it out or swapped it.</span><br><span class="cap c2">Evidence: 5 recipes · 3 swaps · 2 ratings</span></span></div>
      <div class="row"><span class="n"><span class="t2">Chilli heat — every “mild” rating came after a medium recipe.</span><br><span class="cap c2">Evidence: 6 cooks · 4 “too hot”</span></span></div>
      <div class="row"><span class="n"><span class="t2">Spring onion — finishes <span class="mono m3">9</span> dishes, never skipped.</span><br><span class="cap c2">Evidence: 9 cooks · 2 rated 5</span></span></div>
    </div>
  </section>

  <section class="sect in" style="--i:2">
    <div class="label">Confirm or correct <span class="mono m3 c2">2 pending</span></div>
    <div class="rows">
      <div class="row wrong">
        <span class="n"><span class="t2">Stop suggesting coriander?</span><br><span class="cap c2">Won’t use this · you can bring it back any time</span></span>
        <span class="ans2"><button class="btn small ghost">Right</button><button class="btn small ghost">Wrong</button></span>
      </div>
      <div class="row greyed">
        <span class="n"><span class="t2 c2">Won’t use this · coriander</span><br><span class="cap c2">Recorded. <a href="#">Undo</a></span></span>
      </div>
      <div class="row">
        <span class="n"><span class="t2">Keep chilli out of Tonight?</span><br><span class="cap c2">Two different doors — pick the right one</span></span>
        <span class="ans2 col"><button class="btn small ghost">Don’t ask again</button><button class="btn small ghost">This is wrong</button></span>
      </div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">“Don’t ask again” keeps the record and stops the prompts. “This is wrong” corrects it and shows the line that will change.</p>
  </section>

  <section class="sect in" style="--i:3">
    <div class="label">Forgotten things</div>
    <div class="rows">
      <div class="row"><span class="n"><span class="t2">Coriander <span class="mono m3 c2">· since Sept</span></span><span class="mono m3"><a href="#">Forget this</a></span></div>
      <div class="row"><span class="n t2">Chilli heat <span class="mono m3 c2">· since Aug</span></span><span class="mono m3"><a href="#">Forget this</a></span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0"><a href="#">Forget everything</a> clears the whole profile in one confirm. Cooking records (meals, ratings) are history — they stay; only the learned lines go.</p>
  </section>

  <section class="sect in" style="--i:4">
    <div class="card quiet">
      <p class="t1">Quiet honesty</p>
      <p class="t2 c2">Only 11 of your last 14 cooks were rated. Small counts move these lines slowly — that is deliberate. Below 5 ratings on an ingredient it says nothing at all.</p>
    </div>
  </section>

  <section class="sect in" style="--i:5">
    <div class="label">Debug</div>
    <div class="rows">
      <div class="row"><span class="n t2">Where each line came from</span><span class="mono m3">open →</span></div>
    </div>
    <p class="cap c2">Debug answers three questions: what is known, what is unknown, what is stale. Unknown and stale are recorded states, rendered like any other state — visible, honest, and treated as normal.</p>
  </section>
</div></div>
${tabbarF('cookbook')}`;
  const css = `
.head{padding:6px 2px 6px}
.lede{padding:0 2px 16px}
.ans2{display:flex;gap:8px;flex:none}
.ans2.col{flex-direction:column;align-items:stretch}
.row.wrong{align-items:flex-start}
.row.greyed{background:var(--surface-muted,transparent);opacity:.55}
.row.greyed .t2{color:var(--ink2)}
.quiet{padding:14px 16px}
.quiet p+p{margin-top:8px}
`;
  const note = `<h1>Taste profile — the learning surface</h1>
<p>Learnings are sentences with mono evidence counts (“4 of the 5 times…”), never a score dial. Every learned line has a Right / Wrong pair; on Wrong the row greys to “Won’t use this” with Undo in place — the change is shown before it lands, and nothing is silently written.</p>
<p>“Don’t ask again” and “This is wrong” are different doors and the copy says so: one stops the prompts, the other corrects the record and names the line that will change. Forgetting comes in two sizes — Forget this per line, Forget everything behind one confirm — and cooking history is not a learned line, so it survives both.</p>
<p>The quiet-honesty card and the debug section are part of the language: what is known, unknown and stale are states with rendering, not errors.</p>
<h2>States</h2>
<dl>
<dt>no data</dt><dd>“Cook a few meals and this fills in with counts — nothing is shared.” One line, no illustration.</dd>
<dt>thin data</dt><dd>Sections show only what clears the 5-rating rule; the rest is absent, not greyed.</dd>
<dt>undo window</dt><dd>Undo is available from the row itself and from the toast for the rest of the session.</dd>
<dt>rejected adaptation</dt><dd>A tasted adaptation is a new version; a rejected cook leaves the original’s record untouched.</dd>
<dt>reduced motion</dt><dd>The grey-out is a 150 ms opacity change, no scale.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>enter</dt><dd>Five blocks rise 180 ms, 24 ms apart.</dd>
<dt>wrong → greyed</dt><dd>Row fades to 55% in 150 ms; no layout shift.</dd>
<dt>press</dt><dd>Rows 0.985 / 120 ms; chips fill 200 ms.</dd>
</dl>`;
  return { html, css, note };
}

function explore() {
  const { tabbarF } = require('./shell');
  const cat = [
    ['Butter bean curry', 'You cook this about every 10 days', '35 min', '10 of 10'],
    ['Creamy pesto & kale pasta', 'The weeknight fallback', '15 min', '10 of 10'],
    ['Miso salmon with greens', 'Loves: miso, spring onion', '30 min', '9 of 10'],
  ];
  const com = [
    ['Maya’s lemon orzo', 'From your table · reviewed', '20 min', '10 of 10', ''],
    ['One-pan gnocchi', 'Community · reviewed', '25 min', '9 of 10', 'cooked by 37 people'],
  ];
  const html = `<div class="screen"><div class="scroll">
  <header class="head in" style="--i:0"><h1 class="d2">Explore</h1></header>
  <div class="field in" style="--i:1"><svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><span>Search recipes</span></div>
  <div class="chips in" style="--i:2">
    <span class="chip" style="background:var(--chip-acc)">Can cook now</span>
    <span class="chip">Under 30 min</span>
    <span class="chip">Vegetarian</span>
    <span class="chip">One pan</span>
  </div>

  <section class="sect in" style="--i:3">
    <div class="label">Catalog · ranked by what you can cook now <a href="#">why this order</a></div>
    <div class="rows">
      ${cat.map(([n, why, t, f]) => `<div class="row"><span class="n t2">${n}<br><span class="cap c2">${why}</span></span><span class="mono m2 c2">${t}</span><span class="mono m2">${f}</span></div>`).join('')}
    </div>
  </section>

  <section class="sect in" style="--i:4">
    <div class="label">From the community · reviewed</div>
    <div class="rows">
      ${com.map(([n, src, t, f, cooked]) => `<div class="row"><span class="n t2">${n}<br><span class="cap c2">${src}${cooked ? ` · ${cooked}` : ''}</span></span><span class="mono m2 c2">${t}</span><span class="mono m2">${f}</span></div>`).join('')}
      <div class="row"><span class="n t2">Squash &amp; sage risotto<br><span class="cap c2">Community · reviewed · new to you</span></span><span class="mono m2 c2">50 min</span><span class="mono m2">8 of 10</span></div>
    </div>
    <p class="cap c2" style="margin:8px 4px 0">No like counts, no follower counts. “Cooked by N people” appears only above a real minimum — popularity is not shown until it means something.</p>
  </section>
</div></div>
${tabbarF('explore')}`;
  const css = `
.head{padding:6px 2px 6px}
.chips{display:flex;gap:8px;margin-top:10px;overflow-x:auto;scrollbar-width:none}
.chips::-webkit-scrollbar{display:none}
`;
  const note = `<h1>Explore — catalog + community, cookability-ranked</h1>
<p>Two bounded lists, not a feed: the catalog ranked by what-you-can-cook-now with a fit line on every card, then reviewed community recipes. Search and filter chips are first-class. Social proof is honest: no like counts, no follower counts, and “cooked by 37 people” only above a real minimum — until then the row says nothing about popularity.</p>
<h2>States</h2>
<dl>
<dt>loading</dt><dd>One 2 px indeterminate line in the section; the last valid list stays up.</dd>
<dt>offline</dt><dd>The cached list renders with “As of Sat 2 pm” in the section label. No error wall.</dd>
<dt>empty results</dt><dd>“Nothing fits these filters — loosen one?” with the chips kept warm.</dd>
<dt>below minimum</dt><dd>A community recipe with 12 cooks shows no social line at all.</dd>
<dt>moderation</dt><dd>Held recipes never appear; removal drops the row and Tonight falls back to the local bill.</dd>
<dt>reduced motion</dt><dd>Standard entrance becomes a fade; nothing else moves.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>filter switch</dt><dd>Crossfade 150 ms under a stable frame.</dd>
<dt>press</dt><dd>Rows 0.985 / 120 ms.</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { tasteProfile, explore };

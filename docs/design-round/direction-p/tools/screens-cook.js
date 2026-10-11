/* Direction P screens: cook mode (mid-cook, completion) — cook palette. */
'use strict';

const { plate } = require('./screens-tonight');

function cookLechef() {
  const html = `<div class="screen"><div class="scroll cook-scroll">
  <div class="ctop in" style="--i:0">
    <div><div class="label">Ginger chicken udon noodles</div><div class="cap mono c2">Step 4 of 8 · 11 min in</div></div>
    <a class="x" href="#" aria-label="Leave cook"><svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 3l12 12M15 3 3 15"/></svg></a>
  </div>
  <div class="prog in" style="--i:0" aria-hidden="true"><i class="d"></i><i class="d"></i><i class="d"></i><i class="c"></i><i></i><i></i><i></i><i></i></div>

  <div class="stepno in" style="--i:1"><span class="mono m3 c2">4</span><span class="cap c2">Noodles in</span></div>
  <p class="step in" style="--i:1">Add the noodles and <em>3 tbsp</em> water. Toss for <em>2 min</em> until the sauce coats everything.</p>

  <div class="timers in" style="--i:2">
    <div class="tile">
      <div class="tt"><span class="cap c2">Noodles</span>
        <svg class="ring" viewBox="0 0 22 22"><circle class="bg" cx="11" cy="11" r="9"/><circle class="fg" cx="11" cy="11" r="9" style="stroke-dashoffset:22"/></svg>
      </div>
      <div class="digits mono">1:42</div>
    </div>
    <div class="tile paused">
      <div class="tt"><span class="cap c2">Sauce · paused</span>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1.2"/><rect x="14" y="4" width="4" height="16" rx="1.2"/></svg>
      </div>
      <div class="digits mono c2">0:38</div>
    </div>
  </div>
  <p class="cap c2 in" style="--i:2;margin:8px 4px 0">Tap a tile to pause · long-press to remove</p>

  <div class="chef card in" style="--i:3">
    <div class="label c2">LeChef</div>
    <p class="t1">Check the thickest piece: <b class="mono">74 °C</b> in the middle — thermometer, not colour.</p>
    <div class="acts"><button class="btn small ghost">Set 2 min timer</button><button class="btn small ghost">Look at the pan</button></div>
  </div>
</div></div>

<div class="cbottom in" style="--i:5">
  <div class="offline in" style="--i:4" role="status">
    <span class="odot" aria-hidden="true"></span>
    <span class="cap">LeChef is offline. Steps and timers still work.</span>
  </div>
  <div class="voice">
    <span class="bars static" aria-label="On-device listening"><i></i><i></i><i></i><i></i><i></i></span>
    <span class="cap c2"><b>On-device listening.</b> Say: next · back · repeat · timer N minutes · show</span>
  </div>
  <div class="cbrow">
    <button class="cbtn ghost2">Back</button>
    <button class="cbtn primary2">Next step</button>
  </div>
  <div class="lookrow">
    <button class="btn small ghost look"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 8.5A2.5 2.5 0 0 1 6.5 6h1L9 4h6l1.5 2h1A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z"/><circle cx="12" cy="12.5" r="3.5"/></svg>Look</button>
    <span class="cap c2">Camera look: one frame, viewfinder visible, never a safety verdict.</span>
  </div>
</div>`;
  const css = `
.cook-scroll{padding:0 20px 260px}
.ctop{display:flex;justify-content:space-between;align-items:center;height:48px;margin-top:4px}
.ctop .x{width:44px;height:44px;display:grid;place-items:center;color:var(--ink2)}
.prog{display:flex;gap:4px;margin-top:6px}
.prog i{flex:1;height:3px;border-radius:2px;background:var(--rule2)}
.prog i.d{background:var(--ink2)}
.prog i.c{background:var(--accent)}
.stepno{margin-top:16px;display:flex;align-items:baseline;gap:8px}
.step{font-size:var(--cook);line-height:var(--cookl);font-weight:600;letter-spacing:-.01em;margin-top:8px}
.step em{font-style:normal;font-family:var(--mono);font-size:.78em;line-height:1;background:var(--tile);padding:2px 7px;border-radius:6px;color:var(--accent-lt);position:relative;top:-2px;white-space:nowrap}
.timers{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:14px}
.tile{border-radius:16px;background:var(--tile);box-shadow:inset 0 0 0 .5px var(--rule);padding:12px 14px;min-height:96px;display:flex;flex-direction:column;justify-content:space-between;transition:transform 120ms var(--out)}
.tile:active{transform:scale(.97)}
.tile .tt{display:flex;justify-content:space-between;align-items:center;color:var(--ink2)}
.tile .digits{font-size:40px;line-height:44px;font-weight:500;color:var(--accent-lt);letter-spacing:-.02em}
.tile.paused .digits{color:var(--ink2)}
.ring{width:20px;height:20px;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:2.5}
.ring .bg{stroke:var(--rule2)}
.ring .fg{stroke:var(--accent);stroke-dasharray:56.5}
.chef{margin-top:16px;padding:14px 16px;border-radius:16px}
.chef p{margin-top:6px}
.chef .acts{display:flex;gap:8px;margin-top:12px}
.chef .acts .btn{min-height:44px;white-space:nowrap;padding:0 12px}
.offline{display:flex;align-items:center;gap:8px;margin-top:20px;padding:10px 14px;border-radius:12px;background:var(--tile)}
.odot{width:8px;height:8px;border-radius:50%;background:var(--oat);flex:none}
.cbottom{position:absolute;left:14px;right:14px;bottom:24px;display:grid;gap:10px}
.offline{display:flex;align-items:center;gap:8px;padding:10px 14px;border-radius:12px;background:var(--tile)}
.voice{display:flex;align-items:center;gap:12px;padding:4px 6px}
.bars{display:flex;gap:3px;align-items:center;height:22px;width:34px;flex:none}
.bars i{width:4px;border-radius:2px;background:var(--accent-lt)}
.bars.static i{height:7px}
.bars.static i:nth-child(2){height:14px}
.bars.static i:nth-child(3){height:20px}
.bars.static i:nth-child(4){height:11px}
.bars.static i:nth-child(5){height:6px}
.cbrow{display:grid;grid-template-columns:1fr 2fr;gap:10px}
.cbtn{min-height:64px;border-radius:16px;font:inherit;font-weight:600;font-size:var(--t1);border:0;cursor:pointer;transition:transform 120ms var(--out);white-space:nowrap;padding:0 10px}
.cbtn:active{transform:scale(.97)}
.cbtn.primary2{background:var(--btn-fill);color:var(--btn-fg)}
.cbtn.ghost2{background:transparent;box-shadow:inset 0 0 0 1.5px var(--rule2);color:var(--ink)}
.lookrow{display:flex;align-items:center;gap:12px}
.look{flex:none;min-height:44px}
`;
  const note = `<h1>Cook mode — mid-cook (cook palette)</h1>
<p>Cook mode has its own deep warm surface (deepOlive family), matte, no glass, and ignores the system appearance. The step is the largest body type in the app; amounts and durations are mono highlights; timers are first-class tiles whose thin ring depletes linearly — a ring that eases is lying about time. Tap pauses, long-press removes, and the timer runs on the device even when the session drops.</p>
<p>The offline banner is rendered live here on purpose: when the Live session drops, one line says so, voice falls back to on-device recognition for the five words, and the bars go static — no fake pulse when there is no amplitude.</p>
<p>Targets are 64 pt (Back / Next); every control on this screen clears 44 pt.</p>
<h2>States</h2>
<dl>
<dt>online</dt><dd>Banner absent; voice bars carry real input amplitude and the hint reads “Listening.” The camera look stays push-to-see with a visible viewfinder.</dd>
<dt>timer done</dt><dd>Tile settles once (480 ms) and the digits invert; haptic rigid. The step does not advance by itself.</dd>
<dt>adapted step</dt><dd>Adapt rescales amounts and flags the changed step (“one thigh, so 6 min not 8”); time changes only under a reviewed rule.</dd>
<dt>killed app</dt><dd>Step state persists: reopen at step 4 with the timer still counting from its persisted deadline.</dd>
<dt>reduced motion</dt><dd>Ring still moves (information), entrances become 150 ms fades, no tile bounce on done.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>step change</dt><dd>“Next step” happens 8–12 times per cook with wet hands: snap 200 ms, no flourish.</dd>
<dt>timer add</dt><dd>Tile arrives at 320 ms (move).</dd>
<dt>voice</dt><dd>Bars are driven by real amplitude only; muted or offline = static shape.</dd>
</dl>`;
  return { html, css, note };
}

function cookComplete() {
  const html = `<div class="screen"><div class="scroll cook-scroll">
  <div class="ctop in" style="--i:0">
    <div><div class="label">Ginger chicken udon noodles</div><div class="cap mono c2">Cooked in 24 min · 2 servings</div></div>
    <a class="x" href="#" aria-label="Close"><svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 3l12 12M15 3 3 15"/></svg></a>
  </div>

  <div class="in" style="--i:0">${plate(170, 'cc-plate')}</div>

  <h1 class="d2 cc-title in" style="--i:1">Cook complete</h1>
  <p class="t2 c2 in" style="--i:2">Saved on this phone. Sharing is a separate choice.</p>

  <div class="card cc-rate in" style="--i:3">
    <div class="label c2">How was it?</div>
    <div class="stars" role="radiogroup" aria-label="Rating">
      <span class="star on"></span><span class="star on"></span><span class="star on"></span><span class="star on"></span><span class="star"></span>
    </div>
  </div>

  <div class="card cc-note in" style="--i:4">
    <div class="label c2">One line for next time</div>
    <p class="t1">“Add lemon at the end, off the heat.”</p>
    <div class="acts"><button class="btn small ghost">Edit</button><button class="btn small ghost">Say it instead</button></div>
  </div>

  <p class="cap c2 cc-nut in" style="--i:5">About <span class="mono">520 kcal</span> per serving · logged <span class="mono">9</span> of your <span class="mono">14</span> meals this week</p>
</div></div>

<div class="cbottom in" style="--i:6">
  <button class="cbtn primary2" style="min-height:64px;border-radius:16px">Done</button>
  <p class="cap c2" style="text-align:center;padding-bottom:8px">Nothing is shared until you choose to.</p>
</div>`;
  const css = `
.cook-scroll{padding:0 20px 200px}
.ctop{display:flex;justify-content:space-between;align-items:center;height:48px;margin-top:4px}
.ctop .x{width:44px;height:44px;display:grid;place-items:center;color:var(--ink2)}
.cc-plate{margin-top:14px}
.cc-title{margin-top:20px}
.cc-rate{margin-top:24px;padding:14px 16px}
.stars{display:flex;gap:10px;margin-top:10px}
.star{width:30px;height:30px;border-radius:9px;background:var(--tile);box-shadow:inset 0 0 0 1px var(--rule2);display:block}
.star.on{background:var(--accent-lt);box-shadow:none}
.cc-note{margin-top:12px;padding:14px 16px}
.cc-note p{margin-top:8px}
.cc-note .acts{display:flex;gap:8px;margin-top:12px}
.cc-nut{margin-top:14px;padding:0 4px}
.cbottom{position:absolute;left:14px;right:14px;bottom:20px;display:grid;gap:8px}
.cbtn:active{transform:scale(.97)}
.primary2{background:var(--btn-fill);color:var(--btn-fg);font:inherit;font-weight:600;font-size:var(--t1);border:0;cursor:pointer;transition:transform 120ms var(--out)}
`;
  const note = `<h1>Cook-complete (the one richer moment)</h1>
<p>Cook mode ignores the system appearance, so this file renders the completion state on the same deep warm surface: the plate block, the rating, the one-line note (typed or by voice, transcribed and confirmed), one honest nutrition line with its coverage, and the receipt (“Saved on this phone”). Sharing is a separate action with its own preview — see the Table screen.</p>
<h2>States</h2>
<dl>
<dt>rating</dt><dd>4+ can nominate the version actually cooked for catalog review; below 4 the line stays quiet.</dd>
<dt>note by voice</dt><dd>“Say it instead” transcribes, shows the text, and waits for confirmation; a transcript alone never logs or shares a meal.</dd>
<dt>nutrition coverage</dt><dd>The kcal line appears only when the meal is logged; the week’s coverage is stated as a count, never a percentage.</dd>
<dt>reduced motion</dt><dd>The completion moment becomes a 150 ms fade; nothing repeats.</dd>
</dl>
<h2>Motion</h2>
<dl>
<dt>the moment</dt><dd>Once a day the plate settles in at 480 ms with one gentle bounce and the kcal count counts up once — the only counting number in the app.</dd>
<dt>everything else</dt><dd>Buttons stay snap-fast; exits are faster than entrances.</dd>
</dl>`;
  return { html, css, note };
}

module.exports = { cookLechef, cookComplete };

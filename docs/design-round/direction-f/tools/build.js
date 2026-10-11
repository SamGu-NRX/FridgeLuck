#!/usr/bin/env node
// Direction F round set generator. Emits self-contained 393x852 HTML mocks.
// Each file: phone frame + state notes under the frame. No external assets, no JS libraries.
const fs = require('fs');
const path = require('path');
const OUT = path.join(__dirname, '..', 'docs', 'design-round', 'direction-f');

// ---------------------------------------------------------------- palettes
const PALETTES = {
  light: {
    paper:'#F7F8F6', ink:'#131313', ink2:'#5E5E59', ink3:'#8A8A84',
    rule:'#E4E5E0', rule2:'#CFD0CA', yolk:'#F5C400', yolkSoft:'#FFF3B8',
    yolkInk:'#6A5300', err:'#C8321E', btnInk:'#FFFFFF',
    bar:'rgba(250,250,247,.92)', barline:'rgba(0,0,0,.09)', barshadow:'rgba(0,0,0,.22)',
    card:'#FBFBF9', cardline:'rgba(0,0,0,.12)', photoBg:'#E9EAE4',
    photoLine:'rgba(0,0,0,.08)', photoStripe:'rgba(0,0,0,.035)',
  },
  dark: {
    paper:'#191A18', ink:'#F1F1ED', ink2:'#999993', ink3:'#6A6A64',
    rule:'#2A2B28', rule2:'#43443F', yolk:'#F5C400', yolkSoft:'#2A2300',
    yolkInk:'#F5C400', err:'#FF6B57', btnInk:'#161715',
    bar:'rgba(28,29,27,.93)', barline:'rgba(255,255,255,.14)', barshadow:'rgba(0,0,0,.5)',
    card:'#1F201D', cardline:'rgba(255,255,255,.12)', photoBg:'#20211E',
    photoLine:'rgba(255,255,255,.09)', photoStripe:'rgba(255,255,255,.045)',
  },
  hob: {
    paper:'#0C0C0C', ink:'#F1F1ED', ink2:'#8E8E88', ink3:'#5A5A55',
    rule:'#252525', rule2:'#3A3A36', yolk:'#F5C400', yolkSoft:'#2A2300',
    yolkInk:'#F5C400', err:'#FF6B57', btnInk:'#0C0C0C',
    bar:'rgba(22,22,22,.93)', barline:'rgba(255,255,255,.12)', barshadow:'rgba(0,0,0,.6)',
    card:'#161616', cardline:'rgba(255,255,255,.12)', photoBg:'#1A1A18',
    photoLine:'rgba(255,255,255,.09)', photoStripe:'rgba(255,255,255,.045)',
  },
};

// ---------------------------------------------------------------- base css
function baseCSS(t) {
  return `:root{--paper:${t.paper};--ink:${t.ink};--ink2:${t.ink2};--ink3:${t.ink3};--rule:${t.rule};--rule2:${t.rule2};--yolk:${t.yolk};--yolk-soft:${t.yolkSoft};--yolk-ink:${t.yolkInk};--err:${t.err};--btn-ink:${t.btnInk};--bar:${t.bar};--barline:${t.barline};--barshadow:${t.barshadow};--card:${t.card};--cardline:${t.cardline};--photo-bg:${t.photoBg};--photo-line:${t.photoLine};--photo-stripe:${t.photoStripe};
--sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display","Helvetica Neue",Helvetica,Arial,sans-serif;--mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;--out:cubic-bezier(.23,1,.32,1);--sheet:cubic-bezier(.32,.72,0,1)}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--sans);background:#D8D8D2;color:#2A2A28;-webkit-font-smoothing:antialiased;display:flex;flex-direction:column;align-items:center;gap:26px;padding:40px 20px 90px;font-size:17px;line-height:24px}
.phone{position:relative;width:393px;height:852px;flex:none;background:var(--paper);color:var(--ink);border-radius:54px;overflow:hidden;box-shadow:0 0 0 1px rgba(0,0,0,.14),0 30px 60px -20px rgba(0,0,0,.3)}
.island{position:absolute;top:11px;left:50%;transform:translateX(-50%);width:125px;height:37px;background:#000;border-radius:20px;z-index:12}
.status{position:absolute;top:0;left:0;right:0;height:54px;display:flex;justify-content:space-between;align-items:center;padding:4px 36px 0 44px;font-size:17px;font-weight:600;color:var(--ink);z-index:11}
.status .sig{display:flex;gap:7px;align-items:center}
.homebar{position:absolute;bottom:8px;left:50%;transform:translateX(-50%);width:139px;height:5px;border-radius:3px;background:var(--ink);z-index:12}
.screen{position:absolute;inset:0;padding-top:54px}
.scroll{height:100%;overflow:auto;scrollbar-width:none;padding:0 24px 150px}
.scroll::-webkit-scrollbar{display:none}
.mono{font-family:var(--mono);font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.c2{color:var(--ink2)}.c3{color:var(--ink3)}
.label{font-size:13px;line-height:16px;font-weight:600}
.cap{font-size:13px;line-height:16px}
.sec{font-size:15px;line-height:20px}
.btn{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;height:52px;border-radius:12px;font:inherit;font-weight:600;font-size:17px;border:0;cursor:pointer;transition:transform 120ms var(--out);color:var(--ink);background:transparent;padding:0 18px;white-space:nowrap}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--ink);color:var(--btn-ink)}
.btn.ghost{box-shadow:inset 0 0 0 1px var(--rule2)}
.btn.small{height:40px;padding:0 14px;border-radius:10px;font-size:15px;width:auto;flex:none}
.btn:focus-visible{outline:2px solid var(--ink);outline-offset:2px}
.in{animation:rise 200ms var(--out) both;animation-delay:calc(var(--i,0)*40ms)}
@keyframes rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.head{display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;padding:10px 0 22px}
.head h1{font-size:28px;line-height:32px;font-weight:700;letter-spacing:-.015em}
.head a{color:var(--ink);text-decoration:none;font-size:17px}
.nav{display:flex;justify-content:space-between;align-items:center;height:44px;margin:0 -4px}
.nav a{display:flex;align-items:center;gap:4px;color:var(--ink);text-decoration:none;font-size:17px;padding:0 4px}
.sect{margin-top:28px}
.sect h3{font-size:13px;line-height:16px;font-weight:600;margin-bottom:4px;display:flex;justify-content:space-between;align-items:baseline}
.sect h3 span,.sect h3 .r{font-weight:400;color:var(--ink2)}
.sect h3 .r{font-family:var(--mono)}
.row{display:flex;align-items:center;gap:12px;min-height:44px;padding:10px 0;border-top:1px solid var(--rule);transition:transform 120ms var(--out)}
.row:first-of-type{border-top:0}
.row:active{transform:scale(.985)}
.row .n{flex:1;min-width:0}
.row .n small{display:block;font-size:13px;line-height:16px;color:var(--ink2)}
.row .q{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:15px;color:var(--ink2);white-space:nowrap}
.tag{font-family:var(--mono);font-size:13px;line-height:16px;padding:3px 7px;border-radius:6px;background:var(--yolk-soft);color:var(--yolk-ink);white-space:nowrap}
.sq{width:12px;height:12px;border-radius:3px;background:var(--ink);flex:none}
.sq.o{background:transparent;box-shadow:inset 0 0 0 1.5px var(--rule2)}
.sq.a{background:transparent;box-shadow:inset 0 0 0 1.5px var(--ink)}
.sq.d{background:transparent;box-shadow:inset 0 0 0 1.5px var(--rule2);outline:1px dashed var(--rule2);outline-offset:-1px}
.chips{display:flex;gap:8px;margin-top:10px;flex-wrap:wrap}
.chip{height:36px;padding:0 14px;border-radius:10px;display:inline-flex;align-items:center;gap:8px;font-size:15px;font-weight:500;box-shadow:inset 0 0 0 1px var(--rule2);background:transparent;border:0;font-family:inherit;color:var(--ink);cursor:pointer;transition:transform 120ms var(--out),background 150ms ease,box-shadow 150ms ease}
.chip:active{transform:scale(.97)}
.chip.on{background:var(--yolk-soft);box-shadow:inset 0 0 0 1px var(--yolk);color:var(--yolk-ink)}
.chip.quiet{box-shadow:none;color:var(--ink2);padding:0 8px}
.fit{display:inline-flex;gap:3px;align-items:center}
.fit i{width:9px;height:9px;border-radius:2px;background:var(--ink)}
.fit i.o{background:transparent;box-shadow:inset 0 0 0 1.5px var(--rule2)}
.fit i.y{background:var(--yolk)}
.photo{position:relative;background:var(--photo-bg);border-radius:14px;box-shadow:inset 0 0 0 .5px var(--photo-line);overflow:hidden}
.photo::before{content:"";position:absolute;inset:0;background:repeating-linear-gradient(135deg,transparent 0 10px,var(--photo-stripe) 10px 11px)}
.photo span{position:absolute;left:12px;bottom:10px;font-family:var(--mono);font-size:11px;color:var(--ink3)}
.tabbar{position:absolute;left:16px;right:16px;bottom:22px;display:flex;gap:10px;z-index:10}
.tabs{flex:1;height:62px;border-radius:31px;display:flex;align-items:center;justify-content:space-around;padding:0 6px;background:var(--bar);box-shadow:inset 0 0 0 .5px var(--barline),0 10px 28px -10px var(--barshadow)}
.tab{display:flex;flex-direction:column;align-items:center;gap:2px;font-size:10.5px;line-height:12px;font-weight:500;color:var(--ink3);width:62px}
.tab.on{color:var(--ink)}
.tab svg{width:24px;height:24px}
.scanbtn{width:62px;height:62px;border-radius:31px;display:grid;place-items:center;background:var(--ink);color:var(--btn-ink);box-shadow:0 10px 28px -10px rgba(0,0,0,.45);transition:transform 120ms var(--out)}
.scanbtn:active{transform:scale(.95)}
/* Shell S: flat bar, central matte orb — the least glassy the system allows */
.tabbar.s .tabs{background:var(--paper);backdrop-filter:none;-webkit-backdrop-filter:none;box-shadow:inset 0 .5px 0 var(--rule2);border-radius:16px;padding:0 4px}
.orb{width:58px;height:58px;border-radius:29px;flex:none;display:grid;place-items:center;background:var(--ink);color:var(--btn-ink);transform:translateY(-14px);box-shadow:0 0 0 4px var(--paper);transition:transform 120ms var(--out)}
.orb:active{transform:translateY(-14px) scale(.95)}
/* sheets (system radius 36), no custom blur */
.dim{position:absolute;inset:0;background:rgba(19,19,19,.38);z-index:8}
.sheet{position:absolute;left:0;right:0;bottom:0;z-index:9;background:var(--paper);border-radius:36px 36px 0 0;padding:20px 24px 44px;box-shadow:inset 0 .5px 0 var(--rule2)}
.stitle{font-size:28px;line-height:32px;font-weight:700;letter-spacing:-.015em}
.shead{display:flex;justify-content:space-between;align-items:center;height:32px;margin-bottom:14px}
.shead a{color:var(--ink);text-decoration:none;font-size:17px;display:flex;align-items:center;gap:4px}
.shead a.q{color:var(--ink2)}
.note{width:393px;flex:none;font-size:13px;line-height:19px;color:#2A2A28}
.note h1{font-size:15px;line-height:20px;font-weight:600;margin-bottom:4px}
.note p{margin-bottom:12px}
.note h2{font-size:12px;line-height:16px;font-weight:600;margin:18px 0 8px;color:#5E5E59}
.note dl{display:grid;grid-template-columns:92px 1fr;gap:8px 12px}
.note dt{font-family:var(--mono);font-size:11px;line-height:19px;color:#5E5E59}
@media (prefers-reduced-motion:reduce){.in{animation:fadein 150ms ease both;animation-delay:0s}@keyframes fadein{from{opacity:0}to{opacity:1}}}
`;
}

// ---------------------------------------------------------------- chrome
const STATUS = `
  <div class="island"></div>
  <div class="status"><span>9:41</span><span class="sig">
    <svg width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx=".8"/><rect x="5" y="5.5" width="3" height="6.5" rx=".8"/><rect x="10" y="3" width="3" height="9" rx=".8"/><rect x="15" y="0" width="3" height="12" rx=".8"/></svg>
    <svg width="16" height="12" viewBox="0 0 16 12" fill="currentColor"><path d="M8 11.2 1.3 4.5a9.5 9.5 0 0 1 13.4 0z"/></svg>
    <svg width="27" height="12" viewBox="0 0 27 12" fill="none"><rect x=".5" y=".5" width="23" height="11" rx="3" stroke="currentColor" stroke-opacity=".4"/><rect x="2" y="2" width="20" height="8" rx="1.6" fill="currentColor"/><rect x="25" y="4" width="1.6" height="4" rx=".8" fill="currentColor" fill-opacity=".4"/></svg>
  </span></div>`;

const ICON = {
  tonight:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/></svg>',
  kitchen:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="6" y="2.5" width="12" height="19" rx="2"/><path d="M6 10h12M9 6v1.5M9 13.5v3"/></svg>',
  table:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 9.5h18M6 9.5V19M18 9.5V19"/><circle cx="12" cy="5" r="2.5"/></svg>',
  cookbook:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M5 4.5h10.5a2.5 2.5 0 0 1 2.5 2.5v12.5H7.5A2.5 2.5 0 0 1 5 17z"/><path d="M5 17a2.5 2.5 0 0 1 2.5-2.5H18"/></svg>',
  progress:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 20v-9M12 20V5M20 20v-5"/></svg>',
  scan:'<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9V6a2 2 0 0 1 2-2h3M15 4h3a2 2 0 0 1 2 2v3M20 15v3a2 2 0 0 1-2 2h-3M9 20H6a2 2 0 0 1-2-2v-3"/><circle cx="12" cy="12" r="3"/></svg>',
};

const tab = (id, name, on) => `<a class="tab${on ? ' on' : ''}">${ICON[id]}${name}</a>`;

const TABBAR_F = (active) => `
  <nav class="tabbar">
    <div class="tabs">
      ${tab('tonight','Tonight',active==='tonight')}
      ${tab('kitchen','Kitchen',active==='kitchen')}
      ${tab('table','Table',active==='table')}
      ${tab('cookbook','Cookbook',active==='cookbook')}
    </div>
    <a class="scanbtn" aria-label="Scan">${ICON.scan}</a>
  </nav>`;

const TABBAR_S = (active) => `
  <nav class="tabbar s">
    <div class="tabs">
      ${tab('tonight','Tonight',active==='tonight')}
      ${tab('kitchen','Kitchen',active==='kitchen')}
      <a class="orb" aria-label="Scan"><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9V6a2 2 0 0 1 2-2h3M15 4h3a2 2 0 0 1 2 2v3M20 15v3a2 2 0 0 1-2 2h-3M9 20H6a2 2 0 0 1-2-2v-3"/><circle cx="12" cy="12" r="3"/></svg></a>
      ${tab('progress','Progress',active==='progress')}
      ${tab('table','Table',active==='table')}
    </div>
  </nav>`;

const HOME_indicator = '<div class="homebar"></div>';

// small fit meters
const fit10 = (n, opts='') => {
  let s = '';
  for (let i = 0; i < 10; i++) s += `<i${i >= n ? ' class="o"' : ''}></i>`;
  return `<span class="fit" aria-label="${n} of 10 on hand"${opts}>${s}</span>`;
};

const noteHTML = (title, paras, states, motion, extra = '') => `
<aside class="note">
  <h1>${title}</h1>
  ${paras.map((p) => `<p>${p}</p>`).join('')}
  <h2>States</h2>
  <dl>
    ${states.map(([dt, dd]) => `<dt>${dt}</dt><dd>${dd}</dd>`).join('\n    ')}
  </dl>
  ${motion ? `<h2>Motion</h2>
  <dl>
    ${motion.map(([dt, dd]) => `<dt>${dt}</dt><dd>${dd}</dd>`).join('\n    ')}
  </dl>` : ''}
  ${extra}
</aside>`;

const page = (t, title, bodyInner, extraCSS = '') => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FridgeLuck mock: ${title}</title>
<style>
${baseCSS(t)}
${extraCSS}
</style>
</head>
<body>
${bodyInner}
</body>
</html>
`;

// ================================================================ TONIGHT
const tonightCSS = `
.eyebrow{display:flex;align-items:center;gap:8px}
.eyebrow i{width:10px;height:10px;background:var(--yolk);border-radius:2px}
.title{font-size:32px;line-height:34px;font-weight:700;letter-spacing:-.02em;margin:10px 0 6px}
.fitrow{display:flex;justify-content:space-between;align-items:center;margin-top:14px}
.sect{margin-top:36px}
.sect h3 a{font-weight:400;color:var(--ink2);text-decoration:none}
`;

const tonightBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head"><h1>Tonight</h1><span class="cap c2 mono">Sat 11 Oct</span></header>

    <section>
      <div class="eyebrow in" style="--i:0"><i></i><span class="label">From your fridge</span></div>
      <h2 class="title in" style="--i:1">Ginger chicken udon noodles</h2>
      <p class="mono sec c2 in" style="--i:2">25 min · 2 servings · 520 kcal</p>
      <div class="photo in" style="--i:3;aspect-ratio:3/2;margin-top:16px"><span>photo: overhead, daylight, 3:2</span></div>
      <div class="fitrow in" style="--i:4">
        ${fit10(9)}
        <span class="mono" style="font-weight:500;white-space:nowrap">9 of 10 · 1 swap</span>
      </div>
      <p class="sec in" style="--i:5;margin-top:8px">Everything except lime. Swap in a lemon, you have two.</p>
      <p class="sec c2 in" style="--i:5;margin-top:8px">Why: you've cooked noodles four times this month and rated two of them 5. Under 30 min, like 11 of your last 14 cooks.</p>
      <div style="margin-top:28px;display:grid;gap:4px">
        <button class="btn primary">Cook this</button>
        <button class="btn">Something else</button>
      </div>
    </section>

    <section class="sect">
      <h3>Use soon <a href="#">Kitchen</a></h3>
      <div class="row"><span class="n">Spinach</span><span class="tag">2 days</span></div>
      <div class="row"><span class="n">Greek yogurt <span class="mono c2">500 g</span></span><span class="tag">tomorrow</span></div>
      <div class="row"><span class="n">Lime <span class="mono c2">½</span></span><span class="tag">today</span></div>
    </section>

    <section class="sect">
      <h3>Also possible</h3>
      <div class="row"><span class="n">Creamy pesto &amp; kale pasta<br><span class="cap c2">Uses the spinach</span></span><span class="mono sec c2">15 min</span><span class="mono sec">10 of 10</span></div>
      <div class="row"><span class="n">Butter bean curry<br><span class="cap c2">You cook this about every 10 days</span></span><span class="mono sec c2">35 min</span><span class="mono sec">10 of 10</span></div>
      <div class="row"><span class="n">Chicken, leek &amp; brown rice stir-fry</span><span class="mono sec c2">40 min</span><span class="mono sec">8 of 10</span></div>
    </section>

    <section class="sect">
      <h3>Your table <a href="#">Flat 4B</a></h3>
      <div class="row"><span class="n">Maya cooked Butter bean curry last night. <span class="c2">"Add lemon at the end."</span></span><span class="mono sec">10 of 10</span></div>
    </section>
  </div></div>

  ${TABBAR_F('tonight')}
  ${HOME_indicator}
</div>

${noteHTML('Tonight', [
  `Answers "what do I cook now" before the thumb moves. One pick, its fit, its reason, and the button. Two alternatives, the use-soon list and one line from your table come after, so the screen still works when the pick is wrong.`,
  `The yolk square next to "From your fridge" is the only colour on the screen. It marks the pick; it marks nothing else.`,
  `Fit is "9 of 10, 1 swap", never a percentage. The swap is named in the next line with the evidence ("you have two").`,
  `The "Why" line is written as evidence from the taste profile. Tapping it opens the profile sentence it came from.`,
], [
  ['empty', `No scan yet: "Scan a shelf and I'll pick tonight's dinner." Below it two equal choices: <b>Scan a shelf</b> and <b>Add by hand</b> — manual entry is first-class, not a fallback link. A sample pick sits under an "Example" label. The scan button gets a yolk ring for the first session only.`],
  ['sparse', `3 to 5 items in the kitchen: the pick stays honest, the fit line reads "4 recorded · you'd need noodles, eggs", and the primary button becomes "See what you'd need". Nothing pretends to be cookable that is not.`],
  ['nothing fits', `Best fit under 6 of 10: eyebrow reads "Closest with what you have", pick still shows, buttons become "Build a shopping list" and "Cook something saved". Never a fake "cook with 2 swaps".`],
  ['third rejection', `After the third "Something else" in one session the buttons become a constraint choice: Quicker · Different main · Less effort · Pick from a list. Rejections never become dislikes and never feed the taste profile.`],
  ['loading', `Local fit is instant. The "Why" line and table line can arrive late: layout reserves their height, one 2 px indeterminate line under the title, no shimmer.`],
  ['error', `Recommendation service down: show the last pick with "As of 6:10 pm" in the eyebrow. Use soon, Also possible and fit are computed on device and always render.`],
  ['mid-cook', `A cook in progress replaces the hero with a resume bar: dish, "Step 4 of 8", running timer, "Resume". Everything else unchanged.`],
  ['late', `After 21:30 the title reads "Tomorrow" and the pick is tomorrow's dinner. Use soon stays. There is no clock cutoff; the user can choose tonight's dish at any hour.`],
  ['question', `When the taste profile has a pattern at five observations, one line appears under the Why: "You've taken coriander out 5 times. Stop suggesting it? Yes / No". Asked once, never repeated.`],
], [
  ['enter', `Six blocks rise 6 px over 200 ms, 40 ms apart. Rows below do not stagger.`],
  ['press', `Buttons and rows scale to 0.97 in 120 ms.`],
  ['swap', `"Something else" crossfades the hero in 150 ms under a stable frame; the photo block keeps its size so nothing jumps.`],
  ['reduced', `Entrance becomes a 150 ms fade, no stagger.`],
])}`;

// ================================================================ KITCHEN
const kitchenCSS = `
.head{align-items:center;padding:10px 0 2px}
.head a{width:36px;height:36px;display:grid;place-items:center;color:var(--ink);margin-right:-8px}
.updated{padding-bottom:16px}
.sect{margin-top:24px}
.sect h3{margin-bottom:2px}
.sect h3 span{font-family:var(--mono)}
.row .n small{display:block}
.row .q{white-space:nowrap}
.row.unsure{border-top:1px dashed var(--rule2)}
.staples{padding:10px 0 4px}
.staples p{font-size:15px;line-height:22px}
.staples a{color:var(--ink2);text-decoration:none}
.addrow{margin-top:20px;display:flex;gap:8px}
.addrow a{flex:1;height:44px;border-radius:11px;display:flex;align-items:center;justify-content:center;gap:8px;box-shadow:inset 0 0 0 1px var(--rule2);color:var(--ink);text-decoration:none;font-size:15px;font-weight:600;transition:transform 120ms var(--out)}
.addrow a:active{transform:scale(.97)}
`;

const kitchenBody = (tabbar) => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head in" style="--i:0"><h1>Kitchen</h1><a href="#" aria-label="Search"><svg width="22" height="22" viewBox="0 0 22 22" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="9.5" cy="9.5" r="6.5"/><path d="M14.5 14.5 19 19"/></svg></a></header>
    <p class="updated cap c2 in" style="--i:0">Updated <span class="mono">2 h</span> ago from a scan · <span class="mono">31</span> things</p>

    <section class="sect in" style="--i:1">
      <h3>Use soon <span>3</span></h3>
      <div class="row"><i class="sq"></i><span class="n">Spinach<small>Creamy pesto &amp; kale pasta uses it</small></span><span class="tag">2 days</span></div>
      <div class="row"><i class="sq"></i><span class="n">Greek yogurt<small>Chicken &amp; tzatziki wraps, 20 min</small></span><span class="q">500 g</span><span class="tag">tomorrow</span></div>
      <div class="row"><i class="sq"></i><span class="n">Lime<small>Tonight's pick wants it</small></span><span class="q">½</span><span class="tag">today</span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Needs a look <span>2</span></h3>
      <div class="row unsure"><i class="sq d"></i><span class="n">Carrots<small>Added 28 Sept. Still there?</small></span><span class="chips" style="margin-top:0"><button class="chip" style="height:32px;padding:0 12px;border-radius:9px">Yes</button><button class="chip" style="height:32px;padding:0 12px;border-radius:9px">Gone</button></span></div>
      <div class="row unsure"><i class="sq d"></i><span class="n">Parmesan or pecorino<small>From today's scan</small></span><span class="chips" style="margin-top:0"><button class="chip" style="height:32px;padding:0 12px;border-radius:9px">Parm.</button><button class="chip" style="height:32px;padding:0 12px;border-radius:9px">Pec.</button></span></div>
    </section>

    <section class="sect in" style="--i:3">
      <h3>Fridge <span>14</span></h3>
      <div class="row"><i class="sq"></i><span class="n">Chicken thighs</span><span class="q">4</span><span class="q c3">today</span></div>
      <div class="row"><i class="sq"></i><span class="n">Eggs</span><span class="q">6</span><span class="q c3">today</span></div>
      <div class="row"><i class="sq"></i><span class="n">Pak choi</span><span class="q">2 heads</span><span class="q c3">today</span></div>
      <div class="row"><i class="sq"></i><span class="n">Spring onions</span><span class="q">1 bunch</span><span class="q c3">today</span></div>
      <div class="row"><i class="sq"></i><span class="n">Ginger</span><span class="q">1 piece</span><span class="q c3">today</span></div>
      <div class="row"><i class="sq"></i><span class="n">Red chilli</span><span class="q">3</span><span class="q c3">today</span></div>
      <div class="row"><i class="sq"></i><span class="n">Lemons</span><span class="q">2</span><span class="q c3">4 d</span></div>
      <div class="row"><i class="sq"></i><span class="n">Cheddar</span><span class="q">block</span><span class="q c3">9 d</span></div>
      <div class="row"><i class="sq"></i><span class="n">Butter</span><span class="q">open</span><span class="q c3">12 d</span></div>
      <div class="row"><i class="sq"></i><span class="n">Soy sauce</span><span class="q">open</span><span class="q c3">3 wk</span></div>
      <div class="row"><i class="sq"></i><span class="n">Milk, semi-skimmed</span><span class="q">1 L</span><span class="q c3">2 d</span></div>
    </section>

    <section class="sect in" style="--i:4">
      <h3>Freezer <span>4</span></h3>
      <div class="row"><i class="sq"></i><span class="n">Peas</span><span class="q">½ bag</span></div>
      <div class="row"><i class="sq"></i><span class="n">Chicken breasts</span><span class="q">2</span></div>
      <div class="row"><i class="sq"></i><span class="n">Butter bean curry<small>Leftovers, 28 Sept</small></span><span class="q">1 portion</span></div>
      <div class="row"><i class="sq"></i><span class="n">Bread</span><span class="q">½ loaf</span></div>
    </section>

    <section class="sect in" style="--i:5">
      <h3>Pantry <span>10</span></h3>
      <div class="staples"><p><span class="label">Assumed</span> <span class="c2">Olive oil, salt, pepper, rice, pasta, sesame oil, honey. Recipes count these as here.</span> <a href="#">Change</a></p></div>
      <div class="row"><i class="sq"></i><span class="n">Udon noodles</span><span class="q">2 packs</span></div>
      <div class="row"><i class="sq"></i><span class="n">Chickpeas, tinned</span><span class="q">3</span></div>
      <div class="row"><i class="sq"></i><span class="n">Butter beans, tinned</span><span class="q">2</span></div>
      <div class="row"><i class="sq"></i><span class="n">Coconut milk</span><span class="q">1</span></div>
    </section>

    <div class="addrow in" style="--i:5">
      <a href="#">${ICON.scan.replace('26" height="26','18" height="18')}Scan groceries</a>
      <a href="#">Add by name</a>
    </div>
  </div></div>

  ${tabbar}
  ${HOME_indicator}
</div>`;

const kitchenNote = noteHTML('Kitchen', [
  `The dense screen. 44 pt rows, hairlines, quantity and age in mono on the right. The eye should take in a shelf's worth without scrolling. No icons per ingredient: text is faster to scan than fifty tiny vegetables.`,
  `Order is by what needs a decision. Use soon first, each with the recipe that would use it (the warning is an action). Then "needs a look": items the app is unsure about, with the two answers inline so the truth model improves without a separate chore. Then the locations.`,
  `Row states by shape: filled square = confirmed, dashed = unconfirmed. Yolk tags carry the one meaning (attention now) and always sit next to a word.`,
  `Assumed staples are a sentence, not a list, because they are a policy rather than inventory. "Change" opens the checklist.`,
], [
  ['empty', `Never scanned: title, then "Scan a shelf to start. One shelf, straight on, works best." with Scan groceries and Add by name as equal choices. No sample data.`],
  ['stale', `Last scan over 7 days ago: the updated line turns to a row, "Last scan 9 days ago. Tonight's picks may be off." with Scan now. Nothing is auto-expired; the app asks instead via "needs a look".`],
  ['loading', `None. Kitchen is local. After a scan, new rows enter at the top of their section with the rise animation and "today" in the age column.`],
  ['error', `None for reading. A failed sync to the backup is a single line at the bottom, "Not backed up since Tuesday", never a modal.`],
  ['search', `Inline field replaces the title; sections collapse to matching rows; "Add 'tahini'" appears as the last result when nothing matches.`],
  ['edit', `Tap a row: inline stepper for quantity and a date for use-by, plus Remove. Swipe left: Remove. Swipe right: Used up (deducts and teaches the app the real rate).`],
  ['leftovers', `Cook-complete can save a portion to the freezer or fridge as a row named after the dish with its date; it shows up in Tonight with its reheat time and a use-by date; frozen portions say how long they need to thaw.`],
  ['receipts', `Scans observe; purchases add. A shelf scan reconciles ("Still 2 lemons?"). Only a receipt or "New groceries" adds stock.`],
], [
  ['answer', `Yes / Gone chip press: the row either loses its dashed state (150 ms crossfade) or slides out with the settle spring. Light haptic.`],
  ['used up', `Row slides right following the finger; release past 40% or a flick completes; the section count updates with the fade token.`],
  ['reduced', `Slides become fades; counts still update.`],
]);

// ================================================================ SCAN REVIEW
const scanCSS = `
.head{padding:8px 0 20px}
.head h1{font-size:28px;line-height:32px;font-weight:700;letter-spacing:-.015em}
.head p{margin-top:4px}
.sect h3{margin-bottom:4px}
.sect h3 span{font-family:var(--mono)}
.ask{padding:12px 0 14px;border-top:1px solid var(--rule)}
.ask:first-of-type{border-top:0}
.ask .top{display:flex;gap:12px;align-items:center}
.thumb{width:56px;height:56px;border-radius:10px;flex:none}
.ask .q{flex:1;font-size:15px;line-height:20px}
.ask .q b{font-weight:600}
.chips{margin-top:10px}
.dock{position:absolute;left:0;right:0;bottom:0;padding:12px 24px 34px;background:var(--paper);border-top:.5px solid var(--rule);z-index:9}
.dock .cap{text-align:center;margin-top:8px}
`;

const scanBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <div class="nav"><a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Retake</a><a href="#" class="c2">Photo</a></div>

    <header class="head in" style="--i:0">
      <h1>Found <span class="mono">14</span> things</h1>
      <p class="sec c2"><span class="mono">11</span> look right. <span class="mono">3</span> need you.</p>
    </header>

    <section class="sect in" style="--i:1">
      <h3>Need you <span>3</span></h3>

      <div class="ask">
        <div class="top"><div class="photo thumb"></div><div class="q">Leafy, pale stems, top shelf.</div></div>
        <div class="chips"><button class="chip on">Pak choi</button><button class="chip">Chinese cabbage</button><button class="chip quiet">Neither</button></div>
      </div>

      <div class="ask">
        <div class="top"><div class="photo thumb"></div><div class="q">Small red chillies in the door.</div></div>
        <div class="chips"><button class="chip">Red chilli</button><button class="chip">Bird's-eye chilli</button><button class="chip quiet">Neither</button></div>
      </div>

      <div class="ask">
        <div class="top"><div class="photo thumb"></div><div class="q">Hard cheese, wedge, wrapped.</div></div>
        <div class="chips"><button class="chip">Parmesan</button><button class="chip">Pecorino</button><button class="chip quiet">Neither</button></div>
      </div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Looks right <span>11</span></h3>
      <div class="row"><i class="sq"></i><span class="n">Chicken thighs</span><span class="q">4</span></div>
      <div class="row"><i class="sq"></i><span class="n">Eggs</span><span class="q">6</span></div>
      <div class="row"><i class="sq"></i><span class="n">Greek yogurt</span><span class="q">500 g</span></div>
      <div class="row"><i class="sq"></i><span class="n">Spinach</span><span class="q">1 bag</span></div>
      <div class="row"><i class="sq"></i><span class="n">Spring onions</span><span class="q">1 bunch</span></div>
      <div class="row"><i class="sq"></i><span class="n">Ginger</span><span class="q">1 piece</span></div>
      <div class="row"><i class="sq"></i><span class="n">Udon noodles</span><span class="q">2 packs</span></div>
      <div class="row"><i class="sq"></i><span class="n">Soy sauce</span><span class="q">open</span></div>
      <div class="row"><i class="sq"></i><span class="n">Lemons</span><span class="q">2</span></div>
      <div class="row"><i class="sq"></i><span class="n">Carrots</span><span class="q">3</span></div>
      <div class="row"><i class="sq"></i><span class="n">Cheddar</span><span class="q">block</span></div>
    </section>

    <section class="sect in" style="--i:3">
      <div class="row"><svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 4v12M4 10h12"/></svg><span class="n">Missed something? Add by name</span></div>
    </section>
  </div></div>

  <div class="dock">
    <button class="btn primary">Add 14 to kitchen</button>
    <p class="cap c2">Tonight's pick updates when you do.</p>
  </div>
  ${HOME_indicator}
</div>

${noteHTML('Scan review', [
  `The screen asks only the questions the camera could not answer, and asks them first. Three "need you" rows, each with the two likely answers as chips and a thumbnail crop of what it saw. The eleven sure rows are a skim list below; tapping one edits, swiping removes.`,
  `The count in the title is mono because it is a number the user checks against the shelf. "14 things" is the whole summary; there is no confidence percentage anywhere.`,
  `Selected chips use yolk-soft with a yolk stroke: the selection meaning of the one accent. Unanswered rows are allowed; the button still works and unanswered items go to Kitchen's "needs a look" queue rather than blocking here.`,
  `The primary button names what happens and the count. The caption under it says why it matters. The dock is flat paper with a hairline; nothing glassy sits over a list you are correcting.`,
], [
  ['analysing', `Photo at top, 4:5. Title reads "Looking". One 2 px indeterminate line under it. Rows appear as recognised, each entering with the 200 ms rise; no scanning laser, no shimmer.`],
  ['all sure', `The "need you" section is absent. Title: "Found 9 things", subtitle: "All look right." Button unchanged.`],
  ['nothing', `"Nothing I recognise. Try one shelf, straight on, with the door light on." Buttons: Retake, Add by name.`],
  ['dark/blur', `Detected before upload: "Too dark to read" or "Too blurry" with Retake. Shown over the photo, not as an alert.`],
  ['error', `Recognition request failed: photo stays, "Couldn't read this photo. Try again or add by name." Retry keeps the photo; no re-capture required.`],
  ['receipt', `Same screen. Rows carry the receipt line text in caption under the normalised name ("ORG SPNCH 200G"). Quantities come from the receipt; scans observe, purchases add.`],
  ['plate', `Camera saw a cooked dish, not a shelf: a one-line switch at the top, "This looks like a meal. Log it instead?" with Yes / No. Never auto-switches.`],
  ['duplicates', `Item already in Kitchen: a shelf scan observes, it never adds. The row reads "Still 2?" with Yes / "Bought more". Only a receipt or "New groceries" adds stock.`],
], [
  ['chip', `Background and stroke crossfade 150 ms; press 0.97. No layout shift when selected.`],
  ['remove', `Swipe follows the finger; release past 40% or a flick dismisses with the settle spring; the row below slides up in 200 ms.`],
  ['confirm', `Button press, medium haptic, push to Tonight. No celebration.`],
])}`;

// ================================================================ RECIPE
const recipeCSS = `
.title{font-size:32px;line-height:34px;font-weight:700;letter-spacing:-.02em;margin:8px 0 6px}
.meta{display:flex;gap:14px;flex-wrap:wrap}
.fitblock{margin-top:22px;padding:14px 0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule);display:flex;justify-content:space-between;align-items:center}
.sect h3{align-items:center}
.step{display:inline-flex;align-items:center;gap:0;box-shadow:inset 0 0 0 1px var(--rule2);border-radius:8px;height:28px;font-weight:400;color:var(--ink2)}
.step b{width:28px;display:grid;place-items:center;font-weight:500;font-size:17px;color:var(--ink);cursor:pointer}
.step span{padding:0 6px;font-family:var(--mono);font-size:13px;color:var(--ink2)}
.sq{margin-top:6px}
.swap{margin-top:6px;display:inline-flex;align-items:center;gap:8px;padding:4px 8px 4px 6px;border-radius:8px;background:var(--yolk-soft);color:var(--yolk-ink);font-size:13px;line-height:16px}
.swap b{font-weight:600}
.why .row{align-items:center}
.why .q{color:var(--ink2);font-size:13px}
.steps .row{gap:14px;align-items:flex-start}
.steps .num{font-family:var(--mono);font-size:13px;color:var(--ink2);width:18px;flex:none;line-height:24px}
.nut{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:6px}
.nut div{padding:10px 0;border-top:1px solid var(--rule)}
.nut b{display:block;font-family:var(--mono);font-size:17px;font-weight:500;line-height:22px}
.nut small{font-size:13px;color:var(--ink2)}
.bar{height:3px;background:var(--rule);margin-top:8px;border-radius:2px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ink)}
.notes .row{align-items:center}
.dock{position:absolute;left:16px;right:16px;bottom:22px;z-index:10;display:flex;gap:8px;padding:8px;border-radius:40px;background:var(--bar);backdrop-filter:blur(28px) saturate(1.6);-webkit-backdrop-filter:blur(28px) saturate(1.6);box-shadow:inset 0 0 0 .5px var(--barline),0 10px 28px -10px var(--barshadow)}
.dock .btn{height:48px;border-radius:24px;flex:1}
`;

const recipeBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <div class="nav"><a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Tonight</a><a href="#" class="c2">Save</a></div>

    <h1 class="title in" style="--i:0">Ginger chicken udon noodles</h1>
    <p class="meta mono sec c2 in" style="--i:1"><span>25 min</span><span>8 steps</span><span>2 timers</span><span>520 kcal</span></p>
    <div class="photo in" style="--i:2;aspect-ratio:3/2;margin-top:16px"><span>photo: overhead, daylight, 3:2</span></div>

    <div class="fitblock in" style="--i:3">
      <div>
        ${fit10(9)}
        <p class="sec" style="margin-top:6px">Fit to your kitchen</p>
      </div>
      <div style="text-align:right"><span class="mono" style="font-weight:500">9 of 10</span><br><span class="cap c2">1 swap</span></div>
    </div>

    <section class="sect in" style="--i:4">
      <h3>Ingredients <span class="step"><b>−</b><span>2 servings</span><b>+</b></span></h3>
      <div class="row"><i class="sq"></i><span class="n">Chicken thighs, skinless</span><span class="q">300 g</span></div>
      <div class="row"><i class="sq"></i><span class="n">Udon noodles</span><span class="q">300 g</span></div>
      <div class="row"><i class="sq"></i><span class="n">Ginger, grated</span><span class="q">25 g</span></div>
      <div class="row"><i class="sq"></i><span class="n">Spring onions</span><span class="q">4</span></div>
      <div class="row"><i class="sq"></i><span class="n">Pak choi</span><span class="q">2 heads</span></div>
      <div class="row"><i class="sq"></i><span class="n">Red chilli</span><span class="q">1</span></div>
      <div class="row"><i class="sq o"></i><span class="n">Lime<br><span class="swap"><b>Swap</b> Lemon, you have 2 · a little sharper, less floral</span></span><span class="q">1</span></div>
      <div class="row"><i class="sq a"></i><span class="n">Soy sauce <span class="cap c2">assumed</span></span><span class="q">2 tbsp</span></div>
      <div class="row"><i class="sq a"></i><span class="n">Sesame oil <span class="cap c2">assumed</span></span><span class="q">1 tbsp</span></div>
      <div class="row"><i class="sq a"></i><span class="n">Honey <span class="cap c2">assumed</span></span><span class="q">1 tsp</span></div>
    </section>

    <section class="sect why in" style="--i:5">
      <h3>Why it fits you <a href="#" class="r" style="text-decoration:none;font-family:inherit">Your taste</a></h3>
      <div class="row"><span class="n sec">Noodles: you've cooked 4 this month, rated 2 of them 5.</span><span class="q mono">4 cooks</span></div>
      <div class="row"><span class="n sec">Under 30 minutes, like 11 of your last 14.</span><span class="q mono">11 of 14</span></div>
      <div class="row"><span class="n sec">No coriander. You take it out every time.</span><span class="q mono">5 of 5</span></div>
    </section>

    <section class="sect steps in" style="--i:5">
      <h3>Steps <span class="r mono">8 · 2 timers</span></h3>
      <div class="row"><span class="num">1</span><span class="n">Slice the chicken into 2 cm strips. Grate the ginger, slice the chilli and spring onions, halve the pak choi.</span></div>
      <div class="row"><span class="num">2</span><span class="n">Mix soy, honey, half the ginger and 3 tbsp water in a cup.</span></div>
      <div class="row"><span class="num">3</span><span class="n">Heat the oil in a wok until it just smokes. Fry the chicken 4 minutes without moving it, then 2 more, tossing. Check the thickest piece reads 74 °C with a thermometer. <span class="mono cap c2">timer 4:00, 2:00</span></span></div>
      <div class="row"><span class="num c3">4</span><span class="n c2">Show all 8</span></div>
    </section>

    <section class="sect in" style="--i:5">
      <h3>Per serving</h3>
      <div class="nut">
        <div><b>520</b><small>kcal</small></div>
        <div><b>38 g</b><small>protein</small><div class="bar"><i style="width:76%"></i></div></div>
        <div><b>54 g</b><small>carbs</small><div class="bar"><i style="width:54%"></i></div></div>
        <div><b>14 g</b><small>fat</small><div class="bar"><i style="width:28%"></i></div></div>
      </div>
    </section>

    <section class="sect notes in" style="--i:5">
      <h3>From <span class="mono">212</span> cooks</h3>
      <div class="row"><span class="n sec">Swapped lime for lemon</span><span class="q mono">31%</span></div>
      <div class="row"><span class="n sec">"Add the ginger late or it burns."</span><span class="q mono">41</span></div>
      <div class="row"><span class="n sec">"Double the pak choi."</span><span class="q mono">18</span></div>
    </section>
  </div></div>

  <div class="dock">
    <button class="btn">Just the steps</button>
    <button class="btn primary">Cook with LeChef</button>
  </div>
  ${HOME_indicator}
</div>

${noteHTML('Recipe', [
  `A document, not a stack of cards. Title, mono meta, photo, then the fit block as the one framed element because it is the app's promise. Ingredients are quantity rows: filled square = on hand, hollow = missing, outlined = assumed staple. The one missing row carries its swap inline in yolk-soft, with the evidence ("you have 2") and the difference ("a little sharper, less floral") — a swap never promises "no change".`,
  `"Why it fits you" is three sentences with evidence counts; the heading links to the taste profile so every claim is inspectable and correctable.`,
  `Step 3 carries the USDA check ("74 °C with a thermometer") because doneness for poultry is a thermometer test, never colour or time alone. The timer says when to check.`,
  `Macros are three ink bars of different lengths, not three colours. Cook notes show only because this recipe has 212 cooks; under 10 the section reads "Be the first to leave a note". The 31% is what cooks did, not a fit or taste score.`,
  `The floating dock is the one glass element on a content screen (system glassEffect capsule). "Cook with LeChef" enters cook mode; "Just the steps" enters the same screen with voice off.`,
], [
  ['no photo', `Photo block absent; the title stays at 32 and the fit block moves up. Nothing reads as missing.`],
  ['loading', `Everything above cook notes is local and instant. Notes reserve 3 rows and show one 2 px line; if they take over 2 s, the section collapses.`],
  ['offline', `Cook notes section hidden. Fit, swaps, steps, macros all render from device data.`],
  ['missing 3+', `Primary button becomes "Cook with 3 swaps"; a secondary row above the dock offers "Add 3 to shopping list". Cooking is never blocked.`],
  ['generated', `LeChef-made recipe: a caption under the title reads "Made for your fridge · not cooked by anyone yet". No cook notes. It stays private. A 4+ rating can nominate the version you actually cooked for review; it enters the catalog only after rights, safety and a human test cook.`],
  ['servings', `Stepper rescales quantities in place (150 ms crossfade on the mono column, no layout shift). Steps with quantities update too; the changed step gets a caption "changed for 4".`],
  ['swap popover', `Tapping the swap chip opens a popover anchored to that row (transform-origin at the chip) with up to 2 alternatives from the substitution table and "I have it, actually". Every swap rechecks all eaters' allergens, including compound ones (soy sauce contains wheat).`],
  ['error', `Recipe failed to load from catalog: "This recipe didn't load. Try again." with Retry; title still shows from the list cache.`],
], [
  ['push', `From Tonight, the title and photo keep their position (matched geometry); the rest rises in 200 ms, 40 ms apart, capped at six blocks.`],
  ['dock', `Rises with the sheet curve over 320 ms after the page settles; hides on scroll down, returns on scroll up.`],
  ['to cook', `Paper fades to hob over 320 ms with the first step already in place: the one deliberate material change in the app.`],
])}`;

// ================================================================ COOK (hob)
const cookCSS = `
.screen{padding:54px 24px 0;display:flex;flex-direction:column}
.top{display:flex;justify-content:space-between;align-items:center;height:44px}
.top .x{width:44px;height:44px;margin-right:-10px;display:grid;place-items:center;color:var(--ink2)}
.prog{display:flex;gap:4px;margin-top:10px}
.prog i{flex:1;height:3px;border-radius:2px;background:var(--rule2)}
.prog i.d{background:var(--ink)}
.prog i.c{background:var(--yolk)}
.stepno{margin-top:26px;display:flex;align-items:baseline;gap:10px}
.stepno b{font-family:var(--mono);font-size:13px;font-weight:500;color:var(--yolk)}
.step{font-size:26px;line-height:32px;font-weight:600;letter-spacing:-.01em;margin-top:8px}
.step em{font-style:normal;background:var(--yolk-soft);color:var(--yolk);padding:0 4px;border-radius:4px;font-family:var(--mono);font-size:24px;font-weight:500}
.timers{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:28px}
.tile{position:relative;border-radius:14px;background:var(--card);box-shadow:inset 0 0 0 .5px var(--photo-line);padding:14px 16px;min-height:112px;display:flex;flex-direction:column;justify-content:space-between;transition:transform 120ms var(--out)}
.tile:active{transform:scale(.97)}
.tile .t{display:flex;justify-content:space-between;align-items:center}
.tile .d{font-family:var(--mono);font-size:44px;line-height:44px;font-weight:500;letter-spacing:-.02em;color:var(--yolk);font-variant-numeric:tabular-nums}
.tile.add{justify-content:center;align-items:center;color:var(--ink2);box-shadow:inset 0 0 0 1px var(--rule2);background:transparent;gap:6px}
.ring{width:22px;height:22px;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:2.5}
.ring .bg{stroke:var(--rule2)}
.ring .fg{stroke:var(--yolk);stroke-dasharray:56.5;stroke-dashoffset:0;animation:drain 102s linear forwards}
@keyframes drain{to{stroke-dashoffset:56.5}}
.chef{margin-top:28px;padding-top:16px;border-top:1px solid var(--rule)}
.chef .label{color:var(--ink2);margin-bottom:6px}
.chef p{font-size:17px;line-height:24px}
.chef .acts{display:flex;gap:8px;margin-top:12px}
.chef .acts .btn{height:40px;border-radius:10px;box-shadow:inset 0 0 0 1px var(--rule2);font-size:15px;width:auto}
.spacer{flex:1}
.voice{display:flex;align-items:center;gap:12px;padding:12px 0}
.bars{display:flex;gap:3px;align-items:center;height:22px;width:34px}
.bars i{width:4px;border-radius:2px;background:var(--yolk);height:6px;animation:amp 900ms ease-in-out infinite alternate}
.bars i:nth-child(2){animation-delay:120ms}.bars i:nth-child(3){animation-delay:240ms}.bars i:nth-child(4){animation-delay:360ms}.bars i:nth-child(5){animation-delay:60ms}
@keyframes amp{from{height:5px}to{height:20px}}
.voice .hint{color:var(--ink2);font-size:13px;line-height:16px}
.voice .hint b{color:var(--ink);font-weight:500}
.next{height:64px;border-radius:16px;background:var(--ink);color:var(--btn-ink);font-size:17px;display:flex;align-items:center;justify-content:space-between;padding:0 20px;font-weight:600;transition:transform 120ms var(--out);border:0;width:100%;font-family:inherit;cursor:pointer}
.next:active{transform:scale(.97)}
.next span{font-weight:400;color:var(--ink2);font-size:15px;text-align:left;flex:1;margin-left:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bottom{padding-bottom:40px}
.back{display:block;text-align:center;color:var(--ink2);font-size:15px;line-height:20px;padding:12px 0 4px}
@media (prefers-reduced-motion:reduce){.bars i{animation:none!important}.ring .fg{animation:none!important}}
`;

const cookBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen">
    <div class="top in" style="--i:0">
      <div><div class="label">Ginger chicken udon noodles</div><div class="cap c2 mono">Step 4 of 8 · 11 min in</div></div>
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
      <div class="tile add in" style="--i:3"><svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 4v12M4 10h12"/></svg><span class="sec">Timer</span></div>
    </div>

    <div class="chef in" style="--i:4">
      <div class="label">LeChef</div>
      <p>Check the thickest piece of chicken: 74 °C in the middle. Want a 2 min timer to check again?</p>
      <div class="acts"><button class="btn">Show it</button><button class="btn c2">No</button></div>
    </div>

    <div class="spacer"></div>

    <div class="bottom in" style="--i:5">
      <div class="voice">
        <div class="bars" aria-label="Listening"><i></i><i></i><i></i><i></i><i></i></div>
        <div class="hint"><b>Listening.</b> Say next, back, repeat, show, or timer 3 minutes.</div>
      </div>
      <button class="next">Next<span>5 · Stir in the sauce</span><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 2l8 8-8 8"/></svg></button>
      <a class="back" href="#">Back</a>
    </div>
  </div>
  ${HOME_indicator}
</div>

${noteHTML('Cook with LeChef — the hob', [
  `Matte black, paper-white text, yolk for the two things that are live: the current step marker and running timers. No glass, no gradient, no transcript on screen. Cook mode ignores the system setting; it is its own palette, not "dark mode".`,
  `The step is the largest text in the app (26/32) because it is read from arm's length. Quantities and times inside the step are mono on a yolk-soft block so they can be found without reading the sentence.`,
  `Timers are tiles, not a list: 44 pt mono digits, a thin ring that drains linearly, tap to pause, long-press to remove. "Timer" adds one; by voice, "timer 3 minutes" adds one named after the current step.`,
  `LeChef speaks in one line, only when it has something step-relevant, with at most two answers. "Show it" opens the camera for a single look; the camera is never on by itself. A look describes what a picture can show and never gives a safety verdict.`,
  `Next is 64 pt and shows the next step's name so the user can decide without pressing. Back is a text link because it is rare.`,
], [
  ['voice off', `"Just the steps" mode or mic denied: the bars become a static mic-slash glyph, hint reads "Tap to talk". Everything else identical. Timers and Next are unchanged.`],
  ['offline', `Live session drops: a one-line banner above the voice row, "LeChef is offline. Steps and timers still work." Voice falls back to on-device recognition for the five words. The LeChef block hides.`],
  ['looking', `"Show it" replaces the LeChef block with a 4:3 viewfinder for up to 3 s and the caption "Looking at the pan". Then the answer replaces it, limited to what a picture can show: "Browning looks even. I can't tell doneness from a photo, check 74 °C with a thermometer." Never a safety verdict.`],
  ['timer done', `The tile fills yolk, digits read 0:00 in ink, rigid haptic, sound. LeChef says what to do next in one line. The fill fades after the user taps the tile or says "next" or "repeat" (the vocabulary stays five words).`],
  ['adapt', `A quantity changed (one breast, not two): amounts rescale and the affected step shows a caption "Changed: 1 breast, same check: 74 °C" in yolk-ink. Times only change when a rule supports it (thickness, pan size), otherwise the step says to check rather than trust the timer. Never silent.`],
  ['remember', `At step 7, if the taste profile has a note for this recipe: "Last time you said too salty. I've cut the soy to 1½ tbsp." Shown once.`],
  ['interrupted', `App killed or phone locked: reopening returns to this step with timers still counting (they run on device, scheduled as notifications).`],
  ['complete', `After step 8: paper returns (320 ms), dish name, "Cooked in 27 min", kcal counting up once, a 1 to 5 rating row, "One line for next time" by voice or keyboard, optional photo, "Done". Nothing else. No confetti.`],
  ['leave', `The X asks once: "Leave this cook? Timers keep running." Leave / Stay.`],
], [
  ['next', `Step text crossfades with a 6 px rise in 200 ms; the progress segment fills with the fade token. Said by voice ten times a cook, so never slower.`],
  ['timer add', `Tile enters from scale 0.96 with the move spring; the grid reflows with a transition, not a keyframe, so a second add mid-animation retargets.`],
  ['ring', `Linear. A ring that eases is lying about time.`],
  ['voice bars', `In the app they are driven by input amplitude. The mock's loop is a stand-in; a muted mic shows a static shape, never a fake pulse.`],
  ['reduced', `Step change is a 150 ms fade; ring still drains; bars still follow amplitude.`],
])}`;

// ================================================================ TASTE PROFILE
const tasteCSS = `
.head{display:block;padding:8px 0 20px}
.head h1{font-size:28px;line-height:32px;font-weight:700;letter-spacing:-.015em}
.head p{margin-top:6px}
.sect h3 span{font-family:inherit}
.ts{padding:12px 0;border-top:1px solid var(--rule);transition:opacity 150ms ease}
.ts:first-of-type{border-top:0}
.ts .s{display:flex;gap:12px;align-items:flex-start}
.ts .s p{flex:1}
.ts .ev{font-family:var(--mono);font-size:13px;line-height:24px;color:var(--ink2);white-space:nowrap}
.ts .ctl{display:flex;gap:8px;margin-top:8px;align-items:center}
.sb{height:32px;padding:0 12px;border-radius:9px;border:0;background:transparent;box-shadow:inset 0 0 0 1px var(--rule2);font:inherit;font-size:15px;font-weight:500;color:var(--ink);cursor:pointer;transition:transform 120ms var(--out),background 150ms ease,box-shadow 150ms ease}
.sb:active{transform:scale(.97)}
.sb.on{background:var(--yolk-soft);box-shadow:inset 0 0 0 1px var(--yolk);color:var(--yolk-ink)}
.sb.q{box-shadow:none;color:var(--ink2);padding:0 6px}
.ts.off{opacity:.55}
.ts.off p{text-decoration:line-through;text-decoration-color:var(--rule2)}
.ts .state{font-size:13px;line-height:16px;color:var(--ink2);display:flex;align-items:center;gap:6px}
.ts .state i{width:8px;height:8px;border-radius:2px;background:var(--yolk)}
.chips{padding-top:8px;margin-top:0}
.mem{padding:12px 0;border-top:1px solid var(--rule)}
.mem:first-of-type{border-top:0}
.mem .t{display:flex;justify-content:space-between;gap:12px}
.mem .t b{font-weight:600}
.mem .t a{color:var(--ink2);text-decoration:none;font-size:15px}
.mem q{display:block;margin-top:2px;color:var(--ink2);font-size:15px;line-height:20px;quotes:"\\201C" "\\201D"}
.foot{margin-top:40px;padding-top:20px;border-top:1px solid var(--rule);display:grid;gap:14px}
.foot a{text-decoration:none;font-size:15px}
`;

const tasteBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <div class="nav"><a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Cookbook</a></div>

    <header class="head in" style="--i:0">
      <h1>Your taste</h1>
      <p class="sec c2">Written from <span class="mono">23</span> cooks since 14 Sept. Nothing here comes from outside the app.</p>
    </header>

    <section class="sect in" style="--i:1">
      <h3>What I've noticed <span>Tap Right or Wrong</span></h3>

      <div class="ts">
        <div class="s"><p>You cook on weeknights, mostly under 30 minutes.</p><span class="ev">18 of 23</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>

      <div class="ts">
        <div class="s"><p>You reach for chicken thighs, chickpeas and noodles.</p><span class="ev">9 · 6 · 7</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>

      <div class="ts">
        <div class="s"><p>You skip coriander.</p><span class="ev">5 of 5</span></div>
        <div class="ctl"><button class="sb on">Right</button><span class="state"><i></i>Confirmed 3 Oct. Never suggested.</span></div>
      </div>

      <div class="ts">
        <div class="s"><p>You like it hot. Three dishes marked "hot" got a 5 from you.</p><span class="ev">3 of 3</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>

      <div class="ts off">
        <div class="s"><p>You eat late, after 9 pm.</p><span class="ev">4 of 23</span></div>
        <div class="ctl"><span class="state">Won't use this.</span><button class="sb q">Undo</button></div>
      </div>

      <div class="ts">
        <div class="s"><p>You come back to Butter bean curry about every 10 days.</p><span class="ev">3 cooks</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>

      <div class="ts">
        <div class="s"><p>You've never cooked fish here.</p><span class="ev">0 of 23</span></div>
        <div class="ctl"><button class="sb">Suggest some</button><button class="sb">Not interested</button></div>
      </div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Never suggest</h3>
      <div class="chips">
        <span class="chip">Coriander<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 3l8 8M11 3 3 11"/></svg></span>
        <span class="chip">Blue cheese<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 3l8 8M11 3 3 11"/></svg></span>
        <span class="chip">Shellfish <span class="cap c2">allergy</span></span>
        <span class="chip"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 3v10M3 8h10"/></svg>Add</span>
      </div>
    </section>

    <section class="sect in" style="--i:3">
      <h3>LeChef remembers <span class="mono">4</span></h3>
      <div class="mem"><div class="t"><b>Butter bean curry</b><a href="#">Forget</a></div><q>Too salty. Low-sodium stock next time.</q><span class="cap c2 mono">3 Oct</span></div>
      <div class="mem"><div class="t"><b>Ginger chicken udon noodles</b><a href="#">Forget</a></div><q>Lemon instead of lime worked.</q><span class="cap c2 mono">28 Sept</span></div>
      <div class="mem"><div class="t"><b>Chicken jalfrezi</b><a href="#">Forget</a></div><q>Needs another 10 min on the onions.</q><span class="cap c2 mono">21 Sept</span></div>
      <div class="mem"><div class="t"><b>Creamy pesto &amp; kale pasta</b><a href="#">Forget</a></div><q>Double the kale.</q><span class="cap c2 mono">16 Sept</span></div>
    </section>

    <section class="sect in" style="--i:4">
      <h3>What you told me at setup <span><a href="#" style="color:inherit;text-decoration:none">Edit</a></span></h3>
      <p class="sec" style="padding-top:8px">No shellfish · cooking for 2 · metric</p>
    </section>

    <div class="foot in" style="--i:5">
      <a href="#" class="c2">Export everything I know about you</a>
      <a href="#" style="color:var(--err)">Forget everything</a>
    </div>
  </div></div>
  ${HOME_indicator}
</div>

${noteHTML('Your taste', [
  `The whole learning system in one readable page: sentences the app would say out loud, each with the count it is based on and a Right / Wrong control. No sliders, no percentages, no "personality" labels.`,
  `Three row states. Default: Right / Wrong. Confirmed: the Right button is held in yolk-soft and the row says when, in the same words the app will act on ("Never suggested"). Rejected: the row dims, the sentence is struck through, and "Won't use this" sits next to Undo. Nothing is deleted on Wrong; it is excluded from recommendations and kept so the app does not re-learn it next week.`,
  `"Don't ask again" and "This is wrong" are different decisions and the page keeps them different: a weak inference expires, an explicit rejection does not.`,
  `"Never suggest" is the only list the user writes directly. Allergies from setup appear here too, labelled, and cannot be removed from this page (they are edited in setup).`,
  `"LeChef remembers" is the cook-complete notes, verbatim, with Forget per line. These are the lines LeChef reads back mid-cook.`,
], [
  ['new', `Fewer than 3 cooks: the "What I've noticed" section is one sentence, "Cook three things and I'll start writing this." Setup answers and Never suggest still show.`],
  ['thin', `3 to 9 cooks: sentences use hedged language ("You seem to…") and counts; the fish row and the repeat row do not appear until 10 cooks.`],
  ['loading', `None. The profile is on device. Learning runs on the phone; nothing about taste leaves it.`],
  ['error', `None for reading. If a Right / Wrong fails to persist, the control reverts and a one-line "Didn't save. Try again." appears under the row.`],
  ['question pending', `A pattern the app has asked about on Tonight but the user has not answered shows here with the two buttons highlighted by a yolk square at the leading edge.`],
  ['forget all', `Confirmation sheet: "Forget 23 cooks of learning? Setup answers and allergies stay." Forget / Keep. On Forget, the page returns to the "new" state. Changing your mind never requires a full reset.`],
  ['export', `Share sheet with a JSON of sentences, counts, source cook IDs, notes and setup answers.`],
], [
  ['right/wrong', `Button fill crossfades 150 ms, light haptic. On Wrong the row opacity drops to 0.55 over 150 ms; no height change, no removal.`],
  ['undo', `Same crossfade back. Nothing bounces.`],
  ['forget line', `Row slides out with the settle spring and the list closes the gap with a transition.`],
])}`;

// ================================================================ EXPLORE
const exploreCSS = `
.head{padding:10px 0 12px}
.search{display:flex;align-items:center;gap:8px;height:44px;border-radius:10px;box-shadow:inset 0 0 0 1px var(--rule2);padding:0 12px;font-size:15px;color:var(--ink3);margin:0 0 12px;white-space:nowrap;overflow:hidden}
.fchips{display:flex;gap:8px;flex-wrap:wrap}
.fchip{height:32px;padding:0 12px;border-radius:9px;font-size:15px;font-weight:500;box-shadow:inset 0 0 0 1px var(--rule2);background:transparent;border:0;font-family:inherit;color:var(--ink);cursor:pointer;transition:transform 120ms var(--out),background 150ms ease,box-shadow 150ms ease}
.fchip:active{transform:scale(.97)}
.fchip.on{background:var(--yolk-soft);color:var(--yolk-ink);box-shadow:inset 0 0 0 1px var(--yolk)}
.rank{padding:10px 0 2px}
.ecard{margin-top:14px;border-radius:14px;box-shadow:inset 0 0 0 .5px var(--cardline);padding:12px;background:var(--card);display:flex;gap:10px 12px;align-items:flex-start;flex-wrap:wrap;transition:transform 120ms var(--out)}
.ecard:active{transform:scale(.985)}
.ecard .ephoto{width:88px;height:88px;flex:none;margin:0}
.ecard .emid{flex:1;min-width:0}
.ename{font-size:16px;line-height:21px;font-weight:600}
.esrc{margin-top:2px}
.ebtm{flex-basis:100%;display:flex;justify-content:space-between;align-items:center;gap:10px;margin-top:2px}
.ebtm .cap{flex:1;min-width:0}
.efit{margin-top:8px}
.sect h3 .r{font-family:var(--mono)}
`;

const exploreBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head in" style="--i:0"><h1>Explore</h1><a href="#" aria-label="Saved recipes"><svg width="20" height="22" viewBox="0 0 20 22" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 2.5h12a1.5 1.5 0 0 1 1.5 1.5v15.5L10 15.5 2.5 19.5V4A1.5 1.5 0 0 1 4 2.5z"/></svg></a></header>

    <div class="search in" style="--i:0" role="search"><svg width="18" height="18" viewBox="0 0 22 22" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="9.5" cy="9.5" r="6.5"/><path d="M14.5 14.5 19 19"/></svg>Search the catalog and published recipes</div>
    <div class="fchips in" style="--i:1">
      <button class="fchip">All</button><button class="fchip on">Under 30 min</button><button class="fchip">Budget</button><button class="fchip">Veg</button><button class="fchip">No shellfish</button>
    </div>
    <p class="rank cap c2 in" style="--i:1">Ranked by what you can cook now. Then newest.</p>

    <section class="sect in" style="--i:2">
      <h3>Can cook now <span class="r">3</span></h3>

      <article class="ecard">
        <div class="photo ephoto"><span>1:1</span></div>
        <div class="emid">
          <div class="ename">Spinach &amp; lemon orzo with feta</div>
          <div class="esrc cap c2">By Priya · cooked by 37</div>
          <div class="efit">${fit10(10)}</div>
        </div>
        <div class="ebtm">
          <span class="cap c2">You have everything</span>
          <button class="btn primary small">Cook this</button>
        </div>
      </article>

      <article class="ecard">
        <div class="photo ephoto"><span>1:1</span></div>
        <div class="emid">
          <div class="ename">Butter bean curry</div>
          <div class="esrc cap c2">From the catalog · cooked by 94</div>
          <div class="efit">${fit10(9)}</div>
        </div>
        <div class="ebtm">
          <span class="cap c2">Missing lime · <span style="white-space:nowrap">1 swap</span></span>
          <button class="btn ghost small">Cook with swap</button>
        </div>
      </article>

      <article class="ecard">
        <div class="photo ephoto"><span>1:1</span></div>
        <div class="emid">
          <div class="ename">Egg-fried noodles with beansprouts</div>
          <div class="esrc cap c2">By Dev · new this week</div>
          <div class="efit">${fit10(8)}</div>
        </div>
        <div class="ebtm">
          <span class="cap c2">Missing beansprouts, chilli oil · <span style="white-space:nowrap">2 swaps</span></span>
          <button class="btn ghost small">Cook with swaps</button>
        </div>
      </article>
    </section>

    <section class="sect in" style="--i:3">
      <h3>Rest of the catalog <span class="r">400 reviewed</span></h3>
      <div class="row"><span class="n">Chicken, leek &amp; brown rice stir-fry</span><span class="q">40 min</span><span class="q" style="color:var(--ink)">8 of 10</span></div>
      <div class="row"><span class="n">Chicken &amp; tzatziki wraps</span><span class="q">20 min</span><span class="q" style="color:var(--ink)">7 of 10</span></div>
      <div class="row"><span class="n">Red lentil dal</span><span class="q">30 min</span><span class="q" style="color:var(--ink)">7 of 10</span></div>
    </section>
  </div></div>

  ${TABBAR_F('cookbook')}
  ${HOME_indicator}
</div>

${noteHTML('Explore', [
  `Published community recipes and the catalog in one ranked list. The rank is the viewer's own fit line, computed on device from the Kitchen ledger, and it sits on every card: "9 of 10 · 1 swap", never a percentage. Search and filters work as everywhere else.`,
  `No like counts, no follower counts, no comments, no ranking by engagement. The response to a card is to cook it or save it. A recipe may say "cooked by 37" — distinct cooks, opted-in data, shown only at 10 or more; below that nothing shows, not a zero and not a dash (the third card has none).`,
  `Publishing comes from the personal cookbook as a separate previewed action; a published recipe is visible only to its author until the moderation check passes and can be withdrawn at any time.`,
  `Placement: reached from Cookbook (search and saved live there too), not a fifth tab. The tab bar shows Cookbook active.`,
], [
  ['empty', `No results: "Nothing for 'vietnamese'. Try 'noodles', or clear the filters." Filters stay applied; the saved bookmark keeps its count.`],
  ['kitchen unknown', `No scan yet: cards replace the fit meter with "Scan first and this ranks by your fridge." The rank line hides. Nothing pretends to be cookable.`],
  ['loading', `The catalog is cached on device and renders instantly; remote updates arrive under one 2 px indeterminate line under the section title. No shimmer.`],
  ['offline', `"Rest of the catalog" hides; already-seen cards and your saved recipes render with fit computed on device.`],
  ['moderation', `A reported recipe hides pending review ("Hidden while we look"). A withdrawn recipe disappears everywhere except its author's cookbook.`],
  ['counts', `"Cooked by N" appears at 10 or more distinct cooks and only from opted-in structured outcomes — never notes, never photos, never inferred.`],
  ['saved', `The bookmark is a filter, not a social signal: saved recipes are private to the person who saved them.`],
], [
  ['enter', `Cards rise 40 ms apart, capped at six; the rest appear.`],
  ['filter', `Chip fill crossfades 150 ms; the list re-ranks with a content crossfade under a stable frame (no reflow animation).`],
  ['reduced', `Fades only, 150 ms; no reordering animation.`],
])}`;

// ================================================================ TABLE (+ share preview frame)
const tableCSS = `
.sub{display:flex;justify-content:space-between;align-items:baseline;padding-bottom:18px}
.week{padding:12px 0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule);display:flex;justify-content:space-between}
.card{margin-top:16px;border-radius:14px;box-shadow:inset 0 0 0 .5px var(--cardline);padding:14px 14px 12px;background:var(--card);transition:transform 120ms var(--out)}
.card:active{transform:scale(.985)}
.card .who{display:flex;justify-content:space-between;align-items:baseline}
.card .who b{font-weight:600}
.card .dish{font-size:17px;line-height:24px;font-weight:600;margin-top:2px}
.card .body{display:flex;gap:12px;margin-top:10px;align-items:flex-start}
.card .photo{width:96px;height:96px;flex:none}
.card q{display:block;font-size:15px;line-height:20px;color:var(--ink2);quotes:"\\201C" "\\201D";flex:1}
.card .rate{font-family:var(--mono);font-size:13px;color:var(--ink2);margin-top:6px}
.card .you{display:flex;justify-content:space-between;align-items:center;margin-top:12px;padding-top:12px;border-top:1px solid var(--rule)}
.card .you .l{display:flex;flex-direction:column;gap:4px}
.card.mine{background:transparent;box-shadow:inset 0 0 0 1px var(--rule)}
.challenge{margin-top:12px;padding:14px;border-radius:14px;box-shadow:inset 0 0 0 1px var(--rule2)}
.challenge .dish{font-size:17px;line-height:24px;font-weight:600}
.challenge .cap{margin-top:4px;display:block}
.challenge .you{display:flex;justify-content:space-between;align-items:center;margin-top:12px;padding-top:12px;border-top:1px solid var(--rule)}
.prow{display:flex;justify-content:space-between;align-items:center;gap:12px;min-height:44px;padding:10px 0;border-top:1px solid var(--rule)}
.prow:first-of-type{border-top:0}
.prow .pk{font-size:13px;line-height:16px;font-weight:600;color:var(--ink2)}
.prow .pv{font-size:15px;line-height:20px;text-align:right}
.never{margin-top:12px;padding:10px 0 2px;border-top:1px solid var(--rule)}
`;

const tableFeedInner = () => `
    <header class="head in" style="--i:0"><h1>Table</h1><a href="#">Invite</a></header>
    <div class="sub in" style="--i:0"><span class="sec c2">Flat 4B · Maya, Dev, you</span></div>

    <div class="week in" style="--i:1"><span class="sec">This week</span><span class="mono sec c2">9 cooks · 2 repeats · 1 new</span></div>

    <article class="card in" style="--i:2">
      <div class="who"><b>Maya</b><span class="cap c2 mono">Tue 19:12</span></div>
      <div class="dish">Butter bean curry</div>
      <div class="body">
        <div class="photo"><span>1:1</span></div>
        <div><q>Add lemon at the end, trust me.</q><div class="rate">5 of 5 · swapped spinach for kale</div></div>
      </div>
      <div class="you">
        <div class="l"><span>${fit10(10)}</span><span class="cap">You have everything</span></div>
        <button class="btn primary small">Cook tonight</button>
      </div>
    </article>

    <article class="card in" style="--i:3">
      <div class="who"><b>Dev</b><span class="cap c2 mono">Mon 21:40</span></div>
      <div class="dish">Egg-fried noodles with beansprouts</div>
      <div class="body">
        <div><q>Doubled the garlic. No regrets.</q><div class="rate">4 of 5 · 18 min</div></div>
      </div>
      <div class="you">
        <div class="l"><span>${fit10(8)}</span><span class="cap">Missing beansprouts · <span style="white-space:nowrap">1 swap</span></span></div>
        <button class="btn ghost small">Cook with swap</button>
      </div>
    </article>

    <article class="card mine in" style="--i:4">
      <div class="who"><b>You</b><span class="cap c2 mono">Sun 18:55</span></div>
      <div class="dish">Ginger chicken udon noodles</div>
      <div class="body">
        <div class="photo"><span>1:1</span></div>
        <div><q>Lemon instead of lime worked.</q><div class="rate">4 of 5 · 27 min</div></div>
      </div>
    </article>

    <section class="sect in" style="--i:5">
      <h3>This week's challenge <span class="r">3 days left</span></h3>
      <div class="challenge">
        <div class="dish">Three ingredients, what can you make?</div>
        <span class="cap c2">Cook anything from spinach, eggs and rice. Your result is a cook, like any other.</span>
        <div class="you"><span class="cap c2">Use-it-up pack · nothing bought</span><button class="btn primary small">Join</button></div>
      </div>
      <div class="row"><span class="n">Last week · Use it up<br><span class="cap c2"><span class="mono">6</span> cooked, <span class="mono">1.8 kg</span> kept from the bin</span></span><span class="q">Results</span></div>
      <div class="row"><span class="n">Budget pack · Five dinners under <span class="mono">£2</span> a portion<br><span class="cap c2">Starts Monday, works alone</span></span><span class="q">Save</span></div>
    </section>`;

const tableNote1 = noteHTML('Table — the feed', [
  `A table is 2 to 8 people who eat together or near each other. The unit is a cook, created by finishing one: dish, who, when, the one-line note, rating, substitutions, optional photo. Nobody writes a post.`,
  `Every card ends with the viewer's own fit meter and one button. That line is why this is not a dead feed: each card is a decision the viewer can act on with what is in their fridge. "Cook tonight" sets the dish on Tonight with Maya's note attached to the relevant step.`,
  `No likes, no comments, no follower counts, no ranking. Cards are in time order. Your own cook has no button because you cannot cook it at yourself; it is here so the table sees what you see.`,
  `The challenge block is setup live: the three ingredients are chosen when the owner creates the pack, joining costs nothing, and results come back as ordinary cook cards. Challenges work alone — you can send one as a link that reads without the app.`,
], [
  ['no table', `Title "Table", then: "Tables are small on purpose: 2 to 8 people who cook. Start one with someone you eat with." Buttons: Start a table, Join with a code. Below, the notes section still renders from your own cooks.`],
  ['alone', `Table with one member (you): your cooks as cards, and a single row at the top, "Invite someone. Tables work from 2."`],
  ['quiet', `No cooks this week: the week line reads "Nobody's cooked this week. Your last was Sunday." Cards from last week follow.`],
  ['invite', `Share sheet with a code and a link: "Anyone with this link can ask to join Flat 4B. You approve each person." The owner approves or declines each request and can revoke the link or remove a member; anyone can leave, block and report. Former members lose access. The invite prompt never appears in onboarding; it first appears after the third cook.`],
  ['challenge results', `Entries render as cook cards in time order with a mono entry count. No voting, no leaderboard: the reward is that the table sees your cook.`],
  ['loading', `Cached cards render instantly; new ones arrive at the top with the rise animation. One 2 px line under the week row while fetching.`],
  ['offline', `Cached cards with "As of 18:40" in the sub line. Fit meters still compute locally. Challenge section shows with "Join" disabled and "You're in" if joined.`],
  ['error', `Fetch failed with nothing cached: "Couldn't reach your table. Your cooks are safe on this phone." Retry.`],
], [
  ['enter', `Header, week line and first three cards rise 40 ms apart. Later cards appear without stagger.`],
  ['new cook', `Arrives at the top from scale 0.96 with the move spring; the list below shifts with a transition.`],
  ['cook tonight', `Medium haptic, switch to Tonight with the hero already swapped (150 ms crossfade on arrival).`],
]);

const tableShareBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    ${tableFeedInner().replace(/style="--i:\d"/g, '')}
  </div></div>
  <div class="dim"></div>
  <div class="sheet">
    <div class="shead"><a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Back</a><span class="cap c2 mono">your cook · 18:55</span></div>
    <h2 class="stitle">Share with Flat 4B</h2>
    <p class="cap c2" style="margin:6px 0 14px">This is everything that leaves your phone.</p>
    <div class="prow"><span class="pk">Recipe</span><span class="pv">Butter bean curry <span class="c2">· rev 3</span></span></div>
    <div class="prow"><span class="pk">Servings</span><span class="pv mono">2</span></div>
    <div class="prow"><span class="pk">Swaps</span><span class="pv">Spinach for kale</span></div>
    <div class="prow"><span class="pk">Rating</span><span class="pv mono">5 of 5</span></div>
    <div class="prow"><span class="pk">Note</span><span class="pv">"Add lemon at the end" <span class="c2">· optional</span></span></div>
    <div class="never cap c2">Never shared: your kitchen, your health, your taste profile, your times beyond the day.</div>
    <div style="margin-top:16px;display:grid;gap:4px">
      <button class="btn primary">Share</button>
      <button class="btn">Not now</button>
    </div>
  </div>
  ${HOME_indicator}
</div>

${noteHTML('Table — share preview', [
  `Finishing a cook saves it locally. Sharing is a separate action, and the preview lists exactly what leaves the phone: recipe revision, servings, swaps, rating, an optional one-line note. The "never shared" line is part of the sheet, not fine print — the contract is the interface.`,
  `The same sheet is the publish preview for Explore, with one extra row: "I wrote this myself, or I have the right to share it." Publishing additionally requires the moderation check; until it passes, the recipe is visible only to its author.`,
], [
  ['nothing to share', `The sheet only exists on a finished cook. There is no composer, no draft, no empty share sheet.`],
  ['note by voice', `LeChef transcribes the one-line note at cook-complete and reads it back here for confirmation before anything is shared.`],
  ['aggregate', `A separate opt-in below the sheet: "Add my rating and swaps to the recipe's totals." Structured fields only, never notes or photos, and separate from Table sharing.`],
  ['account', `Sharing requires a Sign in with Apple account and is adult-only in the first release (to confirm). Without it, cooks stay on the phone and everything else still works.`],
  ['photo', `No photo sharing in the first release. The card shows the dish name and your note, not your fridge.`],
], [
  ['enter', `Sheet rises with the move spring over 320 ms; the feed dims to 38% and stays still behind it.`],
  ['exit', `Out at 240 ms, faster than in.`],
  ['reduced', `Fades only.`],
])}`;

// ================================================================ TONIGHT XXL
const xxlCSS = `
.eyebrow{display:flex;align-items:center;gap:8px}
.eyebrow i{width:12px;height:12px;background:var(--yolk);border-radius:2px}
.title{font-size:44px;line-height:48px;font-weight:700;letter-spacing:-.02em;margin:12px 0 10px}
.head h1{font-size:36px;line-height:40px}
.sec{font-size:20px;line-height:26px}
.cap{font-size:16px;line-height:21px}
.label{font-size:16px;line-height:21px}
.btn{height:64px;font-size:22px;border-radius:14px}
.row{min-height:64px;padding:14px 0;gap:14px}
.row .q{font-size:19px}
.tag{font-size:16px;line-height:20px;padding:4px 9px}
.sect{margin-top:32px}
.sect h3{font-size:16px;line-height:21px;margin-bottom:8px}
.fitrow{display:flex;justify-content:space-between;align-items:center;margin-top:16px}
.fit{gap:4px}
.fit i{width:12px;height:12px;border-radius:3px}
.mono{letter-spacing:-.01em}
.tab{font-size:12px;line-height:14px}
`;

const xxlBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head"><h1>Tonight</h1><span class="cap c2 mono">Sat 11 Oct</span></header>

    <section>
      <div class="eyebrow in" style="--i:0"><i></i><span class="label">From your fridge</span></div>
      <h2 class="title in" style="--i:1">Ginger chicken udon noodles</h2>
      <p class="mono sec c2 in" style="--i:2">25 min · 2 servings · 520 kcal</p>
      <div class="fitrow in" style="--i:3">
        ${fit10(9)}
        <span class="mono sec" style="font-weight:500;white-space:nowrap">9 of 10 · 1 swap</span>
      </div>
      <p class="sec in" style="--i:4;margin-top:10px">Everything except lime. Swap in a lemon, you have two.</p>
      <p class="sec c2 in" style="--i:4;margin-top:10px">Why: you've cooked noodles four times this month and rated two of them 5.</p>
      <div style="margin-top:28px;display:grid;gap:6px">
        <button class="btn primary">Cook this</button>
        <button class="btn">Something else</button>
      </div>
    </section>

    <section class="sect">
      <h3>Use soon <a href="#" style="font-size:16px;font-weight:400;color:var(--ink2);text-decoration:none">Kitchen</a></h3>
      <div class="row"><span class="n sec">Spinach</span><span class="tag">2 days</span></div>
      <div class="row"><span class="n sec">Greek yogurt <span class="mono c2">500 g</span></span><span class="tag">tomorrow</span></div>
      <div class="row"><span class="n sec">Lime <span class="mono c2">½</span></span><span class="tag">today</span></div>
    </section>
  </div></div>

  ${TABBAR_F('tonight')}
  ${HOME_indicator}
</div>

${noteHTML('Tonight — accessibility XXL', [
  `The same screen at the largest Dynamic Type sizes. Everything scales through text styles; mono digits scale with .monospaced() on the system font. Primary labels — the dish title, both buttons, every item name and tag — render unclipped: the title wraps to two lines and truncates only at three.`,
  `The 4:5 photo steps aside at accessibility sizes (the documented "no photo is not an error" state): the decision — pick, fit, reason, buttons — must fit above the fold, and the photo is the one block that would push it off. Nothing else is removed.`,
  `Buttons are 64 pt tall, rows 64 pt, tags 16 pt mono. Squares in the fit meter grow to 12 pt so the count stays readable from arm's length.`,
], [
  ['clipping proof', `Checked in the rendered screenshot: title, "Cook this", "Something else", all three use-soon names and their tags are fully visible at 393 pt width. No truncation on any primary label; the "Why" line caps at two lines by copy length, not by clipping.`],
  ['even larger', `At AX5 the buttons stay 64 pt (fixed), text grows one further step, and the use-soon section scrolls — the pick and the buttons never move below the fold.`],
  ['reduced motion', `Entrance is a 150 ms fade; everything else is unchanged because layout, not motion, carries this state.`],
])}`;

// ================================================================ SHELL S
const shellKitchenNote = noteHTML('Shell S — Kitchen', [
  `Sam's stage-2 structure in the F visual system: Kitchen and Progress as main tabs, a central scan orb, Profile inside Progress. Tonight keeps its slot; Table keeps its slot; Cookbook's content folds into Progress (cooks, taste) and Explore (search, saved).`,
  `The orb is mocked as asked, in the least glassy way the system allows: the bar is flat paper with a single hairline (no blur, no shadow), and the orb is a matte ink disc with a paper ring where it crosses the hairline. No glow, no gradient, no lift animation.`,
  `The tension is stated plainly: Direction F's Avoid list bans a floating centre button that lifts above the bar, because a five-target bar with a raised centre costs a thumb-width of list and reads as decoration. Shell S is Sam's competing candidate and is rendered here so the round can compare it honestly; DIRECTION.md records both sides.`,
], [
  ['kitchen states', `Identical to kitchen.html — this is the same screen under different chrome. All Kitchen states carry over unchanged.`],
  ['orb press', `Press scale 0.95 in 120 ms, same as the F scan button. The orb never grows, glows, or pulses.`],
  ['reachability', `Scan stays reachable from the orb on every tab; LeChef stays out of the bar, entered from Tonight or a recipe, in either shell.`],
]);

const shellProgressCSS = `
.head{padding:10px 0 16px}
.stat{display:flex;align-items:baseline;gap:14px;padding:14px 0;border-top:1px solid var(--rule)}
.stat:first-of-type{border-top:0}
.stat b{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:28px;line-height:32px;font-weight:500;letter-spacing:-.01em;min-width:96px}
.stat .n{flex:1}
.stat .n small{display:block;font-size:13px;line-height:16px;color:var(--ink2);margin-top:2px}
`;

const shellProgressBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head in" style="--i:0"><h1>Progress</h1><span class="cap c2 mono">Oct</span></header>

    <section class="sect in" style="--i:1;margin-top:8px">
      <div class="stat"><b>23</b><span class="n"><span class="sec">Cooks made</span><small>18 weeknights · 5 weekends</small></span></div>
      <div class="stat"><b>4.1 kg</b><span class="n"><span class="sec">Food saved</span><small>Estimated from use-it-up cooks and saved leftovers</small></span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Nutrition</h3>
      <div class="row"><span class="n">Logged 9 of your 14 meals this week<br><span class="cap c2">A lens, not a goal. Apple Health gets confirmed meals only.</span></span><span class="q">Open</span></div>
    </section>

    <section class="sect in" style="--i:3">
      <h3>Learned</h3>
      <div class="row"><span class="n">Your taste<br><span class="cap c2">23 sentences, each with its evidence. Correctable.</span></span><span class="q">Open</span></div>
      <div class="row"><span class="n">LeChef remembers<br><span class="cap c2">4 notes, read back mid-cook</span></span><span class="q">Open</span></div>
    </section>

    <section class="sect in" style="--i:4">
      <h3>Profile</h3>
      <div class="row"><span class="n">Restrictions<br><span class="cap c2">Shellfish allergy · from setup</span></span><span class="q">Open</span></div>
      <div class="row"><span class="n">Household<br><span class="cap c2">2 eaters</span></span><span class="q">Open</span></div>
      <div class="row"><span class="n">Equipment<br><span class="cap c2">Wok, oven, thermometer</span></span><span class="q">Open</span></div>
    </section>
  </div></div>

  ${TABBAR_S('progress')}
  ${HOME_indicator}
</div>

${noteHTML('Shell S — Progress', [
  `Progress as a main tab, with Profile inside it. Counts what cooking here has done: cooks made and food saved, both in mono, both honest about method. No rings, no badges here — the quests candidate is a separate round and, if it ships at all, it links from here rather than living in the tab.`,
  `Nutrition keeps its SPEC position: a line with honest coverage ("logged 9 of your 14 meals"), never a goal, never a ring.`,
  `The learned section is the taste profile entry point; the counts are the same ones the profile page shows.`,
], [
  ['empty', `New account: the two stat rows read "0" with "Cook your first dinner and this starts counting." Nothing is hidden, nothing is faked.`],
  ['food saved', `The kg figure is an estimate from use-it-up cooks and leftovers kept; the caption says so on the screen. It never claims precision it does not have.`],
  ['nutrition off', `If logging is off: "Not logging right now. Turn it on for a line here." — one row, no empty chart.`],
  ['healthkit', `Apple Health stays a setting inside Profile; writes only confirmed meals.`],
  ['rejection', `No weekly report, no "you cooked 12% less than last week". Progress counts; it does not judge.`],
])}`;

const shellProfileBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <div class="nav"><a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Progress</a></div>

    <header class="head in" style="--i:0">
      <h1>Profile</h1>
      <p class="sec c2">The parts of you the app cooks around. They change only here.</p>
    </header>

    <section class="sect in" style="--i:1">
      <h3>Hard restrictions <span>never weakened</span></h3>
      <div class="chips" style="margin-top:0;padding-top:4px">
        <span class="chip on">Shellfish — allergy <span class="cap">from setup</span></span>
        <span class="chip">Cooking for 2</span>
        <span class="chip">Metric</span>
      </div>
      <p class="cap c2" style="margin-top:10px">Allergies and diets are hard filters. They survive any reset, outrank every preference, and are edited in setup, not here.</p>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Settings</h3>
      <div class="row"><span class="n">Apple Health</span><span class="q">On</span></div>
      <div class="row"><span class="n">LeChef voice</span><span class="q">On</span></div>
      <div class="row"><span class="n">Notifications</span><span class="q">Timers only</span></div>
      <div class="row"><span class="n">Appearance</span><span class="q">System</span></div>
    </section>

    <section class="sect in" style="--i:3">
      <h3>Account</h3>
      <div class="row"><span class="n">Sign in with Apple</span><span class="q">Connected</span></div>
      <div class="row"><span class="n">Export everything</span><span class="q">JSON</span></div>
      <div class="row"><span class="n" style="color:var(--err)">Delete account</span></div>
    </section>

    <p class="cap c2 in" style="--i:4;margin-top:24px">Forgetting what the app learned lives in Your taste, not here. This page is who you are; that page is what it noticed.</p>
  </div></div>
  ${HOME_indicator}
</div>

${noteHTML('Shell S — Profile', [
  `Profile lives inside Progress, one tap down. It holds the things that must be stable and legible: hard restrictions, household, equipment, and account.`,
  `The chips carry the shellfish allergy in the confirmed state (yolk-soft, yolk stroke) with "from setup" beside it — the same triple treatment the taste profile gives a confirmed sentence, because restrictions are the strongest sentence there is.`,
  `Delete account and Forget everything are deliberately different screens: this one deletes the person's account; the taste profile forgets what the app noticed. Neither cascades into the other.`,
], [
  ['edit restrictions', `The chips link to setup screens; nothing inline. A restriction change rechecks every saved recipe and plan on device and says what changed.`],
  ['signed out', `"Sign in with Apple — Not connected" with the caption "Needed for sharing with a Table or publishing to Explore. Everything else works without it."`],
  ['household', `Who is eating: default you; one more eater with their own restrictions. Hard restrictions are the union of all eaters'.`],
  ['equipment', `Drives Adapt and step text: no thermometer registered and step 3 says "check with a thermometer" plus where to buy one, not a fake alternative.`],
])}`;

// ================================================================ CANDIDATES
const questsCSS = `
.head{padding:10px 0 16px}
.qcard{margin-top:12px;padding:14px;border-radius:14px;box-shadow:inset 0 0 0 1px var(--rule2)}
.qcard .qt{display:flex;justify-content:space-between;align-items:baseline}
.qcard .qt b{font-size:17px;line-height:24px;font-weight:600}
.qcard .squares{display:flex;gap:4px;margin-top:10px}
.qcard .squares i{width:14px;height:14px;border-radius:3px;background:var(--ink)}
.qcard .squares i.o{background:transparent;box-shadow:inset 0 0 0 1.5px var(--rule2)}
.qcard .squares i.y{background:transparent;box-shadow:inset 0 0 0 1.5px var(--yolk)}
.qcard .cap{margin-top:10px;display:block}
.badges{display:flex;gap:20px;margin-top:14px}
.badge{display:flex;flex-direction:column;align-items:center;gap:8px;width:96px}
.badge .disc{width:64px;height:64px;border-radius:50%;box-shadow:inset 0 0 0 1.5px var(--ink);display:grid;place-items:center;font-family:var(--mono);font-size:15px;font-weight:500;font-variant-numeric:tabular-nums}
.badge .disc.done{background:var(--ink);color:var(--btn-ink);box-shadow:none}
.badge .disc.locked{box-shadow:inset 0 0 0 1.5px var(--rule2);color:var(--ink3)}
.badge .bl{font-size:13px;line-height:16px;font-weight:600;text-align:center}
.badge .bp{font-family:var(--mono);font-size:11px;line-height:14px;color:var(--ink2);text-align:center}
`;

const questsBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head in" style="--i:0"><h1>Rewards</h1><span class="cap c2 mono">Oct</span></header>
    <p class="sec c2 in" style="--i:0;margin-top:-10px;padding-bottom:8px">Counts what you cook, not what you open.</p>

    <section class="sect in" style="--i:1;margin-top:20px">
      <h3>This week <span class="r">2 quests</span></h3>
      <div class="qcard">
        <div class="qt"><b>Cook 3 dinners</b><span class="mono sec" style="font-weight:500">2 of 3</span></div>
        <div class="squares" aria-label="2 of 3 done"><i></i><i></i><i class="y"></i></div>
        <span class="cap c2">One to go. Any dinner counts, including a leftover reheated as a cook.</span>
      </div>
      <div class="qcard">
        <div class="qt"><b>Use it up: cook the spinach</b><span class="tag">2 days</span></div>
        <div class="squares" aria-label="not started"><i class="o"></i></div>
        <span class="cap c2">The bag is on the use-soon list. One cook clears it.</span>
      </div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Milestones <span class="r">counters, not trophies</span></h3>
      <div class="badges">
        <div class="badge"><div class="disc">25</div><span class="bl">Cooks made</span><span class="bp">23 so far</span></div>
        <div class="badge"><div class="disc">5 kg</div><span class="bl">Food saved</span><span class="bp">4.1 so far</span></div>
        <div class="badge"><div class="disc done">1</div><span class="bl">First cook</span><span class="bp">done 14 Sept</span></div>
      </div>
      <p class="cap c2" style="margin-top:14px">No streaks, no flames, no confetti. Miss a month and nothing resets; the counters just wait.</p>
    </section>
  </div></div>

  ${TABBAR_F('cookbook')}
  ${HOME_indicator}
</div>

${noteHTML('Candidate — quests and badges', [
  `THE TENSION, STATED: Direction F's Avoid list bans confetti, streak flames, trophies and badges. Sam proposed light quests and rewards, so per the round rules the candidate is mocked, not cut — in the quietest F-compatible form and judged by the scorecard like any other candidate.`,
  `The quiet form: quest progress is the app's own fit-meter squares (filled ink, next one yolk-outlined); milestones are ink outline discs holding mono counters, not trophy shapes; celebration copy is absent; there is one yolk element per card and it marks the live quest. No sound, no haptic beyond the standard light confirm, no animation beyond the shared rise.`,
  `What it rewards is fixed: COOKS MADE and FOOD SAVED — the two signals product-direction says are worth something. Nothing counts app opens, logins, or scans.`,
  `The honest recommendation: this page competes with cook-complete's one quiet moment. If both ship, the reward for a cook is the dish plus a counter that moved — never a popup. If the scorecard shows quests pull attention from Tonight, the counters fold into Progress and this page dies.`,
], [
  ['completion', `A finished quest increments the mono counter and fills the last square with a 150 ms crossfade. No modal, no sound, no confetti. The next quest appears as a plain row.`],
  ['missed week', `Nothing expires. The squares stay as they were; the caption reads "Picks up where you left off."`],
  ['food saved metric', `Same estimate as Progress: use-it-up cooks and kept leftovers. The caption on the milestone says "estimated".`],
  ['off state', `New account: "Cook three things and a quest writes itself." No seeded quests, no placeholders.`],
])}`;

const tourBody = () => `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
    <header class="head"><h1>Tonight</h1><span class="cap c2 mono">Sat 11 Oct</span></header>
    <section>
      <div class="eyebrow"><i></i><span class="label">From your fridge</span></div>
      <h2 class="title" style="font-size:32px;line-height:34px;font-weight:700;letter-spacing:-.02em;margin:10px 0 6px">Ginger chicken udon noodles</h2>
      <p class="mono sec c2">25 min · 2 servings · 520 kcal</p>
      <div class="photo" style="aspect-ratio:4/5;margin-top:16px"><span>photo: overhead, daylight, 4:5</span></div>
      <p class="sec" style="margin-top:12px">Everything except lime. Swap in a lemon, you have two.</p>
    </section>
  </div></div>

  <div class="dim"></div>
  <div class="sheet">
    <div class="shead">
      <a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Back</a>
      <span class="cap c2 mono">Step 1 of 3</span>
      <a href="#" class="q">Skip</a>
    </div>
    <h2 class="stitle">Scan a shelf</h2>
    <p class="sec c2" style="margin:10px 0 22px">Point the camera at one shelf. I'll ask about at most three things, then this step is over.</p>
    <button class="btn primary">Open camera</button>
    <p class="cap c2" style="text-align:center;margin-top:14px">You come straight back here after each step. Three steps, then the tour ends for good.</p>
  </div>
  ${HOME_indicator}
</div>

${noteHTML('Candidate — guided tour', [
  `THE TENSION, STATED: the overhaul cut tutorial quests and spotlight overlays because "a home screen that needs a tutorial is the problem". Sam asked in March for a short guided tour, so the constrained form competes as a candidate.`,
  `The constraint, all Sam's asks honoured: three short steps (Scan a shelf · Confirm your kitchen · Cook with LeChef); after each step you return to Tonight automatically — the tour is a sheet over the real screen, never a separate world; Back is visible in the sheet header; Skip ends it for good, from any step.`,
  `Each step's button launches the real action on the real screen. The tour teaches by doing one thing, not by explaining the app.`,
], [
  ['step 2', `"Confirm your kitchen": the sheet re-opens on Tonight after the scan, pointing at Kitchen — "Three things need your eye. This is the whole chore."`],
  ['step 3', `"Cook with LeChef": points at the recipe dock — "Press this when you cook. Say 'next' when your hands are wet."`],
  ['auto-return', `Every step dismisses itself on completion and lands back on Tonight with a 150 ms fade. No interstitial, no "great job".`],
  ['done', `After step 3: one line on Tonight, "Tour done. It won't ask again." Re-entry lives in Profile → "Show the tour", never pushed.`],
  ['reduced motion', `Sheets fade 150 ms instead of sliding; everything else is a normal press.`],
])}`;

// ================================================================ emit
const files = [
  ['tonight', 'Tonight', PALETTES.light, tonightBody(), tonightCSS],
  ['kitchen', 'Kitchen', PALETTES.light, kitchenBody(TABBAR_F('kitchen')) + '\n\n' + kitchenNote, kitchenCSS],
  ['scan-review', 'Scan review', PALETTES.light, scanBody(), scanCSS],
  ['recipe', 'Recipe', PALETTES.light, recipeBody(), recipeCSS],
  ['cook-lechef', 'Cook with LeChef', PALETTES.hob, cookBody(), cookCSS],
  ['taste-profile', 'Your taste', PALETTES.light, tasteBody(), tasteCSS],
  ['explore', 'Explore', PALETTES.light, exploreBody(), exploreCSS],
  ['tonight-xxl', 'Tonight XXL', PALETTES.light, xxlBody(), xxlCSS],
  ['shell-s-kitchen', 'Shell S Kitchen', PALETTES.light, kitchenBody(TABBAR_S('kitchen')) + '\n\n' + shellKitchenNote, kitchenCSS],
  ['shell-s-progress', 'Shell S Progress', PALETTES.light, shellProgressBody(), shellProgressCSS],
  ['shell-s-profile', 'Shell S Profile', PALETTES.light, shellProfileBody(), ''],
  ['candidates-quests', 'Candidates Rewards', PALETTES.light, questsBody(), questsCSS],
  ['candidates-tour', 'Candidates Tour', PALETTES.light, tourBody(), tableCSS],
  ['table', 'Table', PALETTES.light, tableLight(), tableCSS],
];
function tableLight() {
  return `
<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
${tableFeedInner()}
  </div></div>
  ${TABBAR_F('table')}
  ${HOME_indicator}
</div>

${tableNote1}

<div class="phone">
  ${STATUS}
  <div class="screen"><div class="scroll">
${tableFeedInner().replace(/style="--i:\d+"/g, '')}
  </div></div>
  <div class="dim"></div>
  <div class="sheet">
    <div class="shead"><a href="#"><svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 2 2 10l8 8"/></svg>Back</a><span class="cap c2 mono">your cook · 18:55</span></div>
    <h2 class="stitle">Share with Flat 4B</h2>
    <p class="cap c2" style="margin:6px 0 14px">This is everything that leaves your phone.</p>
    <div class="prow"><span class="pk">Recipe</span><span class="pv">Butter bean curry <span class="c2">· rev 3</span></span></div>
    <div class="prow"><span class="pk">Servings</span><span class="pv mono">2</span></div>
    <div class="prow"><span class="pk">Swaps</span><span class="pv">Spinach for kale</span></div>
    <div class="prow"><span class="pk">Rating</span><span class="pv mono">5 of 5</span></div>
    <div class="prow"><span class="pk">Note</span><span class="pv">"Add lemon at the end" <span class="c2">· optional</span></span></div>
    <div class="never cap c2">Never shared: your kitchen, your health, your taste profile, your times beyond the day.</div>
    <div style="margin-top:16px;display:grid;gap:4px">
      <button class="btn primary">Share</button>
      <button class="btn">Not now</button>
    </div>
  </div>
  ${HOME_indicator}
</div>

${tableShareNote()}`;
}
function tableShareNote() {
  return tableShareBody().split('<aside').slice(1).map(s => '<aside' + s).join('');
}

// dark variants: same bodies/notes, dark tokens
const darkFiles = [
  ['tonight-dark', 'Tonight (dark)', PALETTES.dark, tonightBody(), tonightCSS],
  ['kitchen-dark', 'Kitchen (dark)', PALETTES.dark, kitchenBody(TABBAR_F('kitchen')) + '\n\n' + kitchenNote, kitchenCSS],
  ['scan-review-dark', 'Scan review (dark)', PALETTES.dark, scanBody(), scanCSS],
  ['recipe-dark', 'Recipe (dark)', PALETTES.dark, recipeBody(), recipeCSS],
  ['taste-profile-dark', 'Your taste (dark)', PALETTES.dark, tasteBody(), tasteCSS],
  ['explore-dark', 'Explore (dark)', PALETTES.dark, exploreBody(), exploreCSS],
  ['shell-s-kitchen-dark', 'Shell S Kitchen (dark)', PALETTES.dark, kitchenBody(TABBAR_S('kitchen')) + '\n\n' + shellKitchenNote, kitchenCSS],
  ['shell-s-progress-dark', 'Shell S Progress (dark)', PALETTES.dark, shellProgressBody(), shellProgressCSS],
  ['shell-s-profile-dark', 'Shell S Profile (dark)', PALETTES.dark, shellProfileBody(), ''],
  ['candidates-quests-dark', 'Candidates Rewards (dark)', PALETTES.dark, questsBody(), questsCSS],
  ['candidates-tour-dark', 'Candidates Tour (dark)', PALETTES.dark, tourBody(), tableCSS],
  ['table-dark', 'Table (dark)', PALETTES.dark, tableLight(), tableCSS],
];

let count = 0;
for (const [name, title, pal, body, css] of [...files, ...darkFiles]) {
  fs.writeFileSync(path.join(OUT, name + '.html'), page(pal, title, body, css));
  count++;
}
console.log(`wrote ${count} files to ${OUT}`);

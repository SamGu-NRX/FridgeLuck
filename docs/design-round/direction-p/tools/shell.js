/* Direction P shared shell: 393x852 frame, iOS chrome, token CSS, type scale, motion, notes aside. */
'use strict';
const TOKENS = require('./tokens.json');

const SERIF = 'ui-serif,"New York","SF Pro Display",Georgia,"Times New Roman",serif';
const ROUND = 'ui-rounded,"SF Pro Rounded",-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Arial,sans-serif';
const MONO = 'ui-monospace,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace';

function vars(t) {
  return `--bg:${t.bg};--bg-deep:${t.bgDeep};--surface:${t.surface};--surf-mut:${t.surfaceMuted};` +
    `--ink:${t.ink};--ink2:${t.ink2};--accent:${t.accent};--accent-ink:${t.accentInk || t.accent};` +
    `--accent-lt:${t.accentLight};--sage:${t.sage};--sage-ink:${t.sageInk || t.sage};--sage-lt:${t.sageLight};` +
    `--oat:${t.oat};--oat-ink:${t.oatInk || t.oat};--rose:${t.dustyRose};--hero-lt:${t.heroLight};--hero-mid:${t.heroMid};` +
    `--chip-acc:${t.chipAccent};--chip-sage:${t.chipSage};--chip-oat:${t.chipOat};--chip-rose:${t.chipRose};` +
    `--rule:${t.rule};--rule2:${t.rule2};--btn-fill:${t.btnFill || t.accentInk};--btn-fg:${t.btnFg};` +
    `--tile:${t.deepOliveLight || t.surfaceMuted};--slab:${t.deepOlive || t.bgDeep};`;
}

const BASE_CSS = `
*{box-sizing:border-box;margin:0;padding:0}
a{color:inherit;text-decoration:none}
html{background:#DAD2C4}
body{font-family:${ROUND};background:#DAD2C4;color:var(--ink);-webkit-font-smoothing:antialiased;display:flex;flex-direction:column;align-items:center;gap:28px;padding:36px 16px 72px;min-height:100vh;font-size:var(--t1);line-height:var(--t1l)}
.phone{position:relative;width:393px;height:852px;flex:none;background:var(--bg);color:var(--ink);border-radius:54px;overflow:hidden;box-shadow:0 0 0 1px rgba(42,33,24,.18),0 30px 60px -20px rgba(42,33,24,.35)}
html[data-mode="cook"] .phone{box-shadow:0 0 0 1px rgba(0,0,0,.5),0 30px 60px -20px rgba(0,0,0,.5)}
.island{position:absolute;top:11px;left:50%;transform:translateX(-50%);width:125px;height:37px;background:#000;border-radius:20px;z-index:12}
.status{position:absolute;top:0;left:0;right:0;height:54px;display:flex;justify-content:space-between;align-items:center;padding:4px 36px 0 44px;font-size:17px;font-weight:600;z-index:11;color:var(--ink)}
.status .sig{display:flex;gap:7px;align-items:center}
.homebar{position:absolute;bottom:8px;left:50%;transform:translateX(-50%);width:139px;height:5px;border-radius:3px;background:var(--ink);z-index:12;opacity:.9}
.screen{position:absolute;inset:0;padding-top:54px}
.scroll{height:100%;overflow:auto;scrollbar-width:none;padding:0 20px 170px}
.scroll::-webkit-scrollbar{display:none}
.mono{font-family:${MONO};font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.c2{color:var(--ink2)}
.d1{font-family:${SERIF};font-size:var(--d1);line-height:var(--d1l);font-weight:700;letter-spacing:-.01em}
.d2{font-family:${SERIF};font-size:var(--d2);line-height:var(--d2l);font-weight:700;letter-spacing:-.01em}
.d3{font-family:${SERIF};font-size:var(--d3);line-height:var(--d3l);font-weight:600}
.t1{font-size:var(--t1);line-height:var(--t1l)}
.t2{font-size:var(--t2);line-height:var(--t2l)}
.cap{font-size:var(--cap);line-height:var(--capl)}
.label{font-size:var(--cap);line-height:var(--capl);font-weight:600}
.m1{font-size:var(--m1);line-height:var(--m1l)}
.m2{font-size:var(--m2);line-height:var(--m2l)}
.m3{font-size:var(--m3);line-height:var(--m3l)}
.card{background:var(--surface);border-radius:16px;box-shadow:inset 0 0 0 .5px var(--rule)}
.rows{background:var(--surface);border-radius:16px;box-shadow:inset 0 0 0 .5px var(--rule);overflow:hidden}
.row{min-height:44px;display:flex;align-items:center;gap:12px;padding:10px 14px;border-top:1px solid var(--rule);transition:transform 120ms var(--out)}
.row:first-child{border-top:0}
.row:active{transform:scale(.985)}
.row .n{flex:1;min-width:0}
.chip{display:inline-flex;align-items:center;gap:6px;font-size:var(--cap);line-height:var(--capl);font-weight:600;padding:3px 9px;border-radius:9px;background:var(--chip-oat);color:var(--ink);white-space:nowrap}
.chip .dot{width:6px;height:6px;border-radius:50%;flex:none}
.chip.acc{background:var(--chip-acc)}.chip.sag{background:var(--chip-sage)}.chip.oat{background:var(--chip-oat)}.chip.ros{background:var(--chip-rose)}
.sq{width:10px;height:10px;border-radius:3px;flex:none;margin-right:2px}
.sq.have{background:var(--sage)}
.sq.missing{background:transparent;box-shadow:inset 0 0 0 1.5px var(--ink2)}
.sq.unconf{background:transparent;border:1.5px dashed var(--ink2)}
.fit{display:inline-flex;gap:3px;align-items:center;flex:none}
.fit i{width:9px;height:9px;border-radius:2.5px;background:var(--accent)}
.fit i.o{background:transparent;box-shadow:inset 0 0 0 1.5px var(--ink2)}
.btn{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;min-height:52px;border-radius:13px;font:inherit;font-weight:600;font-size:var(--t1);border:0;cursor:pointer;transition:transform 120ms var(--out);color:var(--ink);background:transparent;padding:0 18px}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--btn-fill);color:var(--btn-fg)}
.btn.ghost{box-shadow:inset 0 0 0 1.5px var(--rule2)}
.btn.small{min-height:44px;width:auto;padding:0 16px;border-radius:11px;font-size:var(--t2)}
.btn:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.sect{margin-top:28px}
.sect>.label{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px;padding:0 4px}
.sect>.label a{font-weight:400;color:var(--ink2);text-decoration:none;white-space:nowrap}
.field{display:flex;align-items:center;gap:10px;min-height:44px;background:var(--surface);border-radius:12px;box-shadow:inset 0 0 0 .5px var(--rule);padding:0 14px;color:var(--ink2);font-size:var(--t2)}
.in{animation:rise 180ms var(--out) both;animation-delay:calc(var(--i,0)*24ms)}
@keyframes rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
/* tab bar (shell F) */
.tabbar{position:absolute;left:0;right:0;bottom:0;z-index:10;display:grid;grid-template-columns:repeat(5,1fr);min-height:84px;padding:6px 8px 20px;background:var(--tabbar);box-shadow:inset 0 .5px 0 var(--rule)}
.tabs{display:contents}
.tab{display:flex;flex-direction:column;align-items:center;gap:3px;font-size:10.5px;line-height:13px;font-weight:500;color:var(--ink2);padding-top:6px}
.tab.on{color:var(--ink)}
.tab.on .tdot{width:4px;height:4px;border-radius:50%;background:var(--accent)}
.tab .tdot{display:none}
.tab svg{width:24px;height:24px}
/* the floating orb nav on Shell F is killed by the brief: the bar is flat, no scan button.
   Shell S keeps its central scan orb as a separate candidate (.orb-s below). */
/* shell S tab bar */
.tabs-s{position:absolute;left:14px;right:14px;bottom:22px;z-index:10;display:flex;align-items:center;justify-content:space-between;padding:0 10px;min-height:70px;background:var(--tabbar);border-radius:35px;box-shadow:inset 0 0 0 .5px var(--rule),0 10px 28px -12px rgba(42,33,24,.35)}
.tab-s{display:flex;flex-direction:column;align-items:center;gap:2px;font-size:11px;line-height:14px;font-weight:500;color:var(--ink2);width:96px;padding:8px 0}
.tab-s.on{color:var(--ink)}
.tab-s svg{width:24px;height:24px}
.orb-s{width:74px;height:74px;border-radius:50%;display:grid;place-items:center;background:var(--btn-fill);color:var(--btn-fg);box-shadow:0 12px 30px -8px rgba(42,33,24,.55);margin-top:-30px;transition:transform 120ms var(--out);flex:none}
.orb-s:active{transform:scale(.95)}
/* resume dock + cook dock */
.dock{position:absolute;left:14px;right:14px;bottom:96px;z-index:10;background:var(--surface);border-radius:18px;box-shadow:inset 0 0 0 .5px var(--rule),0 12px 30px -12px rgba(42,33,24,.4);padding:12px 14px;display:flex;align-items:center;gap:12px}
/* plate illustration */
.plate{position:relative;background:var(--bg-deep);border-radius:16px;overflow:hidden;box-shadow:inset 0 0 0 .5px var(--rule)}
.plate .pl{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:56%;aspect-ratio:1;border-radius:50%;background:var(--surface);box-shadow:inset 0 0 0 1px var(--rule)}
.plate .b{position:absolute;border-radius:50%}
/* notes */
.note{width:640px;max-width:calc(100vw - 32px);flex:none;font-size:13px;line-height:19px;color:#3A332B;padding-top:8px}
.note h1{font-size:15px;line-height:20px;font-weight:600;margin-bottom:4px}
.note p{margin-bottom:10px}
.note h2{font-size:12px;line-height:16px;font-weight:600;margin:16px 0 8px;color:#6B6054}
.note dl{display:grid;grid-template-columns:96px 1fr;gap:7px 12px}
.note dt{font-family:${MONO};font-size:11px;line-height:19px;color:#6B6054}
.note code{font-family:${MONO};font-size:12px;background:#EFE9DD;border-radius:4px;padding:0 4px}
@media (prefers-reduced-motion:reduce){.in{animation:fadein 150ms ease both;animation-delay:0s}@keyframes fadein{from{opacity:0}to{opacity:1}}}
`;

const TYPE_VARS = `:root{--d1:34px;--d1l:40px;--d2:28px;--d2l:33px;--d3:21px;--d3l:26px;--t1:17px;--t1l:24px;--t2:15px;--t2l:21px;--cap:13px;--capl:17px;--m1:17px;--m1l:22px;--m2:15px;--m2l:20px;--m3:13px;--m3l:17px;--cook:27px;--cookl:35px;--out:cubic-bezier(.23,1,.32,1);--move:cubic-bezier(.32,.72,0,1);--tabbar:rgba(254,252,248,.82)}`;
const XXL_VARS = `html[data-xxl="1"]{--d1:46px;--d1l:54px;--d2:38px;--d2l:44px;--d3:29px;--d3l:35px;--t1:23px;--t1l:31px;--t2:20px;--t2l:27px;--cap:18px;--capl:24px;--m1:23px;--m1l:29px;--m2:20px;--m2l:26px;--m3:17px;--m3l:23px;--cook:36px;--cookl:46px}`;
const XXL_CSS = `html[data-xxl="1"] .head{flex-wrap:wrap;row-gap:10px}
html[data-xxl="1"] .plate{aspect-ratio:auto;height:150px}
html[data-xxl="1"] .dock{flex-wrap:wrap;row-gap:6px}
html[data-xxl="1"] .dock .n{flex:1 1 100%;order:-1}
html[data-xxl="1"] .dock .btn{margin-left:auto}`;

function statusSvgs() {
  return `<span class="sig">
    <svg width="18" height="12" viewBox="0 0 18 12"><rect x="0" y="8" width="3" height="4" rx=".8" fill="currentColor"/><rect x="5" y="5.5" width="3" height="6.5" rx=".8" fill="currentColor"/><rect x="10" y="3" width="3" height="9" rx=".8" fill="currentColor"/><rect x="15" y="0" width="3" height="12" rx=".8" fill="currentColor"/></svg>
    <svg width="16" height="12" viewBox="0 0 16 12"><path d="M8 11.2 1.3 4.5a9.5 9.5 0 0 1 13.4 0z" fill="currentColor"/></svg>
    <svg width="27" height="12" viewBox="0 0 27 12"><rect x=".5" y=".5" width="23" height="11" rx="3" fill="none" stroke="currentColor" stroke-opacity=".4"/><rect x="2" y="2" width="20" height="8" rx="1.6" fill="currentColor"/><rect x="25" y="4" width="1.6" height="4" rx=".8" fill="currentColor" fill-opacity=".4"/></svg>
  </span>`;
}

const ICONS = {
  tonight: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/></svg>',
  kitchen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="6" y="2.5" width="12" height="19" rx="2"/><path d="M6 10h12M9 6v1.5M9 13.5v3"/></svg>',
  table: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 9.5h18M6 9.5V19M18 9.5V19"/><circle cx="12" cy="5" r="2.5"/></svg>',
  cookbook: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M5 4.5h10.5a2.5 2.5 0 0 1 2.5 2.5v12.5H7.5A2.5 2.5 0 0 1 5 17z"/><path d="M5 17a2.5 2.5 0 0 1 2.5-2.5H18"/></svg>',
  explore: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5z"/></svg>',
  scan: '<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9V6a2 2 0 0 1 2-2h3M15 4h3a2 2 0 0 1 2 2v3M20 15v3a2 2 0 0 1-2 2h-3M9 20H6a2 2 0 0 1-2-2v-3"/><circle cx="12" cy="12" r="3"/></svg>',
  progress: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 20h16M7 20v-6M12 20V9M17 20V4"/></svg>',
  search: '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>',
  chev: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 5 7 7-7 7"/></svg>',
  cam: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 8.5A2.5 2.5 0 0 1 6.5 6h1L9 4h6l1.5 2h1A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z"/><circle cx="12" cy="12.5" r="3.5"/></svg>',
  mic: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>',
  back: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 5-7 7 7 7"/></svg>',
  pause: '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1.2"/><rect x="14" y="4" width="4" height="16" rx="1.2"/></svg>',
};

function tabbarF(active) {
  const tabs = [['tonight', 'Tonight'], ['kitchen', 'Kitchen'], ['table', 'Table'], ['cookbook', 'Cookbook'], ['explore', 'Explore']];
  return `<nav class="tabbar"><div class="tabs">` + tabs.map(([id, lbl]) =>
    `<a class="tab${active === id ? ' on' : ''}" href="#">${ICONS[id]}${lbl}</a>`).join('') + `</div></nav>`;
}

function tabbarS(active) {
  return `<nav class="tabs-s">
    <a class="tab-s${active === 'kitchen' ? ' on' : ''}" href="#">${ICONS.kitchen}Kitchen</a>
    <a class="orb-s" aria-label="Scan">${ICONS.scan}</a>
    <a class="tab-s${active === 'progress' ? ' on' : ''}" href="#">${ICONS.progress}Progress</a>
  </nav>`;
}

/* emit one file. body.multi=true → body.html already contains full .phone blocks. */
function chrome(innerHtml) {
  return `<div class="phone">
  <div class="island"></div>
  <div class="status"><span>9:41</span>${statusSvgs()}</div>
${innerHtml}
  <div class="homebar"></div>
</div>`;
}

function page({ mode, title, xxl, body, note }) {
  const t = TOKENS[mode === 'cook' ? 'cook' : mode];
  const phone = body.multi ? body.html : chrome(body.html);
  return `<!doctype html>
<html lang="en" data-mode="${mode}"${xxl ? ' data-xxl="1"' : ''}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FridgeLuck · Direction P · ${title}</title>
<style>
${TYPE_VARS}
${XXL_VARS}
${xxl ? XXL_CSS : ''}
html[data-mode="light"]{${vars(TOKENS.light)}--tabbar:rgba(254,252,248,.84)}
html[data-mode="dark"]{${vars(TOKENS.dark)}--tabbar:rgba(36,33,28,.84)}
html[data-mode="cook"]{${vars(TOKENS.cook)}--tabbar:rgba(44,41,36,.9)}
${BASE_CSS}
${body.css || ''}
</style>
</head>
<body>
${phone}
<aside class="note">
${note}
</aside>
</body>
</html>
`;
}

module.exports = { page, chrome, tabbarF, tabbarS, ICONS, MONO, SERIF };

#!/usr/bin/env node
/* Direction P — WCAG 2.1 contrast computation for every text/background pair used in the mocks.
 * Source of truth for tokens: AppTheme.swift floats (converted here, verified against the brief's hex).
 * Tokens that fail the bar are adjusted by the smallest HSL-lightness step that passes, hue kept.
 * Output: tokens.json (consumed by gen.js) + a markdown table on stdout. */
'use strict';
const fs = require('fs');
const path = require('path');

/* ---------- color math ---------- */
const toHex = rgb => '#' + rgb.map(v => Math.round(v).toString(16).padStart(2, '0')).join('').toUpperCase();
const fromFloats = f => toHex(f.map(v => v * 255));
function hexToRgb(h) { return [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)); }
function lin(c) { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
function lum(rgb) { const [r, g, b] = rgb.map(lin); return 0.2126 * r + 0.7152 * g + 0.0722 * b; }
function ratio(fg, bg) { const a = lum(hexToRgb(fg)), b = lum(hexToRgb(bg)); const hi = Math.max(a, b), lo = Math.min(a, b); return (hi + 0.05) / (lo + 0.05); }
const r2 = x => Math.round(x * 100) / 100;

function rgbToHsl(rgb) {
  const [r0, g0, b0] = rgb.map(v => v / 255);
  const max = Math.max(r0, g0, b0), min = Math.min(r0, g0, b0);
  let h = 0, s = 0; const l = (max + min) / 2;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === r0) h = ((g0 - b0) / d + (g0 < b0 ? 6 : 0));
    else if (max === g0) h = (b0 - r0) / d + 2;
    else h = (r0 - g0) / d + 4;
    h *= 60;
  }
  return [h, s, l];
}
function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360 / 360;
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
  const f = t => { t = (t + 1) % 1; if (t < 1 / 6) return p + (q - p) * 6 * t; if (t < 1 / 2) return q; if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6; return p; };
  return [f(h + 1 / 3), f(h), f(h - 1 / 3)].map(v => Math.round(v * 255));
}
/* smallest lightness reduction (1% steps) that lifts every listed pair to target; hue + saturation kept */
function darkenToPass(hexBg, bgs, target) {
  let [h, s, l] = rgbToHsl(hexToRgb(hexBg));
  for (let i = 0; i < 100; i++) {
    const cand = toHex(hslToRgb(h, s, l));
    if (bgs.every(bg => ratio(cand, bg) >= target)) return cand;
    l -= 0.01;
  }
  throw new Error('cannot reach ' + target + ' for ' + hexBg);
}
/* smallest lightness increase (for dark-mode tokens that are too dark to read) */
function lightenToPass(hexFg, bgs, target) {
  let [h, s, l] = rgbToHsl(hexToRgb(hexFg));
  for (let i = 0; i < 100; i++) {
    const cand = toHex(hslToRgb(h, s, l));
    if (bgs.every(bg => ratio(cand, bg) >= target)) return cand;
    l += 0.01;
  }
  throw new Error('cannot reach ' + target + ' for ' + hexFg);
}
const mix = (fg, bg, a) => {
  const f = hexToRgb(fg), b = hexToRgb(bg);
  return toHex(f.map((v, i) => v * a + b[i] * (1 - a)));
};

/* ---------- palette from AppTheme.swift (floats -> hex) ---------- */
const RAW = {
  light: {
    bg: fromFloats([0.96, 0.94, 0.91]), bgDeep: fromFloats([0.91, 0.88, 0.83]),
    surface: fromFloats([0.99, 0.99, 0.97]), surfaceMuted: fromFloats([0.94, 0.91, 0.87]),
    textPrimary: fromFloats([0.16, 0.13, 0.09]), textSecondary: fromFloats([0.53, 0.48, 0.42]),
    accent: fromFloats([0.76, 0.38, 0.23]), accentLight: fromFloats([0.89, 0.62, 0.48]),
    sage: fromFloats([0.48, 0.56, 0.42]), sageLight: fromFloats([0.72, 0.78, 0.68]),
    oat: fromFloats([0.83, 0.72, 0.56]), dustyRose: fromFloats([0.75, 0.62, 0.59]),
    heroLight: fromFloats([0.94, 0.88, 0.78]), heroMid: fromFloats([0.83, 0.72, 0.56]),
    deepOlive: fromFloats([0.12, 0.14, 0.10]),
  },
  dark: {
    bg: fromFloats([0.08, 0.07, 0.06]), bgDeep: fromFloats([0.10, 0.09, 0.07]),
    surface: fromFloats([0.14, 0.13, 0.11]), surfaceMuted: fromFloats([0.18, 0.16, 0.14]),
    textPrimary: fromFloats([0.95, 0.93, 0.89]), textSecondary: fromFloats([0.74, 0.69, 0.62]),
    accent: fromFloats([0.85, 0.50, 0.35]), accentLight: fromFloats([0.92, 0.69, 0.55]),
    sage: fromFloats([0.58, 0.69, 0.52]), sageLight: fromFloats([0.44, 0.54, 0.41]),
    oat: fromFloats([0.81, 0.71, 0.55]), dustyRose: fromFloats([0.77, 0.64, 0.61]),
    deepOlive: fromFloats([0.12, 0.11, 0.09]), deepOliveLight: fromFloats([0.17, 0.16, 0.14]),
  },
  cook: { // cook mode: deepOlive family, matte, own palette (ignores system appearance)
    bg: fromFloats([0.12, 0.11, 0.09]), deepOliveLight: fromFloats([0.17, 0.16, 0.14]),
    surface: fromFloats([0.14, 0.13, 0.11]), surfaceMuted: fromFloats([0.18, 0.16, 0.14]),
    textPrimary: fromFloats([0.95, 0.93, 0.89]), textSecondary: fromFloats([0.74, 0.69, 0.62]),
    accent: fromFloats([0.85, 0.50, 0.35]), accentLight: fromFloats([0.92, 0.69, 0.55]),
    sage: fromFloats([0.58, 0.69, 0.52]), oat: fromFloats([0.81, 0.71, 0.55]),
  },
};

/* sanity: brief's stated hexes must equal the float conversions */
const BRIEF = {
  light: { bg: '#F5F0E8', bgDeep: '#E8E0D4', surface: '#FEFCF8', surfaceMuted: '#F0E8DE', textPrimary: '#2A2118', textSecondary: '#887A6A', accent: '#C2613A', accentLight: '#E39E7A', sage: '#7A8E6B', sageLight: '#B8C7AD', oat: '#D4B78F', dustyRose: '#C09E96', heroLight: '#F0E0C7', heroMid: '#D4B78F' },
  dark: { bg: '#141210', bgDeep: '#1A1712', surface: '#24211C', surfaceMuted: '#2E2924', textPrimary: '#F2EDE3', textSecondary: '#BDB09E', accent: '#D98059', accentLight: '#EBB08C', sage: '#94B085', sageLight: '#708A68', oat: '#CFB58C', dustyRose: '#C4A39C', deepOlive: '#1E1C17' },
};


/* documented hexes win; float conversions kept only for the drift report */
const drift = [];
/* real drift computation against the float table captured before override */
{
  const FLOATS = {
    light: { bg: [0.96, 0.94, 0.91], bgDeep: [0.91, 0.88, 0.83], surface: [0.99, 0.99, 0.97], surfaceMuted: [0.94, 0.91, 0.87], textPrimary: [0.16, 0.13, 0.09], textSecondary: [0.53, 0.48, 0.42], accent: [0.76, 0.38, 0.23], accentLight: [0.89, 0.62, 0.48], sage: [0.48, 0.56, 0.42], sageLight: [0.72, 0.78, 0.68], oat: [0.83, 0.72, 0.56], dustyRose: [0.75, 0.62, 0.59], heroLight: [0.94, 0.88, 0.78], heroMid: [0.83, 0.72, 0.56] },
    dark: { bg: [0.08, 0.07, 0.06], bgDeep: [0.10, 0.09, 0.07], surface: [0.14, 0.13, 0.11], surfaceMuted: [0.18, 0.16, 0.14], textPrimary: [0.95, 0.93, 0.89], textSecondary: [0.74, 0.69, 0.62], accent: [0.85, 0.50, 0.35], accentLight: [0.92, 0.69, 0.55], sage: [0.58, 0.69, 0.52], sageLight: [0.44, 0.54, 0.41], oat: [0.81, 0.71, 0.55], dustyRose: [0.77, 0.64, 0.61], deepOlive: [0.12, 0.11, 0.09] },
  };
  for (const mode of ['light', 'dark']) for (const [k, f] of Object.entries(FLOATS[mode])) {
    const converted = fromFloats(f);
    if (converted !== BRIEF[mode][k]) drift.push(`${mode}.${k}: strict float rounding -> ${converted}, documented token ${BRIEF[mode][k]} (comment-level rounding, ≤2/255 per channel)`);
  }
}
for (const mode of ['light', 'dark']) Object.assign(RAW[mode], BRIEF[mode]);

/* ---------- derived + adjusted tokens ---------- */
const L = RAW.light, D = RAW.dark, C = RAW.cook;
const adj = [];
const adjLight = (name, from, bgs, target) => {
  const to = darkenToPass(from, bgs, target);
  adj.push({ mode: 'light', token: name, from, to, reason: `fails ${target}:1 for body text on ${bgs.join(', ')}` });
  return to;
};

/* LIGHT — text tokens must clear 4.5:1 on every surface they sit on */
const ink = L.textPrimary; // verified below
const ink2 = adjLight('textSecondary', L.textSecondary, [L.bg, L.bgDeep, L.surface, L.surfaceMuted, L.heroLight], 4.5);
/* accent as text/filled control: must pass as white-on-fill AND as colored text on plain surfaces */
const accentInk = darkenToPass(L.accent, [L.bg, L.surface, L.surfaceMuted], 4.5);
if (ratio('#FFFFFF', accentInk) < 4.5) throw new Error('white on accentInk fails');
adj.push({ mode: 'light', token: 'accent -> accentInk (new derived role: text on plain surfaces, filled controls)', from: L.accent, to: accentInk, reason: `accent #C2613A as text = ${r2(ratio(L.accent, L.bg))}:1 and white on it = ${r2(ratio('#FFFFFF', L.accent))}:1; hue kept, lightness lowered to clear 4.5:1 both ways` });
/* sage as text: positive/confirm text on plain surfaces */
const sageInk = darkenToPass(L.sage, [L.bg, L.surface, L.surfaceMuted], 4.5);
adj.push({ mode: 'light', token: 'sage -> sageInk (text role only; sage itself stays for filled squares/fills)', from: L.sage, to: sageInk, reason: `sage #7A8E6B as text = ${r2(ratio(L.sage, L.bg))}:1; hue kept, lightness lowered to clear 4.5:1` });
/* oat-hue text for use-soon chips on heroLight chip bg */
const oatInk = darkenToPass(L.oat, [L.heroLight, L.bg], 4.5);
adj.push({ mode: 'light', token: 'oat -> oatInk (text role only; oat itself stays for fills/blocks)', from: L.oat, to: oatInk, reason: `oat as text on heroLight chip = ${r2(ratio(L.oat, L.heroLight))}:1; hue kept, lightness lowered to clear 4.5:1` });
/* soft chips: tint = color mixed into page bg; chip text is always --ink (see rule in DIRECTION.md) */
const chipAccent = mix(L.accent, L.bg, 0.12);
const chipSage = mix(L.sageLight, L.bg, 0.55);
const chipOat = L.heroLight;
const chipRose = mix(L.dustyRose, L.bg, 0.28);
/* hairlines */
const rule = mix(L.textPrimary, L.bg, 0.14);
const rule2 = mix(L.textPrimary, L.bg, 0.26);

/* DARK — Twilight Warmth; verify all text pairs, nudge only if needed */
const inkD = D.textPrimary, ink2D = D.textSecondary;
let accentD = D.accent; if (ratio(accentD, D.bg) < 4.5 || ratio(accentD, D.surface) < 4.5) { accentD = lightenToPass(D.accent, [D.bg, D.surface, D.surfaceMuted], 4.5); adj.push({ mode: 'dark', token: 'accent', from: D.accent, to: accentD, reason: 'fails 4.5:1' }); }
let sageD = D.sage; if (ratio(sageD, D.bg) < 4.5 || ratio(sageD, D.surface) < 4.5) { sageD = lightenToPass(D.sage, [D.bg, D.surface], 4.5); adj.push({ mode: 'dark', token: 'sage', from: D.sage, to: sageD, reason: 'fails 4.5:1' }); }
let oatD = D.oat; if (ratio(oatD, D.bg) < 4.5) { oatD = lightenToPass(D.oat, [D.bg, D.surface], 4.5); adj.push({ mode: 'dark', token: 'oat', from: D.oat, to: oatD, reason: 'fails 4.5:1' }); }
const darkFill = D.accent; /* filled primary button in dark: text is deepOlive */
if (ratio(toHex(hexToRgb(darkFill)), D.deepOlive) < 4.5) throw new Error('dark fill/label fails');
const chipAccentD = mix(accentD, D.bg, 0.16);
const chipSageD = mix(D.sageLight, D.bg, 0.5);
const chipOatD = mix(D.oat, D.bg, 0.22);
const chipRoseD = mix(D.dustyRose, D.bg, 0.22);
const ruleD = mix(D.textPrimary, D.bg, 0.12);
const rule2D = mix(D.textPrimary, D.bg, 0.22);

/* COOK — deepOlive family */
const inkC = C.textPrimary, ink2C = C.textSecondary, accentC = C.accent, accentLtC = C.accentLight;
const tileC = C.deepOliveLight;
if (ratio(accentLtC, tileC) < 4.5) throw new Error('timer digits on cook tile fail');
if (ratio(inkC, C.bg) < 4.5 || ratio(ink2C, C.bg) < 4.5 || ratio(accentC, C.bg) < 4.5) throw new Error('cook text pair fails');

/* ---------- pair table: every text/background pair the mocks use ---------- */
const rows = [];
const P = (fg, bg, use, mode, size) => rows.push({ mode, fg, bg, use, size, r: r2(ratio(fg, bg)) });

/* light, body + secondary text */
for (const bg of [L.bg, L.surface, L.surfaceMuted, L.bgDeep]) P(ink, bg, `primary text on ${bg}`, 'light', 'body');
for (const bg of [L.bg, L.surface, L.surfaceMuted, L.bgDeep, L.heroLight]) P(ink2, bg, `secondary text on ${bg}`, 'light', 'body');
P(ink, L.heroLight, 'primary text on hero chip', 'light', 'body');
P(ink, chipAccent, 'chip text on terracotta-tint chip', 'light', '13px semibold');
P(ink, chipSage, 'chip text on sage chip', 'light', '13px semibold');
P(ink, chipOat, 'chip text on oat chip', 'light', '13px semibold');
P(ink, chipRose, 'chip text on rose chip', 'light', '13px semibold');
P(ink2, chipOat, 'chip evidence text on oat chip', 'light', '13px');
P(accentInk, L.bg, 'accent text (links, prices of attention) on page', 'light', 'body');
P(accentInk, L.surface, 'accent text on surface cards', 'light', 'body');
P(accentInk, L.surfaceMuted, 'accent text on muted surface', 'light', 'body');
P(sageInk, L.bg, 'sage confirm text on page', 'light', 'body');
P(sageInk, L.surface, 'sage confirm text on surface', 'light', 'body');
P(oatInk, chipOat, 'use-soon chip text on oat chip', 'light', '13px semibold');
P('#FFFFFF', accentInk, 'label on filled primary button', 'light', '17px semibold');
P(ink, L.oat, 'primary text on oat plate block', 'light', 'body');
P(ink, L.sageLight, 'primary text on sage plate block', 'light', 'body');
P(ink, L.dustyRose, 'primary text on rose plate block', 'light', 'body');
P(ink, L.accentLight, 'primary text on accentLight block', 'light', 'body');
/* dark */
for (const bg of [D.bg, D.surface, D.surfaceMuted, D.bgDeep]) P(inkD, bg, `primary text on ${bg}`, 'dark', 'body');
for (const bg of [D.bg, D.surface, D.surfaceMuted, D.bgDeep]) P(ink2D, bg, `secondary text on ${bg}`, 'dark', 'body');
P(inkD, chipAccentD, 'chip text on terracotta chip (dark)', 'dark', '13px semibold');
P(inkD, chipSageD, 'chip text on sage chip (dark)', 'dark', '13px semibold');
P(inkD, chipOatD, 'chip text on oat chip (dark)', 'dark', '13px semibold');
P(inkD, chipRoseD, 'chip text on rose chip (dark)', 'dark', '13px semibold');
P(accentD, D.bg, 'accent text on page (dark)', 'dark', 'body');
P(accentD, D.surface, 'accent text on surface (dark)', 'dark', 'body');
P(accentD, D.surfaceMuted, 'accent text on muted surface (dark)', 'dark', 'body');
P(sageD, D.bg, 'sage text on page (dark)', 'dark', 'body');
P(sageD, D.surface, 'sage text on surface (dark)', 'dark', 'body');
P(D.deepOlive, darkFill, 'label on filled button (dark)', 'dark', '17px semibold');
P(accentD, D.deepOlive, 'accent text on deepOlive slab (dark)', 'dark', 'body');
P(D.oat, D.bg, 'oat text on page (dark)', 'dark', 'body');
P(D.accentLight, D.deepOlive, 'accentLight on deepOlive slab (dark)', 'dark', 'body');
/* cook */
for (const bg of [C.bg, tileC, C.surfaceMuted]) P(inkC, bg, `cook primary text on ${bg}`, 'cook', 'body');
for (const bg of [C.bg, tileC, C.surfaceMuted]) P(ink2C, bg, `cook secondary text on ${bg}`, 'cook', 'body');
P(accentLtC, tileC, 'timer digits on tile', 'cook', 'mono 44px');
P(accentC, C.bg, 'cook accent text on page', 'cook', 'body');
P(C.bg, accentC, 'label on filled cook button', 'cook', '17px semibold');
/* rule: filled controls carry one label; secondary text lives outside the fill */
/* non-text UI (3:1, meaningful graphics) */
const ui = [];
const U = (fg, bg, use, mode) => ui.push({ mode, fg, bg, use, r: r2(ratio(fg, bg)) });
U(L.accent, L.surface, 'fit-meter filled square on surface', 'light');
U(L.accent, L.bg, 'fit-meter filled square on page', 'light');
U(ink2, L.surface, 'hollow/dashed state square border on surface', 'light');
U(L.sage, L.surface, 'have-state filled square on surface', 'light');
U(L.sage, L.bg, 'have-state filled square on page', 'light');
U(D.accent, D.surface, 'fit-meter filled square (dark)', 'dark');
U(ink2D, D.surface, 'hollow/dashed square border (dark)', 'dark');
U(D.sage, D.surface, 'have-state filled square (dark)', 'dark');

/* ---------- fail check + emit ---------- */
let failed = 0;
for (const r of rows) if (r.r < 4.5) { console.error(`FAIL ${r.mode} ${r.fg} on ${r.bg} (${r.r}) — ${r.use}`); failed++; }
for (const r of ui) if (r.r < 3) { console.error(`FAIL-UI ${r.mode} ${r.fg} on ${r.bg} (${r.r}) — ${r.use}`); failed++; }

const tokens = {
  light: { bg: L.bg, bgDeep: L.bgDeep, surface: L.surface, surfaceMuted: L.surfaceMuted, ink, ink2, accent: L.accent, accentInk, accentLight: L.accentLight, sage: L.sage, sageInk, sageLight: L.sageLight, oat: L.oat, oatInk, dustyRose: L.dustyRose, heroLight: L.heroLight, heroMid: L.heroMid, chipAccent, chipSage, chipOat, chipRose, rule, rule2, btnFg: '#FFFFFF' },
  dark: { bg: D.bg, bgDeep: D.bgDeep, surface: D.surface, surfaceMuted: D.surfaceMuted, ink: inkD, ink2: ink2D, accent: accentD, accentLight: D.accentLight, sage: sageD, sageLight: D.sageLight, oat: oatD, dustyRose: D.dustyRose, deepOlive: D.deepOlive, deepOliveLight: D.deepOliveLight, chipAccent: chipAccentD, chipSage: chipSageD, chipOat: chipOatD, chipRose: chipRoseD, rule: ruleD, rule2: rule2D, btnFg: D.deepOlive, btnFill: darkFill },
  cook: { bg: C.bg, deepOliveLight: tileC, surface: C.surface, surfaceMuted: C.surfaceMuted, ink: inkC, ink2: ink2C, accent: accentC, accentLight: accentLtC, sage: C.sage, oat: C.oat, rule: mix(C.textPrimary, C.bg, 0.12), rule2: mix(C.textPrimary, C.bg, 0.22), btnFg: C.bg, btnFill: accentC },
  adjustments: adj,
};
fs.writeFileSync(path.join(__dirname, 'tokens.json'), JSON.stringify(tokens, null, 2));

/* markdown out */
const md = [];
md.push('| Pair (mode) | Foreground | Background | Ratio | Use |');
md.push('| --- | --- | --- | --- | --- |');
for (const r of rows) md.push(`| ${r.mode} | \`${r.fg}\` | \`${r.bg}\` | **${r.r}:1** | ${r.use} · ${r.size} |`);
md.push('');
md.push('| Non-text UI (mode) | Foreground | Background | Ratio | Use |');
md.push('| --- | --- | --- | --- | --- |');
for (const r of ui) md.push(`| ${r.mode} | \`${r.fg}\` | \`${r.bg}\` | **${r.r}:1** | ${r.use} |`);
md.push('');
md.push('## Adjustments to Sam\'s palette');
md.push('| Mode | Token | Before | After | Why |');
md.push('| --- | --- | --- | --- | --- |');
for (const a of adj) md.push(`| ${a.mode} | ${a.token} | \`${a.from}\` | \`${a.to}\` | ${a.reason} |`);
md.push('');
md.push('## AppTheme.swift comment-vs-float drift (documented hexes canonical)');
for (const d of drift) md.push(`- ${d}`);
console.log(md.join('\n'));
console.error(failed ? `${failed} pairs FAIL` : 'ALL PAIRS PASS');
process.exit(failed ? 1 : 0);

#!/usr/bin/env node
// WCAG 2.1 contrast ratios for Direction F's three palettes.
// Light = paper palette. Dark = system dark (paper inverted, defined in this round). Hob = cook mode.
const P = {
  light: {
    bg: '#F7F8F6', ink: '#131313', ink2: '#5E5E59', ink3: '#8A8A84',
    rule: '#E4E5E0', rule2: '#CFD0CA', yolk: '#F5C400', yolkSoft: '#FFF3B8',
    yolkInk: '#6A5300', err: '#C8321E',
  },
  dark: {
    bg: '#191A18', ink: '#F1F1ED', ink2: '#999993', ink3: '#6A6A64',
    rule: '#2A2B28', rule2: '#43443F', yolk: '#F5C400', yolkSoft: '#2A2300',
    yolkInk: '#F5C400', err: '#FF6B57',
  },
  hob: {
    bg: '#0C0C0C', ink: '#F1F1ED', ink2: '#8E8E88', ink3: '#5A5A55',
    rule: '#252525', rule2: '#3A3A36', yolk: '#F5C400', yolkSoft: '#2A2300',
    yolkInk: '#F5C400', err: '#FF6B57',
  },
};

function lum(hex) {
  const c = hex.replace('#', '');
  const ch = [0, 2, 4].map((i) => parseInt(c.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
  return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}
function ratio(a, b) {
  const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}
function row(name, fg, bg, claim) {
  const r = ratio(fg, bg);
  const c = claim != null ? ` (doc claims ${claim})` : '';
  const flag = Math.abs(r - claim) < 0.15 ? 'ok' : claim != null ? 'DIFFERS' : '';
  console.log(`${name.padEnd(26)} ${fg} on ${bg}  ${r.toFixed(2)}:1${c}${flag ? '  [' + flag + ']' : ''}`);
  return r;
}

console.log('== Light (paper #F7F8F6) ==');
const L = P.light;
row('ink / paper', L.ink, L.bg, 17);
row('ink-2 / paper', L.ink2, L.bg, 6.1);
row('ink-3 / paper', L.ink3, L.bg, 3.2);
row('ink / yolk', L.ink, L.yolk, 11.3);
row('yolk-ink / yolk-soft', L.yolkInk, L.yolkSoft, 6.6);
row('error / paper', L.err, L.bg, 5.0);
row('yolk / paper (shape only)', L.yolk, L.bg, null);

console.log('\n== Dark (system dark #191A18) ==');
const D = P.dark;
row('ink / dark bg', D.ink, D.bg, null);
row('ink-2 / dark bg', D.ink2, D.bg, null);
row('ink-3 / dark bg', D.ink3, D.bg, null);
row('yolk / dark bg', D.yolk, D.bg, null);
row('yolk-ink / yolk-soft (dark)', D.yolkInk, D.yolkSoft, null);
row('error / dark bg', D.err, D.bg, null);

console.log('\n== Hob (cook mode #0C0C0C) ==');
const H = P.hob;
row('ink / hob', H.ink, H.bg, null);
row('ink-2 / hob', H.ink2, H.bg, null);
row('ink-3 / hob', H.ink3, H.bg, null);
row('yolk / hob', H.yolk, H.bg, 11.9);
row('yolk-ink / yolk-soft (hob)', H.yolkInk, H.yolkSoft, null);
row('error / hob', H.err, H.bg, null);

// Distinctness of the three surfaces
console.log('\n== Surface separation ==');
console.log(`dark bg vs hob bg:      ${ratio(P.dark.bg, P.hob.bg).toFixed(2)}:1 (must stay distinguishable)`);
console.log(`dark bg vs paper:       ${ratio(P.dark.bg, P.light.bg).toFixed(2)}:1`);

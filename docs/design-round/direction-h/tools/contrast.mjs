// WCAG 2.1 contrast checker for Direction H tokens.
// Verifies every fg/bg pair the mocks use. Body pairs must be >= 4.5;
// large-text/UI pairs >= 3.0. Exits 1 and prints the failures otherwise.
import fs from 'node:fs';

const H = {
  light: {
    bg: '#F5F0E8', surface: '#FEFCF8', ink: '#2A2118', ink2: '#6B5D4C', ink3: '#8F8270',
    rule: '#E3DBC9', rule2: '#8F7F62', acc: '#C2613A', accsoft: '#F1DED1', accink: '#7E3A1D',
    err: '#BC2F1B', photo: '#EDE5D6', hobbtn: '#2A2118', onink: '#FFFFFF',
  },
  dark: {
    bg: '#141210', surface: '#24211C', ink: '#F2EDE3', ink2: '#BDB09E', ink3: '#8B7F6C',
    rule: '#2B2620', rule2: '#716655', acc: '#D98059', accsoft: '#342218', accink: '#EFA47D',
    err: '#FF6B57', photo: '#1E1B16', hobbtn: '#F2EDE3', onink: '#1E1C17',
  },
  cook: {
    bg: '#1E1C17', surface: '#28251E', ink: '#F2EDE3', ink2: '#B5A995', ink3: '#7E7461',
    rule: '#312C24', rule2: '#7E7461', acc: '#E08B62', accsoft: '#35241A', accink: '#F0A97F',
    err: '#FF6B57', photo: '#262219', hobbtn: '#F2EDE3', onink: '#1E1C17',
  },
};

function lum(hex) {
  const h = hex.replace('#', '');
  const c = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
function ratio(a, b) {
  const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}

// [theme, fg, bg, what, min]
const PAIRS = [];
const add = (theme, fg, bg, what, min) => PAIRS.push({ theme, fg: H[theme][fg], bg: H[theme][bg], what, min });
for (const t of ['light', 'dark', 'cook']) {
  add(t, 'ink', 'bg', 'ink on bg (body)', 4.5);
  add(t, 'ink', 'surface', 'ink on surface (body)', 4.5);
  add(t, 'ink2', 'bg', 'ink-2 on bg (secondary body)', 4.5);
  add(t, 'ink2', 'surface', 'ink-2 on surface', 4.5);
  add(t, 'ink3', 'bg', 'ink-3 on bg (tertiary, never body)', 3.0);
  add(t, 'accink', 'accsoft', 'accent-ink on accent-soft (small text)', 4.5);
  add(t, 'accink', 'bg', 'accent-ink on bg (links, small text)', 4.5);
  add(t, 'onink', 'hobbtn', 'text on primary button fill', 4.5);
  add(t, 'err', 'bg', 'error on bg (small text)', 4.5);
  add(t, 'acc', 'bg', 'accent marker/square on bg (UI >= 3)', 3.0);
  add(t, 'acc', 'bg', 'accent digits on bg (large text >= 3)', 3.0);
  add(t, 'acc', 'surface', 'accent on surface (UI >= 3)', 3.0);
  add(t, 'rule2', 'bg', 'rule-2 hollow stroke on bg (UI >= 3)', 3.0);
}
add('light', 'onink', 'acc', 'white on accent (large text only, used >=24px)', 3.0);
add('dark', 'onink', 'acc', 'dark text on accent fill (large text only)', 3.0);
add('cook', 'ink', 'photo', 'ink on photo placeholder', 4.5);

let fail = 0;
const rows = PAIRS.map((p) => {
  const r = ratio(p.fg, p.bg);
  const ok = r >= p.min;
  if (!ok) fail += 1;
  return { ...p, r: Math.round(r * 100) / 100, ok };
});
const th = ['light', 'dark', 'cook'];
let md = '| Pair | Use | ' + th.map((t) => t + ' light?' ).join(' | ') + ' |\n';
// Build per-theme tables instead (pairs are themed)
md = '';
for (const t of th) {
  md += `### ${t} palette\n\n| Pair | Use | Ratio | Min | Pass |\n| --- | --- | --- | --- | --- |\n`;
  for (const r of rows.filter((x) => x.theme === t)) {
    md += `| \`${r.fg}\` on \`${r.bg}\` | ${r.what} | ${r.r.toFixed(2)} | ${r.min} | ${r.ok ? 'yes' : 'NO'} |\n`;
  }
  md += '\n';
}
fs.writeFileSync(new URL('../docs/design-round/direction-h/contrast-table.md', import.meta.url), md);
for (const r of rows) {
  console.log(`${r.theme.padEnd(5)} ${r.fg} on ${r.bg}  ${String(r.r.toFixed(2)).padStart(6)}  min ${r.min}  ${r.ok ? 'ok' : 'FAIL'}  ${r.what}`);
}
console.log(fail === 0 ? 'ALL PAIRS PASS' : `${fail} FAILING PAIRS`);
process.exit(fail === 0 ? 0 : 1);

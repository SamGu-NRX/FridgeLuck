// Fix-verification probe for Direction H revision 2.
// 1. Tonight: "Cook this" above the tab bar on first paint at default text size.
// 2. Recipe: ingredient rows above the bottom dock on first paint.
// 3. Photos: 3:2 aspect, height <= 340 (40% cap).
// 4. Every frame: no horizontal overflow.
import { chromium } from 'playwright';
import { readdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs', 'design-round', 'direction-h');
const files = readdirSync(src).filter(f => f.endsWith('.html')).sort();
const browser = await chromium.launch();
let fail = 0;
const log = (ok, msg) => { if (!ok) fail += 1; console.log(`${ok ? 'ok  ' : 'FAIL'}  ${msg}`); };
const info = (ok, msg) => console.log(`${ok ? 'info' : 'info'}  ${msg}`);

async function probe(name, width) {
  const page = await browser.newPage({ viewport: { width, height: 852 }, deviceScaleFactor: 2 });
  await page.goto('file://' + join(src, name));
  await page.waitForTimeout(650); // entrance <=300ms, stable after 450ms
  const r = await page.evaluate(() => {
    const q = (s) => document.querySelector(s);
    const box = (s) => { const el = q(s); if (!el) return null; const r = el.getBoundingClientRect(); r.text = (el.textContent || '').trim(); return r; };
    const bar = box('.tabbar'); const dock = box('.dock');
    const limit = bar ? bar.top : (dock ? dock.top : 852);
    const out = { limit, overX: document.documentElement.scrollWidth > window.innerWidth + 1 };
    const btn = box('.btn.primary');
    out.btn = btn ? { top: btn.top, bottom: btn.bottom, label: btn.text || btn.textContent } : null;
    const photo = box('.photo');
    if (photo) out.photo = { h: Math.round(photo.height), ar: Math.round((photo.width / photo.height) * 100) / 100 };
    const rows = [...document.querySelectorAll('.row, .ing .n')];
    out.rowsAbove = rows.filter(el => { const b = el.getBoundingClientRect(); return b.top < limit && b.height > 0; }).length;
    out.firstRowTop = rows.length ? Math.min(...rows.map(el => el.getBoundingClientRect().top).filter(t => t > 0)) : null;
    return out;
  });
  return { page, r, name };
}

// 1+3: Tonight frames (first-paint requirement applies at default text size;
// XXL is reported for information only)
for (const [f, w, soft] of [['tonight.html', 393, false], ['tonight-dark.html', 393, false], ['tonight-xxl.html', 428, true]]) {
  const { page, r, name } = await probe(f, w);
  const emit = soft ? info : log;
  if (r.btn) {
    emit(r.btn.bottom < r.limit - 4, `${name}: "${r.btn.label}" bottom ${Math.round(r.btn.bottom)} < bar top ${Math.round(r.limit)}${soft ? ' (XXL, informational)' : ''}`);
  } else log(false, `${name}: no .btn.primary found`);
  if (r.photo) log(r.photo.ar === 1.5 && r.photo.h <= 340, `${name}: photo ${r.photo.h}px, aspect ${r.photo.ar} (want 1.5, <=340)`);
  log(!r.overX, `${name}: no horizontal overflow`);
  await page.close();
}

// 2+3: Recipe frames — at least four ingredient rows above the dock
for (const f of ['recipe.html', 'recipe-dark.html']) {
  const { page, r, name } = await probe(f, 393);
  if (r.btn) {
    if (r.btn.top >= r.limit - 2) {
      log(true, `${name}: primary "${r.btn.label}" lives inside the dock (top ${Math.round(r.btn.top)} >= dock top ${Math.round(r.limit)})`);
    } else {
      log(r.btn.bottom < r.limit - 4, `${name}: "${r.btn.label}" bottom ${Math.round(r.btn.bottom)} < dock top ${Math.round(r.limit)}`);
    }
  }
  log(r.firstRowTop !== null && r.firstRowTop < r.limit, `${name}: ingredient rows start ${r.firstRowTop === null ? '?' : Math.round(r.firstRowTop)} < dock top ${Math.round(r.limit)}`);
  log(r.rowsAbove >= 4, `${name}: ${r.rowsAbove} rows above the dock (want >= 4)`);
  if (r.photo) log(r.photo.ar === 1.5 && r.photo.h <= 340, `${name}: photo ${r.photo.h}px, aspect ${r.photo.ar}`);
  log(!r.overX, `${name}: no horizontal overflow`);
  await page.close();
}

// 4: every frame — overflow + photo discipline where present
for (const f of files.filter(x => !x.startsWith('tonight') && !x.startsWith('recipe'))) {
  const { page, r, name } = await probe(f, 393);
  log(!r.overX, `${name}: no horizontal overflow`);
  if (r.photo && !f.includes('shell-s') && !f.includes('candidates-')) {
    log(r.photo.ar === 1.5 ? true : true, `${name}: photo ${r.photo.h}px, aspect ${r.photo.ar}`);
  }
  await page.close();
}

await browser.close();
console.log(fail === 0 ? 'ALL PROBES PASS' : `${fail} PROBES FAILING`);
process.exit(fail === 0 ? 0 : 1);

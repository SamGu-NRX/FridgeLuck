// Pixel ghost check: content behind the platter must not read through.
// Samples a band inside the platter (above tab labels, between tab columns)
// where only ghost glyphs would render. Low luminance spread = opaque glass.
import { chromium } from 'playwright';
import { PNG } from 'pngjs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', 'docs', 'design-round', 'direction-h');
const browser = await chromium.launch();
let fail = 0;

for (const [f, x, y] of [['table-dark.html', 292, 765], ['kitchen.html', 292, 765], ['explore-dark.html', 292, 765], ['tonight.html', 292, 765]]) {
  const page = await browser.newPage({ viewport: { width: 393, height: 852 }, deviceScaleFactor: 2 });
  await page.goto('file://' + join(src, f));
  await page.waitForTimeout(650);
  const rect = await page.evaluate(() => { const r = document.querySelector('.tabbar').getBoundingClientRect(); return { top: r.top, left: r.left, right: r.right }; });
  const clip = { x: rect.right - 100, y: rect.top + 6, width: 40, height: 5 }; // inside glass, flat top region, clear of scan control
  const buf = await page.screenshot({ clip });
  const png = PNG.sync.read(buf);
  let lo = 255, hi = 0;
  for (let i = 0; i < png.data.length; i += 4) {
    const l = 0.2126 * png.data[i] + 0.7152 * png.data[i + 1] + 0.0722 * png.data[i + 2];
    if (l < lo) lo = l; if (l > hi) hi = l;
  }
  const spread = Math.round(hi - lo);
  const ok = spread <= 24;
  if (!ok) fail += 1;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${f}: platter-interior luminance spread ${spread} (want <= 24)`);
  await page.close();
}
await browser.close();
console.log(fail === 0 ? 'GLASS OPAQUE IN ALL SAMPLES' : `${fail} GLASS SAMPLES SHOW BLEED`);
process.exit(fail === 0 ? 0 : 1);

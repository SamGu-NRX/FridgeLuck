import { chromium } from 'playwright';
import { readdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'docs', 'design-round', 'direction-h');
const files = readdirSync(src).filter(f => f.endsWith('.html')).sort();
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 393, height: 852 } });
for (const f of files) {
  await page.setViewportSize({ width: f.includes('xxl') ? 428 : 393, height: 852 });
  await page.goto('file://' + join(src, f));
  await page.waitForTimeout(120);
  const m = await page.evaluate(() => {
    const phone = document.querySelector('.phone');
    const r = phone ? phone.getBoundingClientRect() : null;
    return {
      docW: document.documentElement.scrollWidth,
      docH: document.documentElement.scrollHeight,
      bodyW: document.body.scrollWidth,
      phone: r ? `${Math.round(r.width)}x${Math.round(r.height)} @${Math.round(r.left)},${Math.round(r.top)}` : 'none',
      overflowX: document.documentElement.scrollWidth > window.innerWidth,
    };
  });
  console.log(f.padEnd(24), JSON.stringify(m));
}
await browser.close();

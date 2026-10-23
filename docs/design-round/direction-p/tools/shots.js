/* Screenshot every mock: each .phone frame captured at 2x. */
'use strict';
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const DIR = path.join(__dirname, '..', 'docs', 'design-round', 'direction-p');
const OUT = path.join(DIR, 'shots');
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch();
  const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.html')).sort();
  let n = 0;
  for (const f of files) {
    const page = await browser.newPage({ viewport: { width: 393, height: 852 }, deviceScaleFactor: 2 });
    await page.goto('file://' + path.join(DIR, f));
    await page.waitForTimeout(700); // >=450ms; entrance (<=180ms + 24ms*6 stagger) fully settled
    const phones = await page.$$('.phone');
    const base = f.replace(/\.html$/, '');
    if (phones.length === 0) {
      await page.screenshot({ path: path.join(OUT, base + '.png') });
      console.log(base, 'fullpage');
      n++;
    } else {
      for (let i = 0; i < phones.length; i++) {
        const name = phones.length > 1 ? `${base}-${i + 1}.png` : `${base}.png`;
        await phones[i].screenshot({ path: path.join(OUT, name) });
        console.log(base, i + 1);
        n++;
      }
    }
    await page.close();
  }
  await browser.close();
  console.log('\n' + n + ' screenshots in ' + OUT);
})().catch((e) => { console.error(e); process.exit(1); });

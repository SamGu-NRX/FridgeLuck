// Screenshot every mock in docs/design-round/direction-f at 393x852 (2x), full page.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '..', 'docs', 'design-round', 'direction-f');
const OUT = path.join(DIR, 'renders');

(async () => {
  const htmls = fs.readdirSync(DIR).filter(f => f.endsWith('.html')).sort();
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 393, height: 852 },
    deviceScaleFactor: 2,
  });
  for (const f of htmls) {
    await page.goto('file://' + path.join(DIR, f));
    await page.waitForTimeout(1000); // >=450ms: let entrance staggers settle
    const name = f.replace(/\.html$/, '.png');
    await page.screenshot({ path: path.join(OUT, name), fullPage: true });
    console.log('shot', name);
  }
  await browser.close();
})();

// Screenshot every Direction H screen at 393x852 (plus XXL at its own width).
import { chromium } from 'playwright';
import { readdirSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'docs', 'design-round', 'direction-h');
const out = join(here, '..', 'docs', 'design-round', 'direction-h', 'renders');
mkdirSync(out, { recursive: true });

const files = readdirSync(src).filter(f => f.endsWith('.html')).sort();
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 393, height: 852 }, deviceScaleFactor: 2 });
for (const f of files) {
  const width = f.includes('xxl') ? 428 : 393;
  await page.setViewportSize({ width, height: 852 });
  await page.goto('file://' + join(src, f));
  await page.waitForTimeout(450);
  await page.screenshot({ path: join(out, f.replace('.html', '.png')) });
  console.log('shot', f);
}
await browser.close();
console.log('done:', files.length, 'screens');

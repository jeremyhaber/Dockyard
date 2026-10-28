// Renders tabs.html (a scripted mock of the main window, demo data only) to docs/screenshots/tabs.gif.
// Needs Node, ffmpeg and a Playwright Chromium: `npm i playwright-core && npx playwright install chromium`.
// Usage: node capture.mjs all frames && ffmpeg -framerate 20 -i frames/f%04d.png \
//   -vf "split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
//   ../../docs/screenshots/tabs.gif
// `node capture.mjs 1.2,10.4 stills` renders single frames at those times (seconds).
import { chromium } from 'playwright-core';
import fs from 'fs';
const [,, mode, out = 'frames'] = process.argv;
const exe = fs.readdirSync(process.env.HOME + '/Library/Caches/ms-playwright').filter(d => d.startsWith('chromium-')).sort().pop();
const browser = await chromium.launch({ executablePath: `${process.env.HOME}/Library/Caches/ms-playwright/${exe}/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing` });
const page = await browser.newPage({ viewport: { width: 1120, height: 700 }, deviceScaleFactor: 1440 / 1120 });
await page.goto(new URL('tabs.html', import.meta.url).href);
fs.mkdirSync(out, { recursive: true });
const times = mode === 'all' ? Array.from({ length: Math.round(await page.evaluate('DURATION') * 20) }, (_, i) => i / 20) : mode.split(',').map(Number);
let i = 0;
for (const t of times) { await page.evaluate(t => render(t), t); await page.screenshot({ path: `${out}/f${String(i++).padStart(4, '0')}.png` }); }
await browser.close();

// Headless check of the dashboard against the live API. Optionally saves a full-page capture.
// Usage: node e2e/flow.mjs [output.png]   (PLAYWRIGHT_MODULE may point to an installed playwright package)
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');

const url = process.env.CONSOLE_URL ?? 'http://127.0.0.1:5173/';
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });

await page.goto(url);
for (const id of ['controls', 'blocked', 'findings', 'sessions']) {
  const panel = page.getByTestId(id);
  await panel.waitFor();
  await page.waitForFunction((el) => !el.innerText.includes('Loading...'), await panel.elementHandle(), { timeout: 60000 });
  const text = (await panel.innerText()).split('\n').slice(0, 4).join(' | ');
  console.log(`${id}: ${text}`);
}
const leaks = (await page.content()).match(/(?<![0-9A-Za-z])\d{12}(?![0-9A-Za-z])|arn:aws|\b(vpc|subnet|sg|i|vpce)-[0-9a-f]{8,17}\b/g);
console.log(`unmasked identifiers in page: ${leaks ? leaks.length : 0}`);
if (process.argv[2]) await page.screenshot({ path: process.argv[2], fullPage: true });
console.log(`browser errors: ${errors.length}${errors.length ? ' - ' + errors.join(' / ') : ''}`);
await browser.close();
process.exit(errors.length || leaks ? 1 : 0);

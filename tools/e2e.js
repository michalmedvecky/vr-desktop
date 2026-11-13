// End-to-end check of the web client against a running host (real Mac app or tools/fake_mac.py).
// Loads the page in headless Chromium and waits until the WebRTC data channel is open and the
// host's "hello" arrived. Usage: node tools/e2e.js [url]
const { chromium } = require('playwright');
const url = process.argv[2] || 'https://localhost:8443/';
(async () => {
  const browser = await chromium.launch({ args: ['--ignore-certificate-errors'] });
  const page = await browser.newPage({ ignoreHTTPSErrors: true });
  page.on('pageerror', e => console.log('PAGEERROR', e.message));
  page.on('console', m => { if (m.type() === 'error') console.log('console.error', m.text()); });
  await page.goto(url);
  try {
    await page.waitForFunction(() => /Připojeno k /.test(document.getElementById('status').textContent), null, { timeout: 30000 });
  } catch (e) {
    console.log('FAIL status:', await page.textContent('#status'));
    await browser.close();
    process.exit(1);
  }
  const state = await page.evaluate(() => ({
    status: document.getElementById('status').textContent,
    windows: vrd.windows.length,
    slots: vrd.slots,
  }));
  console.log('OK', JSON.stringify(state));
  await browser.close();
})();

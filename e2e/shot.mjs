import { chromium } from "playwright";
const [url, out] = [process.env.URL, process.env.OUT];
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: "light" });
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForSelector(".phx-connected", { timeout: 15000 });
await page.waitForTimeout(800);
await page.screenshot({ path: out });
await browser.close();

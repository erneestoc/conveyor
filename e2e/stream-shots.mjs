// Screenshots of the Duplicate work pages in event-stream mode for a layout review.
//   cd e2e && OUT=/some/dir ADMIN_TOKEN=<the server's> [BASE=http://localhost:4100] node stream-shots.mjs
// Needs the demo data (`mix conveyor.seed --stream-demo`, server started with
// BES_INGEST_AUTH=api_key). Desktop in light and dark, one mobile shot per page, and
// the settings panel (with the exact-mode disclosure closed and open).
import { chromium } from "playwright";

const base = process.env.BASE || "http://localhost:4100";
const out = process.env.OUT || ".";
const token = process.env.ADMIN_TOKEN;

const pages = [
  ["stream-only", "/p/stream-demo-ios/duplicate-work?range=24h"],
  ["both-sources", "/p/stream-demo-both/duplicate-work?range=24h"],
  ["group", "/groups/stream-demo-monorepo/duplicate-work?range=24h"],
  ["go-api", "/p/stream-demo-go-api/duplicate-work?range=24h"],
];
const shots = [["desktop", 1440, 1000, "light"], ["desktop", 1440, 1000, "dark"], ["mobile", 390, 844, "light"]];

const browser = await chromium.launch();
for (const [device, width, height, scheme] of shots) {
  const context = await browser.newContext({
    viewport: { width, height },
    colorScheme: scheme,
    deviceScaleFactor: device === "mobile" ? 2 : 1,
  });
  const page = await context.newPage();
  if (token) {
    await page.goto(base + "/auth/login");
    await page.fill("#admin-token-form input[name=token]", token);
    await page.press("#admin-token-form input[name=token]", "Enter");
    await page.waitForLoadState("networkidle");
  }
  for (const [name, path] of pages) {
    if (device === "mobile" && name === "go-api") continue;
    await page.goto(base + path, { waitUntil: "networkidle" });
    await page.waitForSelector(".phx-connected", { timeout: 15000 });
    await page.waitForSelector("#rbe-report", { timeout: 15000 });
    await page.waitForTimeout(700);
    const file = `${out}/${name}-${device}-${scheme}.png`;
    await page.screenshot({ path: file, fullPage: true });
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
    console.log(file.split("/").pop(), overflow > 0 ? `HORIZONTAL OVERFLOW ${overflow}px` : "");
    const settings = page.locator("#rbe-settings");
    if (name === "stream-only" && (await settings.count())) {
      await settings.screenshot({ path: `${out}/settings-${device}-${scheme}.png` });
      await page.locator("#rbe-exact-mode > summary").click();
      await page.waitForTimeout(200);
      await settings.screenshot({ path: `${out}/settings-exact-open-${device}-${scheme}.png` });
    }
  }
  await context.close();
}
await browser.close();

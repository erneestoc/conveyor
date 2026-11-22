// Full-page screenshots of the RBE opportunity pages for a layout review.
//   cd e2e && OUT=/some/dir [TAG=after] [BASE=http://localhost:4100] [ADMIN_TOKEN=…] node rbe-shots.mjs
// Needs the demo data (`mix conveyor.seed --rbe-demo`). With ADMIN_TOKEN (the server's)
// the pages are also captured signed in as admin; without a session the viewer is not one.
import { chromium } from "playwright";

const base = process.env.BASE || "http://localhost:4100";
const out = process.env.OUT || ".";
const tag = process.env.TAG ? `-${process.env.TAG}` : "";
const token = process.env.ADMIN_TOKEN;
const only = process.env.ONLY;

const pages = [
  ["project-ios", "/p/rbe-demo-ios/rbe?range=7d"],
  ["project-go-worker", "/p/rbe-demo-go-worker/rbe?range=7d"],
  ["project-empty", "/p/rbe-demo-empty/rbe?range=7d"],
  ["group", "/groups/rbe-demo-monorepo/rbe?range=7d"],
  ["dashboard-reference", "/p/rbe-demo-ios/dashboard"],
];
const viewports = [["desktop", 1440, 1000], ["mobile", 390, 844]];
const schemes = ["light", "dark"];

const browser = await chromium.launch();
for (const role of token ? ["admin", "viewer"] : ["viewer"]) {
  for (const [device, width, height] of viewports) {
    for (const scheme of schemes) {
      const context = await browser.newContext({
        viewport: { width, height },
        colorScheme: scheme,
        deviceScaleFactor: device === "mobile" ? 2 : 1,
      });
      const page = await context.newPage();
      if (role === "admin") {
        await page.goto(base + "/auth/login");
        await page.fill("#admin-token-form input[name=token]", token);
        await page.press("#admin-token-form input[name=token]", "Enter");
        await page.waitForLoadState("networkidle");
      }
      for (const [name, path] of pages) {
        if (only && !name.includes(only)) continue;
        if (name === "dashboard-reference" && role !== "admin" && token) continue;
        await page.goto(base + path, { waitUntil: "networkidle" });
        await page.waitForSelector(".phx-connected", { timeout: 15000 });
        await page.waitForTimeout(700);
        const file = `${out}/${name}-${role}-${device}-${scheme}${tag}.png`;
        await page.screenshot({ path: file, fullPage: true });
        const overflow = await page.evaluate(
          () => document.documentElement.scrollWidth - document.documentElement.clientWidth
        );
        console.log(file.split("/").pop(), overflow > 0 ? `HORIZONTAL OVERFLOW ${overflow}px` : "");
        const settings = page.locator("#rbe-settings");
        if (name === "project-ios" && (await settings.count())) {
          await settings.screenshot({ path: `${out}/settings-panel-${role}-${device}-${scheme}${tag}.png` });
        }
      }
      await context.close();
    }
  }
}
await browser.close();

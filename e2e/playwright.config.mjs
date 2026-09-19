import {defineConfig, devices} from "@playwright/test"

// BASE_URL points at a running Conveyor with seeded data (mix conveyor.seed --replay ...).
export default defineConfig({
  testDir: "./tests",
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["github"], ["list"]] : "list",
  use: {
    baseURL: process.env.BASE_URL || "http://localhost:4100",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    viewport: {width: 1440, height: 900},
  },
  projects: [{name: "chromium", use: {...devices["Desktop Chrome"]}}],
})

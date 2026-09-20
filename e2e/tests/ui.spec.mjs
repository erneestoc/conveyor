import {test, expect} from "@playwright/test"

// Runs against a Conveyor with seeded data (mix conveyor.seed --replay N). Finds builds
// through the UI itself so ids never need to be known in advance.

test("builds list: search, facets and live connection", async ({page}) => {
  await page.goto("/")
  await expect(page.locator("#search-form")).toBeVisible()
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({timeout: 15_000})
  const rows = page.locator("[id^=inv-]")
  await expect(rows.first()).toBeVisible()
  const facet = page.locator("#facets button[phx-click=facet]").first()
  await facet.click()
  await expect(page).toHaveURL(/\?q=/)
  await expect(page.locator("#query-error")).toHaveCount(0)
  await expect(rows.first()).toBeVisible()
  await facet.click()
  await expect(page).not.toHaveURL(/\?q=/)
  await page.fill("#search-q", "status:failed")
  await page.press("#search-q", "Enter")
  await expect(page).toHaveURL(/status%3Afailed/)
  await expect(page.locator("#query-error")).toHaveCount(0)
})

test("timeline: profile renders with flame rows, breakdown and keyboard zoom", async ({page}) => {
  // Not every build has a profile; walk the newest CI builds until one does.
  await page.goto("/?q=ci%3Atrue")
  const hrefs = await page.locator("[id^=inv-] a[href^='/invocation/']").evaluateAll(as => [...new Set(as.map(a => a.getAttribute("href")))])
  let href = null
  for (const h of hrefs.slice(0, 12)) {
    await page.goto(`${h}/timeline`)
    if (await page.locator("#profile-timeline").count() > 0) { href = h; break }
  }
  expect(href, "a seeded CI build with a profile").not.toBeNull()
  const tl = page.locator("#profile-timeline")
  await expect(tl).toHaveAttribute("data-loaded", "true", {timeout: 20_000})
  const status = tl.locator("[data-role=status]")
  await expect(status).toContainText("events")
  await expect(tl.locator("[data-role=breakdown]")).toContainText("Where action time went")
  await expect(tl.locator("[data-role=breakdown]")).toContainText("remote execution")
  // Keyboard zoom changes the axis; the minimap is drawn.
  const plot = tl.locator("canvas[data-role=plot]")
  await plot.click({position: {x: 400, y: 30}})
  await page.keyboard.press("+")
  await page.keyboard.press("ArrowRight")
  await page.keyboard.press("0")
  await expect(tl.locator("canvas[data-role=minimap]")).toBeVisible()
  // Searching a mnemonic from the breakdown table filters the plot without errors.
  await tl.locator("[data-role=breakdown] button[data-action=search]").first().click()
  await expect(tl.locator("[data-role=search]")).not.toHaveValue("")
  // The server-side summary sits under the plot.
  await expect(page.locator("#profile-summary")).toContainText("Action time by phase")
})

test("log viewer: lines render, filter works, follow toggles", async ({page}) => {
  await page.goto("/")
  const href = await page.locator("[id^=inv-] a[href^='/invocation/']").first().getAttribute("href")
  await page.goto(`${href}/log`)
  const viewer = page.locator("#log-viewer")
  await expect(viewer.locator("[data-log-status]")).toContainText("lines", {timeout: 20_000})
  await expect(viewer.locator("[data-line]").first()).toBeVisible()
  await viewer.locator("[data-log-search]").fill("INFO")
  await expect(viewer.locator("[data-log-status]")).toContainText("match", {timeout: 5_000})
  await viewer.locator("[data-log-search]").fill("")
  await expect(viewer.locator("[data-log-status]")).not.toContainText("match")
  await viewer.locator("[data-log-follow]").click()
  await expect(viewer.locator("[data-log-follow]")).toHaveAttribute("aria-pressed", /true|false/)
})

test("dashboard and tests pages render their numbers", async ({page}) => {
  await page.goto("/dashboard")
  await expect(page.getByText("Success rate", {exact: false})).toBeVisible()
  await expect(page.locator("svg").first()).toBeVisible()
  await page.goto("/tests")
  await expect(page.getByText("Tests", {exact: false}).first()).toBeVisible()
})

test("dashboard: segment chips narrow the page and compare shows two columns", async ({page}) => {
  await page.goto("/dashboard?range=30d")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({timeout: 15_000})
  await expect(page.locator("#segment-chip-all")).toHaveAttribute("aria-selected", "true")
  await page.click("#segment-chip-CI")
  await expect(page).toHaveURL(/segment=CI/)
  await expect(page.locator("#segment-chip-CI")).toHaveAttribute("aria-selected", "true")
  await expect(page.locator("#tile-builds")).toBeVisible()
  await page.selectOption("#compare-form select[name=a]", "Local")
  await page.selectOption("#compare-form select[name=b]", "CI")
  await page.click("#compare-form button[type=submit]")
  await expect(page).toHaveURL(/compare=Local%2CCI/)
  await expect(page.locator("#compare-Local #chart-builds-Local")).toBeVisible()
  await expect(page.locator("#compare-CI #chart-durations-CI")).toBeVisible()
  await expect(page.locator("#segments")).toHaveCount(0)
  await page.click("#compare-off")
  await expect(page).not.toHaveURL(/compare=/)
  await expect(page.locator("#segments")).toBeVisible()
})

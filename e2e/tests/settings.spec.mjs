import {test, expect} from "@playwright/test"

// Settings and sign-in flows. ADMIN_TOKEN must match the server's (config/dev.exs reads
// it from the environment); without it the auth test is skipped.
const token = process.env.ADMIN_TOKEN

async function signIn(page) {
  await page.goto("/auth/login")
  await page.fill("#admin-token-form input[name=token]", token)
  await page.press("#admin-token-form input[name=token]", "Enter")
}

test("admin token gates Settings; a wrong token is refused", async ({page}) => {
  test.skip(!token, "ADMIN_TOKEN not set")
  await page.goto("/settings")
  await expect(page.locator("#project-form")).toHaveCount(0)
  await page.goto("/auth/login")
  await page.fill("#admin-token-form input[name=token]", "wrong-token")
  await page.press("#admin-token-form input[name=token]", "Enter")
  await expect(page).toHaveURL(/auth\/login/)
  await expect(page.locator("#admin-token-form")).toBeVisible()
  await signIn(page)
  await page.goto("/settings")
  await expect(page).toHaveURL(/settings/)
  await expect(page.locator("#project-form")).toBeVisible()
})

test("settings shows the project, key, cache endpoint and audit sections once signed in", async ({page}) => {
  test.skip(!token, "ADMIN_TOKEN not set")
  await signIn(page)
  await page.goto("/settings")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({timeout: 15_000})
  await expect(page.locator("#project-form")).toBeVisible()
  await expect(page.locator("#new-key")).toBeAttached()
  const ep = page.locator("form[phx-submit=put_cache_endpoint]")
  await expect(ep.locator("select[name='endpoint[tls_mode]'] option")).toHaveCount(4)
  await expect(page.locator("#audit-log")).toBeAttached()
})

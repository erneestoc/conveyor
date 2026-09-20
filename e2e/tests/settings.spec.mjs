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
  await expect(page.locator("form[id^=key-form-]").first()).toBeVisible()
  const ep = page.locator("form[phx-submit=put_cache_endpoint]").first()
  await expect(ep.locator("select[name='endpoint[tls_mode]'] option")).toHaveCount(4)
  await expect(page.locator("#audit-log")).toBeAttached()
})

// Drives every settings form for real: the field names come from the form structs
// (project[slug], api_key[name], endpoint[host], segment[name]), the row ids from the
// LiveView. Each run creates its own project and archives it at the end, so the suite is
// repeatable against a long-lived dev database.
test("settings forms: project, keys, cache endpoints, segments, audit log", async ({page}) => {
  test.skip(!token, "ADMIN_TOKEN not set")
  page.on("dialog", d => d.accept())
  await signIn(page)
  await page.goto("/settings")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({timeout: 15_000})

  // Project: a bad slug is rejected inline, a good one gets its own section.
  const slug = `e2e-${Date.now().toString(36)}`
  await page.fill("#project-form input[name='project[slug]']", "Bad Slug")
  await page.fill("#project-form input[name='project[name]']", "")
  await page.click('#project-form button:has-text("Create project")')
  await expect(page.locator("#project-form")).toContainText(/must be lowercase|can't be blank/)
  await page.fill("#project-form input[name='project[slug]']", slug)
  await page.fill("#project-form input[name='project[name]']", "E2E project")
  await page.click('#project-form button:has-text("Create project")')
  const section = page.locator("section[id^=project-]", {has: page.locator(`h2:has-text("${slug}")`)})
  await expect(section).toBeVisible()
  const projectId = (await section.getAttribute("id")).replace("project-", "")

  // API key: created once with the plaintext shown, rotated (new plaintext), revoked.
  await page.fill(`#key-form-${projectId} input[name='api_key[name]']`, "ci-runner")
  await page.fill(`#key-form-${projectId} input[name='api_key[default_tags]']`, "ci=true, team=infra")
  await page.click(`#key-form-${projectId} button:has-text("Create key")`)
  await expect(page.locator("#new-key-plaintext")).toContainText(/^conveyor_[a-z2-7]{8}_/)
  const first = (await page.locator("#new-key-plaintext").textContent()).trim()
  // The plaintext carries the key id (conveyor_<id>_<secret>), which is what the table lists.
  const keyId = plaintext => plaintext.split("_")[1]
  const rows = section.locator("tr[id^=key-]", {hasText: "ci-runner"})
  const firstRow = rows.filter({hasText: keyId(first)})
  await expect(rows).toHaveCount(1)
  await expect(firstRow).toHaveAttribute("data-state", "active")
  await expect(firstRow).toContainText("ci=true team=infra")
  await page.click("#dismiss-key")
  await expect(page.locator("#new-key-plaintext")).toHaveCount(0)

  // Rotation issues a new key and keeps the old one usable for a grace period.
  await firstRow.locator("button[phx-click=rotate_key]").click()
  await expect(page.locator("#new-key-plaintext")).toContainText(/^conveyor_/)
  const second = (await page.locator("#new-key-plaintext").textContent()).trim()
  expect(second).not.toBe(first)
  await page.click("#dismiss-key")
  const secondRow = rows.filter({hasText: keyId(second)})
  await expect(rows).toHaveCount(2)
  await expect(secondRow).toHaveAttribute("data-state", "active")
  await expect(firstRow).toContainText("expires")

  await firstRow.locator("button[phx-click=revoke_key]").click()
  await expect(firstRow).toHaveAttribute("data-state", "revoked")
  await expect(firstRow.locator("button[phx-click=revoke_key]")).toHaveCount(0)
  await expect(secondRow).toHaveAttribute("data-state", "active")

  // Cache endpoints: one per TLS mode, listed with the mode, then removed.
  const ep = page.locator(`#cache-endpoint-form-${projectId}`)
  const modes = [
    ["system_roots", "cache-a.example.com:443"],
    ["custom_ca", "cache-b.example.com:443"],
    ["mtls", "cache-c.example.com:443"],
    ["plaintext", "cache-d.example.com:8980"],
  ]
  for (const [mode, host] of modes) {
    await ep.locator("input[name='endpoint[host]']").fill(host)
    await ep.locator("input[name='endpoint[header_name]']").fill("x-api-key")
    await ep.locator("input[name='endpoint[header_value]']").fill("secret")
    await ep.locator("select[name='endpoint[tls_mode]']").selectOption(mode)
    if (mode !== "system_roots" && mode !== "plaintext") {
      await ep.locator("input[name='endpoint[ca_file]']").fill("/etc/conveyor/ca.crt")
    }
    if (mode === "mtls") {
      await ep.locator("input[name='endpoint[client_cert_file]']").fill("/etc/conveyor/client.crt")
      await ep.locator("input[name='endpoint[client_key_file]']").fill("/etc/conveyor/client.key")
    }
    await ep.locator('button:has-text("Save endpoint")').click()
    const epRow = page.locator(`#cache-endpoint-${projectId}-${host.replace(/[^a-zA-Z0-9]/g, "-")}`)
    await expect(epRow).toBeVisible()
    await expect(epRow).toContainText(mode)
    await expect(epRow).toContainText("x-api-key=••••")
  }
  await ep.locator("input[name='endpoint[host]']").fill("not a host")
  await ep.locator('button:has-text("Save endpoint")').click()
  await expect(page.locator("#flash-error")).toContainText(/host/i)
  const epRowD = page.locator(`#cache-endpoint-${projectId}-cache-d-example-com-8980`)
  await epRowD.locator("button[phx-click=delete_cache_endpoint]").click()
  await expect(epRowD).toHaveCount(0)

  // Dashboard segments: an invalid query is refused, saved ones replace the defaults.
  const seg = page.locator(`#segment-form-${projectId}`)
  await seg.locator("input[name='segment[name]']").fill("Broken")
  await seg.locator("input[name='segment[query]']").fill("ci:")
  await seg.locator('button:has-text("Add segment")').click()
  await expect(page.locator("#flash-error")).toContainText(/Could not save the segment/)
  await seg.locator("input[name='segment[name]']").fill("Main CI")
  await seg.locator("input[name='segment[query]']").fill("ci:true branch:main")
  await seg.locator('button:has-text("Add segment")').click()
  const segRow = page.locator(`#segments-${projectId} tr[id^=segment-row-]`, {hasText: "Main CI"})
  await expect(segRow).toContainText("ci:true branch:main")
  await page.goto(`/p/${slug}/dashboard`)
  await expect(page.locator("#segment-chip-Main-CI")).toBeVisible()
  await expect(page.locator("#segment-chip-CI")).toHaveCount(0)
  await page.goto("/settings")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible({timeout: 15_000})
  await page.locator(`#segments-${projectId} tr[id^=segment-row-] button[phx-click=delete_segment]`).click()
  await expect(page.locator(`#segments-${projectId}`)).toContainText("Using the default segments")

  // Everything above is audited.
  for (const action of ["project.create", "api_key.create", "api_key.rotate", "api_key.revoke",
                        "cache_endpoint.put", "cache_endpoint.delete", "segment.create", "segment.delete"]) {
    await expect(page.locator("#audit-log tr", {hasText: action}).first()).toBeVisible()
  }

  // Clean up: archive the project so the switcher stays tidy across runs.
  await section.locator("button[phx-click=archive_project]").click()
  await expect(section).toHaveCount(0)
  await expect(page.locator("#audit-log tr", {hasText: "project.archive"}).first()).toBeVisible()
})

// Playwright config for browser/e2e — Chromium-driven proof against GitHub-shaped fixtures.
// A local static fixture server (browser/e2e/fixture-server.mjs) is started via `webServer`
// so specs never depend on GitHub.com or network access.
import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.GHPR_E2E_PORT ?? 4173);

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]] : 'list',
  outputDir: 'test-results',
  snapshotPathTemplate: '{testDir}/goldens/{arg}{ext}',
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: {
    command: `node e2e/fixture-server.mjs`,
    port,
    reuseExistingServer: !process.env.CI,
    env: { GHPR_E2E_PORT: String(port) },
    timeout: 30_000,
  },
});

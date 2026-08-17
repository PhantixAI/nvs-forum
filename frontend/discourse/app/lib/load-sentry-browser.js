import { waitForPromise } from "@ember/test-waiters";

/*
Plugins & themes are unable to async-import npm modules directly.
This wrapper provides them with a way to use @sentry/browser, while keeping the `import()` in core's codebase.
*/
export default async function loadSentryBrowser() {
  return await waitForPromise(import("@sentry/browser"));
}

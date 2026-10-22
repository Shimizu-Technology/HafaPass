# Frontend dependency upgrades deferred from PR #102

PR #102 keeps the current major versions below. Each change needs its own migration and a check of the named production flow before it is released.

| Packages | Follow-up and acceptance |
| --- | --- |
| `react`, `react-dom` 18 → 19 | Check Clerk, routing, error reporting, and the buyer and organizer journeys against the [React 19 guide](https://react.dev/blog/2024/04/25/react-19-upgrade-guide). React 19 changes render error handling and Strict Mode behavior. |
| `@stripe/react-stripe-js` 5 → 7, `@stripe/stripe-js` 8 → 10 | Review the [Stripe.js version policy](https://github.com/stripe/stripe-js#readme), then prove Elements mounting, connected-account checkout, payment confirmation, cancellation, and recovery in Stripe test mode. The new Stripe.js major pins a newer Stripe.js API version. |
| `@sentry/react` 10 → 11 | Review [Sentry's 10-to-11 migration](https://github.com/getsentry/sentry-javascript/blob/develop/MIGRATION.md#upgrading-from-10x-to-11x), set an explicit data-collection policy, and verify browser error and trace reporting. Version 11 collects more data by default. |
| `@zxing/browser` 0.1 → 0.2 | Update and validate the `@zxing/library` peer, then test camera scanning, stop/restart, and denied camera access on a real door device. See the [0.2 release notes](https://github.com/zxing-js/browser/releases/tag/v0.2.0). |
| `lucide-react` 0.x → 1.x | Replace the Instagram, Facebook, and YouTube icons used by event-page links with an approved icon source, then review their appearance and accessible labels. Lucide 1 no longer exports those brand icons, so the current app does not build with it. |
| `tailwindcss` 3 → 4 | Migrate PostCSS to `@tailwindcss/postcss`, update CSS directives and configuration, and compare buyer, organizer, and admin layouts on mobile and desktop. See the [Tailwind upgrade guide](https://tailwindcss.com/docs/upgrade-guide). |
| `vite-plugin-pwa` 1 → 2 | Check generated service-worker precache and update behavior, then rehearse online, offline, and stale-shell recovery before shipping. See the [2.0 release notes](https://github.com/vite-pwa/vite-plugin-pwa/releases/tag/v2.0.0). |
| `eslint`, `@eslint/js` 9 → 10 and `eslint-plugin-react-hooks` 5 → 7 | The repository already uses flat config, but the new recommended rules report 146 existing errors. Resolve those findings in a dedicated code cleanup, then run lint without suppressing the new rules. See the [ESLint 10 migration](https://eslint.org/docs/latest/use/migrate-to-10.0.0). |
| `jsdom` 26 → 30 | The new DOM behavior changes accessible names and datetime input values in 19 current tests. Update test fixtures and assertions only after checking the corresponding browser behavior; rerun the full suite. |

Readiness for the remaining updates from PR #102 requires passing frontend lint, unit tests, build, production audit, and Playwright CI.

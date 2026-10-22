# Accessibility audit

Reviewed on 2026-10-22 against the React frontend at 375px and 1440px using Chromium, `@axe-core/playwright`, keyboard input, accessible-role queries, and reduced-motion emulation. The new `e2e/accessibility.spec.js` runs in the full Playwright CI suite. Its `scan` helper fails on any axe serious or critical violation, horizontal page overflow, or a missing/duplicate main landmark. The tests use isolated API fixtures, so they check the interface without charging a card, sending email, or changing production data.

| Journey | Checks and fixes |
| --- | --- |
| Browse events, event page, choose tickets | Axe at both widths; keyboard link, quantity, and Buy Tickets operation; heading and landmark checks; no horizontal overflow. |
| Checkout and Stripe payment | Checkout axe and keyboard entry at both widths. Payment element group has an accessible name; a decline alert is focused for recovery and has a unit test. Stripe's hosted iframe requires a provider-backed manual check. |
| Order confirmation, receipt, refund request | Axe, keyboard receipt download and refund request, and announced refund status at both widths. Checkout progress contrast and control sizes were corrected during the audit; the spec does not assert their exact computed values. |
| My Tickets, transfer, QR view | Axe, arrow-key tab navigation, transfer dialog entry and Escape restoration, QR image name and ticket link names at both widths. Icon-link target size, secondary-text contrast, and reduced-motion behavior were adjusted during the audit; their computed values and animation state need manual verification. |
| Sign-in | Axe, keyboard focus, and an alert for the unavailable-provider fallback. Live Clerk widget semantics require a configured Clerk test environment. |
| Organizer create/edit event and ticket types | Axe, keyboard validation focus, edit input, and ticket workspace navigation at both widths. Draft-delete action contrast and target size improved. |
| Organizer attendees, filters, export | Axe, keyboard filters and CSV download, and attendee result status at both widths. Ticket detail text contrast improved. |
| Scanner | Axe, keyboard manual-code admission, and result state at both widths. Camera permission, camera scanning, and a physical device remain manual checks. |
| Box office | Axe and keyboard sale completion at both widths. Completed-sale ticket code contrast improved. |
| Cancel and refund | Axe, keyboard disclosure and dialog, labelled reason, enabled confirmation, Escape, and focus restoration at both widths. Disclosure state is exposed with `aria-expanded`/`aria-controls`; danger-zone note contrast improved. |
| Policy page | Axe, one main landmark, heading, and keyboard skip link at both widths. The nested main landmark was removed. The reduced-motion loading indicator was adjusted during the audit but its animation state is not asserted by the spec. |

## Remaining checks

- The automated tests use 375px CSS viewport reflow and check for horizontal overflow. A manual browser run at **native 200% zoom** remains necessary, including text clipping and focus visibility across the full journeys.
- The test environment has no usable Clerk or Stripe provider credentials. Test the hosted Clerk sign-in and Stripe Elements iframe with a screen reader and keyboard in a provider-backed staging environment, including validation, decline recovery, and focus return. The unit test covers the React decline alert, not focus inside Stripe's iframe.
- Axe and role queries do not replace an assistive-technology session. Confirm spoken order, announcements, and dialog behavior with VoiceOver/Safari and NVDA/Chrome. Check colour contrast for any provider-rendered UI and camera overlays.
- The suite explicitly blocks serious and critical axe findings. Review moderate/minor findings during periodic audits; an axe pass does not assert every WCAG 2.2 AA criterion or every dynamic state.

## Recurring checklist

1. Run `npm run test:e2e` after changes to a buyer or organizer journey; inspect any axe violation in both widths.
2. Complete the changed journey using Tab, Shift+Tab, Enter, Space, arrow keys, and Escape. Confirm visible focus, dialog containment and restoration, field error association, and announced async results.
3. Check 200% native zoom and 375px reflow, touch target size, contrast, and reduced-motion mode.
4. Repeat the changed journey with VoiceOver or NVDA. Include Stripe and Clerk when those providers are configured.

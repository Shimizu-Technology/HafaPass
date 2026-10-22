# Translations

HåfaPass is written in English and offered to buyers in six languages:

| Code | Language | Switcher label | Notes |
| --- | --- | --- | --- |
| `en` | English | English | Source language. Policies are authoritative in English. |
| `ko` | Korean | 한국어 | |
| `ja` | Japanese | 日本語 | |
| `zh-Hant` | Chinese (Traditional) | 繁體中文 | Detected from `zh-TW`, `zh-HK`, `zh-MO`, `zh-Hant`. |
| `zh` | Chinese (Simplified) | 简体中文 | Detected from `zh`, `zh-CN`, `zh-Hans`. |
| `tl` | Filipino | Filipino | General Translation calls it `fil`; `customMapping` in `gt.config.json` maps it. |

CHamoru (`ch`) is planned with human translators (see the end of this document).
Its file `hafapass_frontend/src/locales/ch.json` is kept but not offered.

Translation uses [General Translation](https://generaltranslation.com) (GT) in
three places, all following the pattern used by Marianas Open:

1. **Interface text** (buttons, labels, page copy) — the `gt` CLI translates
   `hafapass_frontend/src/locales/en.json` into the other locale files.
2. **Buyer emails** — the same CLI run translates
   `hafapass_api/config/email_locales/en.yml`.
3. **Organizer-entered event text** — the API machine translates event titles,
   descriptions and ticket names after they are saved.

## Environment variables

| Name | Where | Used for |
| --- | --- | --- |
| `GT_API_KEY` | Netlify (frontend build), Render API service, and any Render worker that runs jobs | Interface/email translation at build time; event text translation jobs. |
| `GT_PROJECT_ID` | Same places as `GT_API_KEY` | Same. |
| `VITE_ENABLED_LOCALES` | Netlify | Comma list of buyer languages offered in the app (default `en`). With only English the language switcher is hidden. |
| `HAFAPASS_ENABLED_LOCALES` | Render API and worker | Comma list of languages the API answers in (event text, the language saved on orders). Default `en`; keep it in step with `VITE_ENABLED_LOCALES`. |
| `HAFAPASS_MACHINE_TRANSLATION` | Render API and worker | `true` to send organizer event text to GT and serve the results. Default off. |

## Rollout gates (current state)

Until phase 2 extracts the remaining page copy, a buyer who picks 한국어 would
see translated navigation around English pages. So everything is off by
default:

- **Frontend:** only languages in `VITE_ENABLED_LOCALES` can be chosen or
  detected from the browser. A saved choice of a language that is not enabled
  becomes English. With one language the switcher is hidden. The organizer,
  admin and support workspace never shows the switcher, and its dates and
  amounts always use en-US formatting.
- **Browser translation:** `index.html` does not set `translate="no"` for now,
  so buyers can use Chrome or Safari page translation. Phase 2 can restore it
  once HåfaPass translates every page itself.
- **API:** languages outside `HAFAPASS_ENABLED_LOCALES` read as English.
  Organizer wording is served for enabled languages the organizer turned on.
  Nothing calls GT and no machine translation is served unless
  `HAFAPASS_MACHINE_TRANSLATION=true` and both GT variables are set.
- **Credit:** if GT answers out of credit or rate limited (HTTP 402/429 or a
  credit error), the record is marked `unavailable`, nothing retries, buyers see
  English and organizers see "paused" rather than a failure.

To turn a language on: set it in both `VITE_ENABLED_LOCALES` and
`HAFAPASS_ENABLED_LOCALES`; set `HAFAPASS_MACHINE_TRANSLATION=true` once the GT
account has credit, then run `bin/rails translations:backfill`.

Without the GT variables nothing is sent to GT: builds use the committed locale
files, event text stays English in every language, and the organizer page says
automatic translation is not set up.

## Privacy

General Translation is a subprocessor when machine translation is on: it
receives the English title, short description and description of **published,
publicly visible** events and the names and descriptions of their ticket
types. Drafts, hidden (policy-held) events and live-money proof events are never
sent, and nothing about buyers (names, emails, orders) is sent. The interface and
email copy sent by the `gt` CLI contains no personal data. The privacy policy's
subprocessor list should name General Translation before the switch is turned
on (policy text is maintained separately).

Use a GT project that belongs to HåfaPass. GT applies project-level context to
every request; the first locale files were generated in the Marianas Open
project, which describes jiu-jitsu tournaments, and words like “event” came back
as “tournament” (대회, 大会, 赛事) until they were corrected by hand. Once
HåfaPass has its own project, run `npm run translate -- --force` once (see
below) and review the result.

## Interface text (frontend)

Files, all in `hafapass_frontend/`:

- `src/locales/en.json` — the English source. Developers edit only this file.
- `src/locales/en.metadata.json` — optional per-key context for translators
  (for example, that the service fee is not a tax and that “event” never means
  a sports competition). Add context for anything ambiguous.
- `src/locales/{ko,ja,zh-Hant,zh,tl}.json` — generated. Do not hand-edit except
  for corrections; the next CLI run uploads local edits and keeps them.
- `gt.config.json` — locales, the `tl` → `fil` mapping, and the files to
  translate (JSON and the API's email YAML).
- `gt-lock.json` — the CLI's record of what was translated. Commit it with the
  locale files.
- `scripts/translate-safe.mjs` (logic in `scripts/translate-safe-lib.mjs`) —
  runs `gt translate` when the credentials are present, with a 120-second
  timeout. Afterwards every generated JSON file must parse and keep each key's
  `{{placeholders}}`, and every email YAML file must keep the `emails:` root and
  the same `%{placeholders}`. On a failure, a timeout or invalid output, all
  translation files and `gt-lock.json` are restored to the committed versions
  and the build continues. It never fails the build and never ships
  unvalidated JSON.

Commands:

```bash
cd hafapass_frontend
npm run translate          # translate changed keys (needs GT_API_KEY/GT_PROJECT_ID)
npm run translate -- --force  # retranslate everything
npm run build              # runs translate:safe first, then vite build
npm run build:no-translate # vite build only
```

Netlify runs `npm run build`, so with the variables set every deploy
translates new or changed keys before bundling. Still commit the generated
files (and `gt-lock.json`) so local builds, CI and the API's email copy match
what was deployed.

Runtime (`src/i18n.js`): react-i18next with English bundled and the other
languages as separate chunks loaded on demand. Detection order is the saved
choice (`localStorage` key `i18nextLng`), then the browser languages, then
English, limited to enabled languages (see Rollout gates). Changing the
language updates `<html lang>`, and the home, event list and event pages reload
their event text in the new language (`src/hooks/useContentLanguage.js`).

Dates and money: `src/utils/eventTime.js` and `src/utils/money.js` format with
the active language through `Intl`, always in the event's own time zone
(default `Pacific/Guam`) and always in US dollars. `src/utils/locale.js` holds
the language list and the active-language state used by those helpers.

Every API request sends the active language as `Accept-Language`
(`src/api/client.js`). The API also accepts `?locale=`.

## Buyer emails (API)

Order confirmation, ticket, refund, ticket transfer, waitlist notification and
waitlist offer emails take their copy from
`hafapass_api/config/email_locales/<locale>.yml`. Other emails are still
English-only and use inline copy in `EmailService`.

- `en.yml` is the source; `en.metadata.yml` gives translators context.
- The files have no locale root key (`emails:` is the top level) so the `gt`
  CLI translates values without touching keys. `config/locales/emails.rb`
  loads them into Rails I18n by file name.
- A translated string that does not keep exactly the English `%{placeholders}`
  (or a list that changes length) is ignored, and English is used for it. A
  spec (`spec/services/email_localization_spec.rb`) also fails if a committed
  translation breaks a placeholder.
- Copy is plain text. `EmailService` escapes every value and inserts links
  itself, so translations cannot inject HTML.

The language comes from the record the email is about, captured when the buyer
created it:

| Record | Column | Set by |
| --- | --- | --- |
| `orders` | `locale` | Online checkout (`POST /orders`). Box office, cash and guest-list orders stay English. |
| `waitlist_entries` | `locale` | Joining a waitlist. |
| `ticket_transfers` | `locale` | The sender's language when starting a transfer (recorded only; see below). |

Existing rows were given `en`, so emails about earlier purchases are unchanged.
Event titles in these emails use the record's language too. Ticket transfer
emails go to the recipient, whose language is unknown, so they are always
English. Deadlines (transfer and waitlist-offer expiry) include the time zone.

Issued tickets use the organizer's own ticket names everywhere (emails, PDFs,
My Tickets, the ticket page and door lists) so buyers and door staff see the
same words. Only the event page shows translated ticket names, with "Show
original".

There is no build step on Render: generate the email translations with
`npm run translate` in `hafapass_frontend` and commit the YAML files.

## Organizer event text (API)

Organizers write in English. When machine translation is on (see Rollout
gates), saving a published, publicly visible event or its ticket types queues
`TranslateRecordJob` (queue `low`) for the fields that changed. Publishing an
event queues every field of the event and its ticket types; drafts are never
sent:

| Model | Translated | Left as written |
| --- | --- | --- |
| `Event` | `title`, `short_description`, `description` | Venue name, address and village (proper nouns and directions must match maps and signs). |
| `TicketType` | `name`, `description` | |

How it works:

- `Translatable` (`app/models/concerns/translatable.rb`) records the changed
  fields before save and queues the job after commit. Without the switch and
  credentials it does nothing.
- `GtTranslationService` posts each field to
  `https://runtime2.gtx.dev/v2/translate`, one request per target locale, with
  context telling GT to keep names of people, venues, villages, brands and
  CHamoru words as written.
- Results are stored in the record's `translations` JSONB column as
  `{ field => { "_digest" => <hash of the English>, locale => text } }`, and
  `translation_status` becomes `translated`, `pending`, `failed` or
  `unavailable` (GT out of credit or rate limited).
- A translation is only shown while its digest matches the current English,
  so an edit never shows an outdated translation while the new one is made.
- The job works locale by locale and is idempotent: only locales missing a
  current translation are requested (unless forced); results merge into the
  existing translations, so a locale GT does not return keeps its previous
  good translation; and a result is discarded if the English changed again
  while it was in flight. GT errors retry 4 times with back-off, then mark the
  record `failed`, but never over a translation another job already completed.

What buyers see (`GET /events`, `GET /events/:slug`), in this order of
precedence:

1. The organizer's own wording for that language (`localized_content`, for
   languages the organizer turned on under **Sales tools → Public languages**).
2. The current machine translation.
3. The English original.

Responses include `content_locale`, `machine_translated`, and
`original_content` (the English title and descriptions; ticket types have
`original_name` and `original_description`) so the page can show
“Translated automatically · Show original”. The frontend pieces for that are
`src/hooks/useTranslatedContent.js` and
`src/components/MachineTranslationNotice.jsx`. Responses vary by
`Accept-Language`.

Retranslation and backfill:

- Organizers: **Translate again** in Sales tools → Public languages
  (`POST /api/v1/organizer/events/:id/retranslate`, needs edit-content
  permission).
- Platform admins: `POST /api/v1/admin/events/:id/retranslate`.
- Both retranslate the event and its ticket types. They are refused for drafts,
  for 5 minutes after the last request, and while a request is still pending
  (up to 30 minutes), returning HTTP 429 `recently_requested`.
- The organizer page polls the status every 5 seconds while a translation is
  pending. Organizer wording remembers which English it was written for and is
  marked "English changed since you wrote this" when that English is edited.
- `bin/rails translations:backfill` translates every event and ticket type that
  is `untranslated`, `failed` or `unavailable` and public (run once after
  turning machine translation on; safe to re-run; it stops at the first
  out-of-credit answer). `bin/rails translations:status` counts records by status.

## PDFs

Ticket and door-list PDFs embed Noto Sans plus Noto Sans JP, KR, TC and SC and
Noto Emoji (`hafapass_api/app/assets/fonts/tickets`, SIL Open Font License; see
the README there). `PdfFonts` loads only the fallback fonts the text needs and
puts the font for the text's language first. A ticket PDF still refuses
characters no bundled font has (the download and email paths fall back to a
notice); the emergency door list always prints and shows them as `?`. PDF labels
are English.

## Policies

Policy text is English and authoritative. When the app is in another language,
policy pages say that the English version governs
(`PolicyLanguageNotice`). Translated policy summaries are out of scope for now.

## Adding a language

1. Add the code to `LANGUAGES` in `hafapass_frontend/src/utils/locale.js`
   (native label, English name, `Intl` and `html` tags) and teach
   `normalizeLanguage` any browser tags that should map to it.
2. Add it to `locales` in `hafapass_frontend/gt.config.json` (plus a
   `customMapping` entry if GT uses a different code).
3. Add it to `AppLocale::SUPPORTED` (and `normalize`) in
   `hafapass_api/app/services/app_locale.rb` and to
   `config.i18n.available_locales` in `hafapass_api/config/application.rb`.
4. Run `npm run translate`, review the new files, and commit them with
   `gt-lock.json`.
5. Run `bin/rails translations:backfill` so existing events get the new
   language.
6. Turn it on for buyers by adding it to `VITE_ENABLED_LOCALES` (Netlify) and
   `HAFAPASS_ENABLED_LOCALES` (Render).

## CHamoru plan

CHamoru should be translated by people, not machine translation. The plan:

1. Recruit CHamoru translators and reviewers (for example through the
   Kumisión i Fino' CHamoru) and agree on terms for ticketing words.
2. Translate `en.json` into `ch.json` and `en.yml` into
   `config/email_locales/ch.yml` by hand, keeping keys and placeholders.
3. Add `ch` to the frontend `LANGUAGES` list (and `normalizeLanguage`), to
   `AppLocale::SUPPORTED` and `AppLocale.normalize`, and to
   `config.i18n.available_locales`. Keep it out of `gt.config.json` and change
   `AppLocale::TRANSLATION_TARGETS` to exclude it explicitly (it is currently
   derived from `SUPPORTED`), so neither the CLI nor the translation job
   overwrites human work.
4. Organizers can already enter their own CHamoru wording for events that had
   it enabled; that content stays valid and is shown once `ch` is offered.

## Turning on languages

After translation credit is restored:

- Set `VITE_ENABLED_LOCALES` and `HAFAPASS_ENABLED_LOCALES` to the same language list.
- Set `HAFAPASS_MACHINE_TRANSLATION=true` on the API and worker.
- In `hafapass_frontend`, run `npm run translate -- --force`, review the generated files, and commit them with `gt-lock.json`.
- In `hafapass_api`, run `bin/rails translations:backfill`.
- Spot-check discovery, event details, checkout, ticket recovery, confirmation, and ticket transfers in each language on desktop and mobile.

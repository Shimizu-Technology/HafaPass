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

Without both variables nothing is sent to GT: builds use the committed locale
files, event text stays English in every language, and the organizer page says
automatic translation is not set up.

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
- `scripts/translate-safe.mjs` — runs `gt translate` when the credentials are
  present, and never fails the build.

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
English. Changing the language updates `<html lang>`. `index.html` sets
`translate="no"` so browser auto-translation does not rewrite the React DOM.

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
| `ticket_transfers` | `locale` | The sender's language when starting a transfer. |

Existing rows were given `en`, so emails about earlier purchases are unchanged.
Event titles and ticket names in these emails use the record's language too.

There is no build step on Render: generate the email translations with
`npm run translate` in `hafapass_frontend` and commit the YAML files.

## Organizer event text (API)

Organizers write in English. When General Translation is configured, saving
an event or ticket type queues `TranslateRecordJob` (queue `low`) for the
fields that changed:

| Model | Translated | Left as written |
| --- | --- | --- |
| `Event` | `title`, `short_description`, `description` | Venue name, address and village (proper nouns and directions must match maps and signs). |
| `TicketType` | `name`, `description` | |

How it works:

- `Translatable` (`app/models/concerns/translatable.rb`) records the changed
  fields before save and queues the job after commit. Without credentials it
  does nothing.
- `GtTranslationService` posts each field to
  `https://runtime2.gtx.dev/v2/translate`, one request per target locale, with
  context telling GT to keep names of people, venues, villages, brands and
  CHamoru words as written.
- Results are stored in the record's `translations` JSONB column as
  `{ field => { "_digest" => <hash of the English>, locale => text } }`, and
  `translation_status` becomes `translated`, `pending` or `failed`.
- A translation is only shown while its digest matches the current English,
  so an edit never shows an outdated translation while the new one is made.
- The job is idempotent: unchanged fields are not re-sent unless forced, and a
  result is discarded if the English changed again while it was in flight. GT
  errors retry 4 times with back-off, then mark the record `failed`.

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
- Both retranslate the event and its ticket types from scratch.
- `bin/rails translations:backfill` translates every event and ticket type that
  is `untranslated` or `failed` (run once after first setting the credentials;
  safe to re-run). `bin/rails translations:status` counts records by status.

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

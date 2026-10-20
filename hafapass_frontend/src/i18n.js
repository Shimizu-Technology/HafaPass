import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import LanguageDetector from 'i18next-browser-languagedetector'

import en from './locales/en.json'
import {
  DEFAULT_LANGUAGE, SUPPORTED_LANGUAGE_CODES, languageFor, normalizeLanguage, setActiveLanguage,
} from './utils/locale'

// English ships in the main bundle; the other languages are separate chunks
// loaded when chosen. Their files are generated from en.json by the `gt` CLI
// (npm run translate); see docs/TRANSLATIONS.md.
const localeLoaders = import.meta.glob([
  './locales/*.json', '!./locales/en.json', '!./locales/ch.json', '!./locales/*.metadata.json',
])

const lazyLocales = {
  type: 'backend',
  read(language, namespace, callback) {
    const load = localeLoaders[`./locales/${language}.json`]
    if (!load) return callback(null, {})
    load().then(module => callback(null, module.default), error => callback(error, null))
  },
}

function applyLanguage(language) {
  const code = setActiveLanguage(language)
  if (typeof document !== 'undefined') document.documentElement.lang = languageFor(code).html
}

i18n.on('languageChanged', applyLanguage)

i18n
  .use(lazyLocales)
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: { en: { translation: en } },
    partialBundledLanguages: true,
    supportedLngs: SUPPORTED_LANGUAGE_CODES,
    // "zh-Hant" must not fall back through Simplified Chinese ("zh").
    load: 'currentOnly',
    fallbackLng: DEFAULT_LANGUAGE,
    interpolation: { escapeValue: false },
    // Show English until a language chunk arrives instead of suspending the app.
    react: { useSuspense: false },
    detection: {
      order: ['localStorage', 'navigator'],
      caches: ['localStorage'],
      // Unsupported tags pass through unchanged so i18next skips to the next preference.
      convertDetectedLanguage: tag => normalizeLanguage(tag) || tag,
    },
  })

applyLanguage(i18n.resolvedLanguage || i18n.language)

export default i18n

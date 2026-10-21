// The languages HåfaPass offers buyers, in switcher order. `code` matches the
// locale file name and the API's locale codes (hafapass_api AppLocale);
// `intl` is the tag used for dates and numbers; `html` goes on <html lang>.
// CHamoru (ch.json) is kept for the human translation planned later but is not
// offered until it is complete. See docs/TRANSLATIONS.md.
import { isWorkspacePath } from './workspacePath'

export const LANGUAGES = [
  { code: 'en', label: 'English', englishName: 'English', short: 'EN', intl: 'en-US', html: 'en' },
  { code: 'ko', label: '한국어', englishName: 'Korean', short: 'KO', intl: 'ko-KR', html: 'ko' },
  { code: 'ja', label: '日本語', englishName: 'Japanese', short: 'JA', intl: 'ja-JP', html: 'ja' },
  { code: 'zh-Hant', label: '繁體中文', englishName: 'Chinese (Traditional)', short: '繁中', intl: 'zh-Hant-TW', html: 'zh-Hant' },
  { code: 'zh', label: '简体中文', englishName: 'Chinese (Simplified)', short: '简中', intl: 'zh-Hans-CN', html: 'zh-Hans' },
  { code: 'tl', label: 'Filipino', englishName: 'Filipino', short: 'FIL', intl: 'fil-PH', html: 'fil' },
]

export const DEFAULT_LANGUAGE = 'en'
export const SUPPORTED_LANGUAGE_CODES = LANGUAGES.map(language => language.code)

const TRADITIONAL_CHINESE_REGIONS = ['tw', 'hk', 'mo']

// Maps a browser or stored tag ("ko-KR", "zh-TW", "fil") to a supported code.
export function normalizeLanguage(tag) {
  const parts = String(tag || '').trim().replace(/_/g, '-').toLowerCase().split('-')
  switch (parts[0]) {
    case 'en': case 'ko': case 'ja': return parts[0]
    case 'tl': case 'fil': return 'tl'
    case 'zh': {
      const rest = parts.slice(1)
      if (rest.includes('hans')) return 'zh'
      if (rest.includes('hant') || rest.some(part => TRADITIONAL_CHINESE_REGIONS.includes(part))) return 'zh-Hant'
      return 'zh'
    }
    default: return null
  }
}

// Languages buyers can choose: VITE_ENABLED_LOCALES (comma list, default
// "en"). Until every buyer page is translated only English is on, so the
// switcher is hidden; turning a language on is a deploy setting, not code.
export function parseEnabledLanguages(value) {
  const listed = String(value || DEFAULT_LANGUAGE).split(',').map(normalizeLanguage).filter(Boolean)
  return LANGUAGES.filter(language => language.code === DEFAULT_LANGUAGE || listed.includes(language.code))
}

let enabledLanguages = parseEnabledLanguages(import.meta.env.VITE_ENABLED_LOCALES)

export const getEnabledLanguages = () => enabledLanguages
// For tests and previews; the app reads VITE_ENABLED_LOCALES once at start.
export function configureEnabledLanguages(value) {
  enabledLanguages = parseEnabledLanguages(Array.isArray(value) ? value.join(',') : value)
  return enabledLanguages
}

// A supported code that is also enabled, or null.
export function enabledLanguageCode(tag) {
  const code = normalizeLanguage(tag)
  return enabledLanguages.some(language => language.code === code) ? code : null
}

export function languageFor(code) {
  return enabledLanguages.find(language => language.code === enabledLanguageCode(code)) || LANGUAGES[0]
}

// A saved choice of a language that is no longer offered becomes English
// (not the browser's language), so a buyer is not switched unexpectedly.
export function sanitizeStoredLanguage(storage, key = 'i18nextLng') {
  try {
    const stored = storage?.getItem(key)
    if (stored && !enabledLanguageCode(stored)) storage.setItem(key, DEFAULT_LANGUAGE)
  } catch { /* Storage can be unavailable (private mode); detection then uses the browser. */ }
}

// i18n.js keeps this in step with the selected language so plain helpers
// (dates, money, API headers) can follow it without importing i18next.
let activeLanguage = DEFAULT_LANGUAGE

export function setActiveLanguage(code) {
  activeLanguage = languageFor(code).code
  return activeLanguage
}

export const getActiveLanguage = () => activeLanguage

// Organizer, admin and support screens are English, so their dates and
// amounts stay en-US whatever language a buyer chose.
export function activeIntlLocale() {
  if (typeof window !== 'undefined' && isWorkspacePath(window.location.pathname)) return 'en-US'
  return languageFor(activeLanguage).intl
}

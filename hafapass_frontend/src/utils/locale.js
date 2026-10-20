// The languages HåfaPass offers buyers, in switcher order. `code` matches the
// locale file name and the API's locale codes (hafapass_api AppLocale);
// `intl` is the tag used for dates and numbers; `html` goes on <html lang>.
// CHamoru (ch.json) is kept for the human translation planned later but is not
// offered until it is complete. See docs/TRANSLATIONS.md.
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

export function languageFor(code) {
  return LANGUAGES.find(language => language.code === normalizeLanguage(code)) || LANGUAGES[0]
}

// i18n.js keeps this in step with the selected language so plain helpers
// (dates, money, API headers) can follow it without importing i18next.
let activeLanguage = DEFAULT_LANGUAGE

export function setActiveLanguage(code) {
  activeLanguage = languageFor(code).code
  return activeLanguage
}

export const getActiveLanguage = () => activeLanguage
export const activeIntlLocale = () => languageFor(activeLanguage).intl

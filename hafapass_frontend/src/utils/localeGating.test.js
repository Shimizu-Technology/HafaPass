import { afterEach, describe, expect, it } from 'vitest'
import { activeIntlLocale, configureEnabledLanguages, enabledLanguageCode, getEnabledLanguages, languageFor, parseEnabledLanguages, sanitizeStoredLanguage, setActiveLanguage } from './locale'

describe('enabled languages (VITE_ENABLED_LOCALES)', () => {
  afterEach(() => {
    configureEnabledLanguages('en')
    setActiveLanguage('en')
    window.history.replaceState(null, '', '/')
    window.localStorage.clear()
  })

  it('defaults to English only and always keeps English', () => {
    expect(parseEnabledLanguages(undefined).map(language => language.code)).toEqual(['en'])
    expect(parseEnabledLanguages('ko, zh-TW, fr').map(language => language.code)).toEqual(['en', 'ko', 'zh-Hant'])
  })

  it('maps detection and selection only to enabled languages', () => {
    configureEnabledLanguages('ko')
    expect(enabledLanguageCode('ko-KR')).toBe('ko')
    expect(enabledLanguageCode('ja')).toBeNull()
    expect(languageFor('ja').code).toBe('en')
    expect(getEnabledLanguages().map(language => language.code)).toEqual(['en', 'ko'])
  })

  it('turns a saved choice of a disabled language into English', () => {
    configureEnabledLanguages('ko')
    window.localStorage.setItem('i18nextLng', 'ja')
    sanitizeStoredLanguage(window.localStorage)
    expect(window.localStorage.getItem('i18nextLng')).toBe('en')

    window.localStorage.setItem('i18nextLng', 'ko')
    sanitizeStoredLanguage(window.localStorage)
    expect(window.localStorage.getItem('i18nextLng')).toBe('ko')
  })

  it('keeps organizer and admin screens in en-US formatting whatever the buyer language', () => {
    configureEnabledLanguages('ko')
    setActiveLanguage('ko')
    expect(activeIntlLocale()).toBe('ko-KR')
    window.history.replaceState(null, '', '/dashboard/events/1')
    expect(activeIntlLocale()).toBe('en-US')
    window.history.replaceState(null, '', '/admin')
    expect(activeIntlLocale()).toBe('en-US')
  })
})

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { activeIntlLocale, configureEnabledLanguages, getActiveLanguage, languageFor, normalizeLanguage, setActiveLanguage } from './locale'

describe('locale helpers', () => {
  beforeEach(() => configureEnabledLanguages('ko,ja,zh-Hant,zh,tl'))
  afterEach(() => { setActiveLanguage('en'); configureEnabledLanguages('en') })

  it('maps browser and stored tags to the supported languages', () => {
    expect(['en-US', 'ko-KR', 'ja', 'tl', 'fil-PH'].map(normalizeLanguage)).toEqual(['en', 'ko', 'ja', 'tl', 'tl'])
    expect(['zh', 'zh-CN', 'zh-Hans-TW'].map(normalizeLanguage)).toEqual(['zh', 'zh', 'zh'])
    expect(['zh-TW', 'zh-HK', 'zh_Hant'].map(normalizeLanguage)).toEqual(['zh-Hant', 'zh-Hant', 'zh-Hant'])
    expect(['fr', 'ch', '', undefined].map(normalizeLanguage)).toEqual([null, null, null, null])
  })

  it('tracks the active language for formatting and falls back to English', () => {
    expect(setActiveLanguage('zh-TW')).toBe('zh-Hant')
    expect(activeIntlLocale()).toBe('zh-Hant-TW')
    expect(setActiveLanguage('ch')).toBe('en')
    expect(getActiveLanguage()).toBe('en')
    expect(languageFor('tl')).toMatchObject({ html: 'fil', intl: 'fil-PH', label: 'Filipino' })
  })
})

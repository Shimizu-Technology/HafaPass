import { afterEach, beforeEach, expect, it } from 'vitest'
import { formatMoneyCents } from './money'
import { configureEnabledLanguages, setActiveLanguage } from './locale'

beforeEach(() => configureEnabledLanguages('ko,ja,zh-Hant,zh,tl'))
afterEach(() => { setActiveLanguage('en'); configureEnabledLanguages('en') })

it('always shows US dollars, formatted for the selected language', () => {
  expect(formatMoneyCents(123456)).toBe('$1,234.56')
  expect(formatMoneyCents(undefined)).toBe('$0.00')
  setActiveLanguage('ko')
  expect(formatMoneyCents(123456)).toBe('US$1,234.56')
  setActiveLanguage('ja')
  expect(formatMoneyCents(2500)).toBe('$25.00')
})

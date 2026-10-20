import { afterEach, expect, it } from 'vitest'
import { formatMoneyCents } from './money'
import { setActiveLanguage } from './locale'

afterEach(() => setActiveLanguage('en'))

it('always shows US dollars, formatted for the selected language', () => {
  expect(formatMoneyCents(123456)).toBe('$1,234.56')
  expect(formatMoneyCents(undefined)).toBe('$0.00')
  setActiveLanguage('ko')
  expect(formatMoneyCents(123456)).toBe('US$1,234.56')
  setActiveLanguage('ja')
  expect(formatMoneyCents(2500)).toBe('$25.00')
})

import { activeIntlLocale } from './locale'

// Money amounts from integer cents, e.g. 123456 -> "$1,234.56". Amounts are
// always US dollars; the language only changes separators and wording.
export function formatMoneyCents(cents, currency = 'USD') {
  const safe = Number.isFinite(cents) ? cents : 0
  try {
    return new Intl.NumberFormat(activeIntlLocale(), { style: 'currency', currency }).format(safe / 100)
  } catch {
    return `$${(safe / 100).toFixed(2)}`
  }
}

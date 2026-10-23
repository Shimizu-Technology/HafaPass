// Promo APIs store fixed discounts in integer cents and percentages in whole points.
export function promoDiscountToApi(value, type) {
  if (type === 'percentage') return /^\d+$/.test(value) && Number(value) > 0 && Number(value) <= 100 ? Number(value) : null
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) return null
  const [dollars, fraction = ''] = value.split('.')
  const cents = Number(dollars) * 100 + Number(fraction.padEnd(2, '0'))
  return Number.isSafeInteger(cents) && cents > 0 && cents <= 2147483647 ? cents : null
}

export function promoDiscountFromApi(value, type) {
  return type === 'fixed' ? (value / 100).toFixed(2) : String(value)
}

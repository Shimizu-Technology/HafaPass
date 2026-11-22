const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const PHONE_PATTERN = /^\+?[0-9().\-\s]+$/

export function blankAnswer(value) {
  return value === undefined || value === null || value === false || (Array.isArray(value) && value.length === 0)
    || (typeof value === 'string' && !value.trim())
}

// Mirrors RegistrationQuestion#valid_answer? so buyers see the problem before
// the server rejects the order. Returns an error message or null.
export function questionAnswerError(question, value, t) {
  if (blankAnswer(value)) {
    if (!question.required) return null
    if (question.kind === 'checkbox') return t('buyer.Checkout.checkThisBoxToContinue')
    if (question.kind === 'multi_select') return t('buyer.Checkout.chooseAtLeastOne')
    return t('buyer.Checkout.answerRequired')
  }
  if (question.kind === 'number') {
    const text = String(value).trim()
    if (!/^-?\d+(\.\d+)?$/.test(text)) return t('buyer.Checkout.enterANumber')
    const number = Number(text)
    const { min, max } = question.validation_rules || {}
    if ((min != null && number < min) || (max != null && number > max)) {
      if (min != null && max != null) return t('buyer.Checkout.enterANumberFromTo', { min, max })
      return min != null ? t('buyer.Checkout.enterANumberAtLeast', { min }) : t('buyer.Checkout.enterANumberAtMost', { max })
    }
  }
  if (question.kind === 'email' && !EMAIL_PATTERN.test(String(value).trim())) return t('buyer.Checkout.pleaseEnterAValidEmail')
  if (question.kind === 'phone') {
    const text = String(value).trim()
    const digits = text.replace(/\D/g, '').length
    if (!PHONE_PATTERN.test(text) || digits < 7 || digits > 15) return t('buyer.Checkout.enterAValidPhoneNumber')
  }
  return null
}

// The value sent to the API: numbers as numbers, text trimmed, and an
// unchecked checkbox as an explicit "No".
export function answerPayload(question, value) {
  if (question.kind === 'checkbox') return value === true
  if (blankAnswer(value)) return undefined
  if (question.kind === 'number') return Number(String(value).trim())
  if (typeof value === 'string') return value.trim()
  return value
}

export function answersPayload(questions, answers) {
  return Object.fromEntries(questions
    .map(question => [question.id, answerPayload(question, answers[question.id])])
    .filter(([, value]) => value !== undefined))
}

import { describe, expect, it } from 'vitest'
import { answerPayload, questionAnswerError } from './registrationAnswers'

const t = (key, values) => (values ? `${key} ${JSON.stringify(values)}` : key)

describe('registration answer checks', () => {
  const year = { kind: 'number', required: true, validation_rules: { min: 1950, max: 2035, integer: true } }

  it('requires whole numbers within range and bounds the input length', () => {
    expect(questionAnswerError(year, '1998', t)).toBeNull()
    expect(questionAnswerError(year, '1998.5', t)).toBe('buyer.Checkout.enterAWholeNumber')
    expect(questionAnswerError(year, '1949', t)).toBe('buyer.Checkout.enterANumberFromTo {"min":1950,"max":2035}')
    expect(questionAnswerError(year, '1'.repeat(25), t)).toBe('buyer.Checkout.enterANumber')
    expect(questionAnswerError({ ...year, validation_rules: {} }, '2.5', t)).toBeNull()
  })

  it('sends choices exactly as written and an unchecked checkbox as false', () => {
    expect(answerPayload({ kind: 'selection' }, ' Gold ')).toBe(' Gold ')
    expect(answerPayload({ kind: 'multi_select' }, [' S', 'M'])).toEqual([' S', 'M'])
    expect(answerPayload({ kind: 'short_text' }, '  Class of 98 ')).toBe('Class of 98')
    expect(answerPayload({ kind: 'checkbox' }, undefined)).toBe(false)
    expect(answerPayload({ kind: 'number' }, ' 1998 ')).toBe(1998)
  })
})

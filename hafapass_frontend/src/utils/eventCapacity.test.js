import { describe, expect, it } from 'vitest'
import { MAX_EVENT_CAPACITY, validEventCapacity } from './eventCapacity'

describe('event capacity database range', () => {
  it.each(['1', '1e2', '0200', String(MAX_EVENT_CAPACITY)])('accepts representable positive capacity %s', value => {
    expect(validEventCapacity(value)).toBe(true)
  })
  it.each(['', '0', '-1', '1.2', '2147483648', '9007199254740992', '1e309', 'invalid'])('rejects capacity %s before serialization', value => {
    expect(validEventCapacity(value)).toBe(false)
  })
})

import { expect, it } from 'vitest'
import { mutationErrorMessage } from './adminOperations'

it.each([new Error('offline'), { response: { status: 500, data: { error: 'Nothing changed' } } }])('does not claim an uncertain save failed', failure => {
  expect(mutationErrorMessage(failure)).toBe("We couldn't confirm the result. Refresh to check before trying again.")
})
it('retains definite validation errors', () => {
  expect(mutationErrorMessage({ response: { status: 422, data: { errors: ['A review note is required'] } } })).toBe('A review note is required')
})

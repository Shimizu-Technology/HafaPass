import { describe, expect, it } from 'vitest'
import { safeReturnPath, signInDestination } from './authDestination'

describe('authentication destination', () => {
  it('preserves invitation tokens, query, and fragment through sign in', () => {
    const location = { pathname: '/organization-invitations/accept', search: '?token=signed-value', hash: '#accept' }
    const redirect = signInDestination(location)
    expect(new URL(redirect, window.location.origin).searchParams.get('returnTo')).toBe('/organization-invitations/accept?token=signed-value#accept')
    expect(safeReturnPath('/ticket-transfers/accept?token=signed-value')).toBe('/ticket-transfers/accept?token=signed-value')
  })

  it('rejects external and browser-normalized redirect paths', () => {
    for (const path of ['https://untrusted.invalid', '//untrusted.invalid', '/\\untrusted.invalid', '/\n/untrusted.invalid', null]) expect(safeReturnPath(path)).toBe('/')
  })
})

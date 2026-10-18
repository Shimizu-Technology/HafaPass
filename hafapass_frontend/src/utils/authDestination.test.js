import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { safeReturnPath, signInDestination, createAuthReturnIntent, readAuthReturnIntent, storeAuthReturnIntent, clearAuthReturnIntent } from './authDestination'

describe('authentication destination', () => {
  beforeEach(() => window.sessionStorage.clear())
  afterEach(() => vi.restoreAllMocks())
  it('preserves invitation tokens, query, and fragment through sign in', () => {
    const location = { pathname: '/organization-invitations/accept', search: '?token=signed-value', hash: '#accept' }
    const redirect = signInDestination(location)
    expect(new URL(redirect, window.location.origin).searchParams.get('returnTo')).toBe('/organization-invitations/accept?token=signed-value#accept')
    expect(safeReturnPath('/ticket-transfers/accept?token=signed-value')).toBe('/ticket-transfers/accept?token=signed-value')
  })

  it('rejects external and browser-normalized redirect paths', () => {
    for (const path of ['https://untrusted.invalid', '//untrusted.invalid', '/\\untrusted.invalid', '/\n/untrusted.invalid', null]) expect(safeReturnPath(path)).toBe('/')
  })

  it('does not let an old completed attempt erase a newer destination', () => {
    const original = createAuthReturnIntent('/my-tickets')
    const current = createAuthReturnIntent('/dashboard')
    storeAuthReturnIntent(original)
    storeAuthReturnIntent(current)
    clearAuthReturnIntent(original.id)
    expect(readAuthReturnIntent()?.destination).toBe('/dashboard')
    clearAuthReturnIntent(current.id)
    expect(readAuthReturnIntent()).toBeNull()
  })

  it('rejects a tampered external destination persisted in the tab', () => {
    storeAuthReturnIntent({ id: 'synthetic-intent', destination: '//untrusted.invalid', expiresAt: Date.now() + 1000 })
    expect(readAuthReturnIntent()).toBeNull()
  })

  it('treats corrupt or unavailable stored intent as absent', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockReturnValue('not-json')
    expect(readAuthReturnIntent()).toBeNull()
    Storage.prototype.getItem.mockImplementation(() => { throw new Error('Storage unavailable') })
    expect(readAuthReturnIntent()).toBeNull()
  })
})

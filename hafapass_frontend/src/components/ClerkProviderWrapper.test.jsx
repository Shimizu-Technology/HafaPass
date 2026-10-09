import { act, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import userEvent from '@testing-library/user-event'

const auth = vi.hoisted(() => ({ isLoaded: false, isSignedIn: false, user: null, getToken: vi.fn() }))
const clear = vi.hoisted(() => vi.fn())
vi.mock('@clerk/clerk-react', () => ({
  ClerkProvider: ({ children }) => children,
  useAuth: () => ({ getToken: auth.getToken }),
  useUser: () => auth,
}))
vi.mock('../utils/admissionStore', () => ({ clearAllAdmissionData: clear }))
vi.mock('../api/client', () => ({ setAuthTokenGetter: vi.fn() }))
vi.mock('../monitoring', () => ({ Sentry: { setUser: vi.fn() } }))

describe('account-bound scanner authentication bootstrap', () => {
  let Wrapper
  beforeEach(async () => {
    vi.resetModules()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'test-configured-key')
    window.localStorage.clear()
    Object.assign(auth, { isLoaded: false, isSignedIn: false, user: null })
    clear.mockReset().mockResolvedValue(undefined)
    Wrapper = (await import('./ClerkProviderWrapper')).default
  })
  afterEach(() => vi.unstubAllEnvs())

  it('opens only the supplied verified scanner fallback while Clerk cannot load, then mounts normal routes for its owner', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.getByText('Verified saved scanner')).toBeInTheDocument()
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    Object.assign(auth, { isLoaded: true, isSignedIn: true, user: { id: 'owner-a' } })
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(await screen.findByText('Normal routes')).toBeInTheDocument()
    expect(clear).not.toHaveBeenCalled()
  })

  it.each([null, 'owner-b'])('removes saved attendee access before mounting routes after confirmed account change to %s', async owner => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    let finishClear
    clear.mockReturnValue(new Promise(resolve => { finishClear = resolve }))
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    Object.assign(auth, { isLoaded: true, isSignedIn: Boolean(owner), user: owner ? { id: owner } : null })
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    expect(clear).toHaveBeenCalledOnce()
    await act(async () => finishClear())
    expect(screen.getByText('Normal routes')).toBeInTheDocument()
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe(owner)
  })

  it.each([null, 'owner-b'])('keeps routes locked after failed purge for %s and recovers only after a successful retry', async owner => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    window.localStorage.setItem('hafapass_organization_id', 'old-organization')
    clear.mockRejectedValueOnce(new Error('Storage unavailable'))
    Object.assign(auth, { isLoaded: true, isSignedIn: Boolean(owner), user: owner ? { id: owner } : null })
    render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(await screen.findByRole('alert')).toHaveTextContent('locked for privacy')
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('owner-a')
    expect(window.localStorage.getItem('hafapass_organization_id')).toBe('old-organization')

    let finishRetry
    clear.mockReturnValueOnce(new Promise(resolve => { finishRetry = resolve }))
    await userEvent.setup().click(screen.getByRole('button', { name: 'Retry account preparation' }))
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Preparing your account')
    await act(async () => finishRetry())
    expect(screen.getByText('Normal routes')).toBeInTheDocument()
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe(owner)
    expect(window.localStorage.getItem('hafapass_organization_id')).toBeNull()
    expect(clear).toHaveBeenCalledTimes(2)
  })

  it.each(['resolve', 'reject'])('ignores a stale %s result after the authenticated account changes again', async outcome => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    let finishOld
    let finishNew
    clear.mockReturnValueOnce(new Promise((resolve, reject) => { finishOld = outcome === 'resolve' ? resolve : reject }))
      .mockReturnValueOnce(new Promise(resolve => { finishNew = resolve }))
    Object.assign(auth, { isLoaded: true, isSignedIn: true, user: { id: 'owner-b' } })
    const { rerender } = render(<Wrapper><p>Normal routes</p></Wrapper>)
    Object.assign(auth, { user: { id: 'owner-c' } })
    rerender(<Wrapper><p>Normal routes</p></Wrapper>)
    await act(async () => finishNew())
    expect(screen.getByText('Normal routes')).toBeInTheDocument()
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('owner-c')
    await act(async () => finishOld(outcome === 'reject' ? new Error('Old failure') : undefined))
    expect(screen.getByText('Normal routes')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('owner-c')
  })

  it('does not reopen the saved scanner when Clerk becomes unavailable after a failed account purge', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    clear.mockRejectedValueOnce(new Error('Storage unavailable'))
    Object.assign(auth, { isLoaded: true, isSignedIn: false, user: null })
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    await screen.findByRole('alert')
    Object.assign(auth, { isLoaded: false })
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.getByRole('alert')).toHaveTextContent('locked for privacy')
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
  })
})

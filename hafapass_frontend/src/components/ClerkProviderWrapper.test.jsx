import { act, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

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
})

import { act, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import userEvent from '@testing-library/user-event'

const auth = vi.hoisted(() => ({ isLoaded: false, isSignedIn: false, user: null, getToken: vi.fn() }))
const clear = vi.hoisted(() => vi.fn())
vi.mock('@clerk/clerk-react', () => ({
  ClerkProvider: ({ children }) => children,
  useAuth: () => ({ getToken: auth.getToken, isLoaded: auth.authLoaded, userId: auth.user?.id ?? null }),
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
    window.sessionStorage.clear()
    Object.assign(auth, { isLoaded: false, isSignedIn: false, user: null, authLoaded: undefined })
    clear.mockReset().mockResolvedValue(undefined)
    Wrapper = (await import('./ClerkProviderWrapper')).default
  })
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs() })

  it.each([null, 'owner-a'])('preserves the mounted application when Clerk resolves for unchanged owner %s', async owner => {
    auth.authLoaded = false
    if (owner) window.localStorage.setItem('hafapass_scanner_user_id', owner)
    const application = <Wrapper><main data-testid="application"><input aria-label="Draft" defaultValue="Keep this draft" /></main></Wrapper>
    const { rerender, container } = render(application)
    const node = screen.getByTestId('application')
    const inserted = []
    const observer = new MutationObserver(records => records.forEach(record => inserted.push(...record.addedNodes)))
    observer.observe(container, { childList: true, subtree: true })
    Object.assign(auth, { isLoaded: true, authLoaded: true, isSignedIn: Boolean(owner), user: owner ? { id: owner } : null })
    rerender(<Wrapper><main data-testid="application"><input aria-label="Draft" defaultValue="Keep this draft" /></main></Wrapper>)
    await act(async () => {})
    observer.disconnect()
    expect(screen.getByTestId('application')).toBe(node)
    expect(screen.getByLabelText('Draft')).toHaveValue('Keep this draft')
    expect(screen.queryByText('Preparing your account…')).not.toBeInTheDocument()
    expect(inserted.some(item => item.textContent.includes('Preparing your account'))).toBe(false)
    expect(clear).not.toHaveBeenCalled()
  })

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
    window.sessionStorage.setItem('hafapass:order-access-owner', JSON.stringify('owner-a'))
    window.sessionStorage.setItem('hafapass:order-access:12', 'previous-private-link')
    let finishClear
    clear.mockReturnValue(new Promise(resolve => { finishClear = resolve }))
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    Object.assign(auth, { isLoaded: true, isSignedIn: Boolean(owner), user: owner ? { id: owner } : null })
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Preparing your account')
    expect(clear).toHaveBeenCalledOnce()
    expect(window.sessionStorage.getItem('hafapass:order-access:12')).toBeNull()
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

  it('withdraws an unbound legacy guest capability during a confirmed sign-out before routes reopen', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    window.sessionStorage.setItem('hafapass:order-access:12', 'legacy-private-link')
    window.sessionStorage.setItem('hafapass:checkout-attempt:event', 'uncertain-checkout-identity')
    let finishClear
    clear.mockReturnValueOnce(new Promise(resolve => { finishClear = resolve }))
    Object.assign(auth, { isLoaded: true, isSignedIn: false, user: null })
    render(<Wrapper><p>Normal routes</p></Wrapper>)
    expect(window.sessionStorage.getItem('hafapass:order-access:12')).toBeNull()
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    await act(async () => finishClear())
    expect(screen.getByText('Normal routes')).toBeInTheDocument()
    const { getOrderAccess, saveOrderAccess } = await import('../utils/orderAccess')
    expect(getOrderAccess(12)).toBeNull()
    expect(window.sessionStorage.getItem('hafapass:checkout-attempt:event')).toBe('uncertain-checkout-identity')
    saveOrderAccess(12, 'explicit-new-email-link')
    expect(getOrderAccess(12)).toBe('explicit-new-email-link')
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

  it.each([null, 'owner-b'])('durably withdraws access during an interrupted purge for %s, including a fresh loading boot', async owner => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    Object.assign(auth, { isLoaded: true, isSignedIn: Boolean(owner), user: owner ? { id: owner } : null })
    let finishClear
    clear.mockReturnValue(new Promise(resolve => { finishClear = resolve }))
    const { unmount } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    const { currentScannerOwner } = await import('../utils/scannerAccountBinding')
    expect(currentScannerOwner()).toBeNull()
    expect(window.localStorage.getItem('hafapass_scanner_binding_pending')).toBe('pending')
    unmount()
    await act(async () => finishClear())
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('owner-a')
    expect(window.localStorage.getItem('hafapass_scanner_binding_pending')).toBe('pending')
    // Re-importing clears module memory, as a new page boot would. The durable
    // storage marker alone must reject the old verified fallback.
    vi.resetModules()
    Wrapper = (await import('./ClerkProviderWrapper')).default
    Object.assign(auth, { isLoaded: false })
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    Object.assign(auth, { isLoaded: true })
    clear.mockResolvedValueOnce(undefined)
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(await screen.findByText('Normal routes')).toBeInTheDocument()
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe(owner)
    expect(window.localStorage.getItem('hafapass_scanner_binding_pending')).toBeNull()
  })

  it('keeps access withdrawn when durable withdrawal storage fails', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    const write = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Storage unavailable') })
    clear.mockRejectedValueOnce(new Error('IndexedDB unavailable'))
    Object.assign(auth, { isLoaded: true, isSignedIn: false, user: null })
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(await screen.findByRole('alert')).toHaveTextContent('locked for privacy')
    const { currentScannerOwner } = await import('../utils/scannerAccountBinding')
    expect(currentScannerOwner()).toBeNull()
    expect(clear).toHaveBeenCalledOnce()
    write.mockRestore()
    Object.assign(auth, { isLoaded: false })
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    expect(currentScannerOwner()).toBeNull()
  })

  it('does not restore an old fallback when Clerk reloads after a completed signout', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    Object.assign(auth, { isLoaded: true, isSignedIn: false, user: null })
    const { rerender } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    await screen.findByText('Normal routes')
    Object.assign(auth, { isLoaded: false })
    rerender(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
  })

  it('keeps cached access blocked after a storage read failure until preparation succeeds', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    const read = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('Storage unavailable') })
    Object.assign(auth, { isLoaded: true, isSignedIn: false, user: null })
    render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(await screen.findByRole('alert')).toHaveTextContent('locked for privacy')
    read.mockRestore()
    const { currentScannerOwner } = await import('../utils/scannerAccountBinding')
    expect(currentScannerOwner()).toBeNull()
    expect(window.localStorage.getItem('hafapass_scanner_binding_pending')).toBe('pending')
    await userEvent.click(screen.getByRole('button', { name: 'Retry account preparation' }))
    await screen.findByText('Normal routes')
    expect(clear).toHaveBeenCalledOnce()
    expect(window.localStorage.getItem('hafapass_scanner_binding_pending')).toBeNull()
  })

  it.each(['new-key quota', 'all local writes'])('purges and refuses a fresh loading boot after localStorage %s failure', async failure => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    const originalSet = Storage.prototype.setItem
    const quota = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(function (key, value) {
      if (this === window.localStorage && (failure === 'all local writes' || this.getItem(key) === null)) throw new DOMException('Quota exhausted', 'QuotaExceededError')
      return originalSet.call(this, key, value)
    })
    window.sessionStorage.setItem('quota-regression', 'still writable')
    let finishClear
    clear.mockReturnValueOnce(new Promise(resolve => { finishClear = resolve }))
    Object.assign(auth, { isLoaded: true, isSignedIn: false, user: null })
    const { unmount } = render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(clear).toHaveBeenCalledOnce()
    unmount()
    await act(async () => finishClear())
    if (failure === 'new-key quota') {
      expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('!')
      // The shared existing-key fallback alone must protect another page/tab.
      window.sessionStorage.removeItem('hafapass_scanner_binding_pending')
    }
    vi.resetModules()
    Wrapper = (await import('./ClerkProviderWrapper')).default
    Object.assign(auth, { isLoaded: false })
    render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
    const { currentScannerOwner } = await import('../utils/scannerAccountBinding')
    expect(currentScannerOwner()).toBeNull()
    quota.mockRestore()
    window.sessionStorage.removeItem('quota-regression')
  })

  it('does not let an old purge completion overwrite a newer peer binding', async () => {
    window.localStorage.setItem('hafapass_scanner_user_id', 'owner-a')
    let finishClear
    clear.mockReturnValueOnce(new Promise(resolve => { finishClear = resolve }))
    Object.assign(auth, { isLoaded: true, isSignedIn: true, user: { id: 'owner-b' } })
    render(<Wrapper loadingFallback={<p>Verified saved scanner</p>}><p>Normal routes</p></Wrapper>)
    await act(async () => {
      window.localStorage.setItem('hafapass_scanner_user_id', 'owner-c')
      window.localStorage.removeItem('hafapass_scanner_binding_pending')
      window.dispatchEvent(new StorageEvent('storage', { key: 'hafapass_scanner_user_id', newValue: 'owner-c', storageArea: window.localStorage }))
    })
    expect(clear.mock.calls[0][0].isCurrent()).toBe(false)
    await act(async () => finishClear())
    expect(window.localStorage.getItem('hafapass_scanner_user_id')).toBe('owner-c')
    expect(window.localStorage.getItem('hafapass_scanner_binding_pending')).toBeNull()
    expect(screen.queryByText('Normal routes')).not.toBeInTheDocument()
    expect(screen.queryByText('Verified saved scanner')).not.toBeInTheDocument()
  })
})

import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, Link, useNavigate, useLocation } from 'react-router-dom'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { readAuthReturnIntent } from '../utils/authDestination'

const auth = vi.hoisted(() => ({ signedIn: false, listeners: new Set() }))
vi.mock('@clerk/clerk-react', async () => {
  const { useSyncExternalStore, useEffect } = await import('react')
  const subscribe = listener => { auth.listeners.add(listener); return () => auth.listeners.delete(listener) }
  const useAuth = () => ({ isSignedIn: useSyncExternalStore(subscribe, () => auth.signedIn) })
  function Widget({ entry, forceRedirectUrl, alternate }) {
    const navigate = useNavigate()
    const { isSignedIn } = useAuth()
    useEffect(() => { if (isSignedIn) navigate(forceRedirectUrl) }, [isSignedIn, navigate, forceRedirectUrl])
    return <div>
      <p data-testid="auth-target">{forceRedirectUrl}</p>
      <button onClick={() => navigate(`${entry}/${entry === '/sign-in' ? 'factor-one' : 'verify-email-address'}`)}>Continue nested auth</button>
      <Link to={alternate}>Switch auth form</Link>
      <button onClick={() => { auth.signedIn = true; auth.listeners.forEach(listener => listener()) }}>Complete authentication</button>
    </div>
  }
  return { useAuth,
    SignIn: props => <Widget entry="/sign-in" alternate={props.signUpUrl} {...props} />,
    SignUp: props => <Widget entry="/sign-up" alternate={props.signInUrl} {...props} /> }
})

let SignInPage
let SignUpPage
beforeAll(async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_auth_journey')
  ;({ default: SignInPage } = await import('./SignInPage'))
  ;({ default: SignUpPage } = await import('./SignUpPage'))
})
beforeEach(() => { auth.signedIn = false; window.sessionStorage.clear() })
afterEach(() => vi.restoreAllMocks())
afterAll(() => vi.unstubAllEnvs())

function LocationLabel() {
  const location = useLocation()
  return <p data-testid="location">{location.pathname}{location.search}{location.hash}</p>
}
function Navigation() {
  const navigate = useNavigate()
  return <>
    <button onClick={() => navigate('/sign-in?returnTo=%2Fadmin')}>Start new admin attempt</button>
    <button onClick={() => navigate('/sign-in')}>Start plain sign in</button>
    <button onClick={() => navigate(-1)}>Back</button>
  </>
}
function mount(path) {
  return render(<MemoryRouter initialEntries={[path]}><LocationLabel /><Navigation /><Routes>
    <Route path="/sign-in/*" element={<SignInPage />} />
    <Route path="/sign-up/*" element={<SignUpPage />} />
    <Route path="*" element={<p>Requested destination</p>} />
  </Routes></MemoryRouter>)
}

describe('Clerk auth return journey', () => {
  it.each(['/sign-in', '/sign-up'])('keeps the destination through %s nested steps without query', async entry => {
    mount(`${entry}?returnTo=%2Fmy-tickets`)
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    expect(screen.getByTestId('location').textContent).not.toContain('?')
    expect(screen.getByTestId('auth-target')).toHaveTextContent('/my-tickets')
    await userEvent.click(screen.getByRole('button', { name: 'Complete authentication' }))
    await screen.findByText('Requested destination')
    expect(screen.getByTestId('location')).toHaveTextContent('/my-tickets')
    expect(readAuthReturnIntent()).toBeNull()
  })

  it.each(['/sign-in', '/sign-up'])('resumes %s after a hard reload of its nested step', async entry => {
    const page = mount(`${entry}?returnTo=%2Fmy-tickets`)
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    const nested = screen.getByTestId('location').textContent
    page.unmount()
    mount(nested)
    expect(screen.getByTestId('auth-target')).toHaveTextContent('/my-tickets')
    await userEvent.click(screen.getByRole('button', { name: 'Complete authentication' }))
    await screen.findByText('Requested destination')
    expect(screen.getByTestId('location')).toHaveTextContent('/my-tickets')
  })

  it('preserves invitation query and fragment while switching sign-in/sign-up and verifying', async () => {
    const target = '/organization-invitations/accept?token=synthetic-invitation#accept'
    mount(`/sign-in?returnTo=${encodeURIComponent(target)}`)
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    await userEvent.click(screen.getByRole('link', { name: 'Switch auth form' }))
    expect(screen.getByTestId('location')).toHaveTextContent('/sign-up?returnTo=')
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    expect(screen.getByTestId('auth-target')).toHaveTextContent(target)
    await userEvent.click(screen.getByRole('link', { name: 'Switch auth form' }))
    await userEvent.click(screen.getByRole('button', { name: 'Complete authentication' }))
    await screen.findByText('Requested destination')
    expect(screen.getByTestId('location').textContent).toBe(target)
  })

  it('replaces old intent on a new top-level attempt and resets a plain entry', async () => {
    mount('/sign-in?returnTo=%2Fmy-tickets')
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    await userEvent.click(screen.getByRole('button', { name: 'Start new admin attempt' }))
    expect(screen.getByTestId('auth-target')).toHaveTextContent('/admin')
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    await userEvent.click(screen.getByRole('button', { name: 'Back' }))
    expect(screen.getByTestId('auth-target')).toHaveTextContent('/admin')
    await userEvent.click(screen.getByRole('button', { name: 'Start plain sign in' }))
    expect(screen.getByTestId('auth-target').textContent).toBe('/')
  })

  it.each(['https://untrusted.invalid', '//untrusted.invalid', '/\\untrusted.invalid'])('rejects an external destination %s throughout nested routes', async destination => {
    mount(`/sign-in?returnTo=${encodeURIComponent(destination)}`)
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    expect(screen.getByTestId('auth-target').textContent).toBe('/')
  })

  it('does not resume an expired intent on a nested reload', async () => {
    const page = mount('/sign-in?returnTo=%2Fmy-tickets')
    page.unmount()
    vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 31 * 60 * 1000)
    mount('/sign-in/factor-one')
    expect(screen.getByTestId('auth-target').textContent).toBe('/')
  })

  it('keeps the mounted journey usable when session storage is unavailable', async () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Storage unavailable') })
    mount('/sign-in?returnTo=%2Fmy-tickets')
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    expect(screen.getByTestId('auth-target')).toHaveTextContent('/my-tickets')
    await act(async () => { auth.signedIn = true; auth.listeners.forEach(listener => listener()) })
    await waitFor(() => expect(screen.getByTestId('location')).toHaveTextContent('/my-tickets'))
  })

  it('clears earlier intent when an already-signed-in account opens a fresh entry', async () => {
    const old = mount('/sign-in?returnTo=%2Fdashboard')
    old.unmount()
    auth.signedIn = true
    mount('/sign-in?returnTo=%2Fmy-tickets')
    await screen.findByText('Requested destination')
    expect(screen.getByTestId('location')).toHaveTextContent('/my-tickets')
    expect(readAuthReturnIntent()).toBeNull()
  })

  it('does not resume an older destination when saving its replacement fails', async () => {
    const page = mount('/sign-in?returnTo=%2Fmy-tickets')
    expect(readAuthReturnIntent()?.destination).toBe('/my-tickets')
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Quota exceeded') })
    await userEvent.click(screen.getByRole('button', { name: 'Start new admin attempt' }))
    await userEvent.click(screen.getByRole('button', { name: 'Continue nested auth' }))
    expect(screen.getByTestId('auth-target')).toHaveTextContent('/admin')
    const nested = screen.getByTestId('location').textContent
    page.unmount()
    mount(nested)
    expect(screen.getByTestId('auth-target').textContent).toBe('/')
    expect(readAuthReturnIntent()).toBeNull()
  })
})

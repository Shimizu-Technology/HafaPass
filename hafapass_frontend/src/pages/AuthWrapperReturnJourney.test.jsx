vi.mock('../components/SEO', () => ({ default: () => null }))
import 'fake-indexeddb/auto'
import { StrictMode } from 'react'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Navigate, useLocation, useNavigate } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

const sdk = vi.hoisted(() => ({ auth: null, user: null, listeners: new Set(), mounts: 0, completionCallbacks: [] }))
vi.mock('@clerk/clerk-react', async () => {
  const { useEffect, useSyncExternalStore } = await import('react')
  const subscribe = listener => { sdk.listeners.add(listener); return () => sdk.listeners.delete(listener) }
  const useAuth = () => useSyncExternalStore(subscribe, () => sdk.auth)
  const useUser = () => useSyncExternalStore(subscribe, () => sdk.user)
  function SignIn({ forceRedirectUrl }) {
    const navigate = useNavigate()
    useAuth(); useUser()
    useEffect(() => { ++sdk.mounts }, [])
    useEffect(() => { sdk.completionCallbacks.push(() => navigate(forceRedirectUrl)) }, [forceRedirectUrl, navigate])
    return <>
      <p data-testid="wrapper-auth-target">{forceRedirectUrl}</p>
      <button onClick={() => navigate('/sign-in/factor-one')}>Enter factor one</button>
    </>
  }
  return { ClerkProvider: ({ children }) => children, useAuth, useUser, SignIn }
})
vi.mock('../monitoring', () => ({ Sentry: { setUser: vi.fn(), captureException: vi.fn() } }))
vi.mock('../components/Navbar', () => ({ default: () => null }))
vi.mock('../components/Footer', () => ({ default: () => null }))
vi.mock('../components/EnvironmentBanner', () => ({ default: () => null }))
vi.mock('./MyTicketsPage', () => ({ default: () => <h1>Buyer My Tickets destination</h1> }))
vi.mock('./EventsPage', () => ({ default: () => <h1>Wrong Events destination</h1> }))
vi.mock('./HomePage', () => ({ default: () => <Navigate to="/events" replace /> }))

let Wrapper, App, store, authIntent
const publish = () => sdk.listeners.forEach(listener => listener())
function LocationLabel() {
  const location = useLocation()
  return <p data-testid="wrapper-location">{location.pathname}{location.search}</p>
}
function mount(path) {
  return render(<StrictMode><MemoryRouter initialEntries={[path]}><LocationLabel /><Wrapper><App /></Wrapper></MemoryRouter></StrictMode>)
}
beforeEach(async () => {
  vi.resetModules()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_wrapper_auth_journey')
  vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
  window.localStorage.clear(); window.sessionStorage.clear()
  Object.assign(sdk, { auth: { isLoaded: true, isSignedIn: false, userId: null, sessionId: null, getToken: vi.fn().mockResolvedValue('synthetic-auth-token') },
    user: { isLoaded: true, isSignedIn: false, user: null }, mounts: 0, completionCallbacks: [] })
  ;({ default: Wrapper } = await import('../components/ClerkProviderWrapper'))
  ;({ default: App } = await import('../App'))
  store = await import('../utils/admissionStore')
  authIntent = await import('../utils/authDestination')
  await store.clearAllAdmissionData()
})
afterEach(async () => {
  vi.restoreAllMocks(); vi.unstubAllEnvs()
  await store.clearAllAdmissionData()
  window.localStorage.clear(); window.sessionStorage.clear()
})

it.each([false, true])('retains return intent through real Wrapper rebinding/unmount with nested reload: %s', async reload => {
  let page = mount('/sign-in?returnTo=%2Fmy-tickets')
  await screen.findByTestId('wrapper-auth-target')
  await userEvent.click(screen.getByRole('button', { name: 'Enter factor one' }))
  expect(screen.getByTestId('wrapper-location').textContent).toBe('/sign-in/factor-one')
  if (reload) {
    page.unmount()
    sdk.completionCallbacks = [] // A real hard reload also discards old document callbacks.
    page = mount('/sign-in/factor-one')
    await screen.findByTestId('wrapper-auth-target')
  }
  // SDK sign-in precedes the matching user profile/account binding. Clerk's
  // redirect is deliberately delayed until the private binding is complete.
  await act(async () => {
    sdk.auth = { ...sdk.auth, isSignedIn: true, userId: 'synthetic-buyer', sessionId: 'synthetic-session' }
    publish()
  })
  expect(authIntent.readAuthReturnIntent()?.destination).toBe('/my-tickets')
  expect(screen.getByTestId('wrapper-auth-target')).toHaveTextContent('/my-tickets')
  const mountsBeforeBinding = sdk.mounts
  const originalPurge = store.clearAllAdmissionData
  let releasePurge
  const heldPurge = new Promise(resolve => { releasePurge = resolve })
  vi.spyOn(store, 'clearAllAdmissionData').mockImplementation(async options => { await heldPurge; return originalPurge(options) })
  // An owned synthetic prior binding requires the real wrapper's guarded IDB
  // purge, making the actual "Preparing your account" unmount observable.
  window.localStorage.setItem('hafapass_scanner_user_id', 'synthetic-prior-profile')
  await act(async () => {
    sdk.user = { isLoaded: true, isSignedIn: true, user: { id: 'synthetic-buyer' } }
    publish()
  })
  expect(await screen.findByText('Preparing your account…')).toBeInTheDocument()
  expect(screen.queryByTestId('wrapper-auth-target')).not.toBeInTheDocument()
  expect(authIntent.readAuthReturnIntent()?.destination).toBe('/my-tickets')
  await act(async () => releasePurge())
  await screen.findByTestId('wrapper-auth-target')
  expect(sdk.mounts).toBeGreaterThan(mountsBeforeBinding)
  expect(screen.getByTestId('wrapper-auth-target')).toHaveTextContent('/my-tickets')
  const callbacks = sdk.completionCallbacks.slice()
  await act(async () => callbacks[0]())
  await screen.findByRole('heading', { name: 'Buyer My Tickets destination' })
  await waitFor(() => expect(authIntent.readAuthReturnIntent()).toBeNull())
  // An already scheduled provider continuation can run after that first
  // navigation. Its remounted widget must still have received the same target.
  await act(async () => callbacks.at(-1)())
  expect(screen.getByTestId('wrapper-location').textContent).toBe('/my-tickets')
  expect(screen.queryByRole('heading', { name: 'Wrong Events destination' })).not.toBeInTheDocument()
  page.unmount()
})

import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Navigate, Route, Routes, useNavigate } from 'react-router-dom'
import HomePage from './HomePage'
import apiClient from '../api/client'

const auth = vi.hoisted(() => ({ isLoaded: true, isSignedIn: false }))
vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => <div>{children}</div> }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))
vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => auth,
  SignIn: function MockSignIn({ signUpUrl, forceRedirectUrl }) {
    const navigate = useNavigate()
    if (auth.isSignedIn) return <Navigate to={forceRedirectUrl} replace />
    return <div><h1>Sign in to continue</h1><Link to={signUpUrl}>Create an account</Link>
      <button onClick={() => { auth.isSignedIn = true; navigate(forceRedirectUrl) }}>Complete sign in</button></div>
  },
  SignUp: function MockSignUp({ signInUrl, forceRedirectUrl }) {
    const navigate = useNavigate()
    if (auth.isSignedIn) return <Navigate to={forceRedirectUrl} replace />
    return <div><h1>Create an account</h1><Link to={signInUrl}>Use an existing account</Link>
      <button onClick={() => { auth.isSignedIn = true; navigate(forceRedirectUrl) }}>Complete signup</button></div>
  },
}))

let ProtectedRoute
let SignInPage
let SignUpPage
beforeAll(async () => {
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_navigation_fixture')
  ;({ default: ProtectedRoute } = await import('../components/ProtectedRoute'))
  ;({ default: SignInPage } = await import('./SignInPage'))
  ;({ default: SignUpPage } = await import('./SignUpPage'))
})
afterAll(() => vi.unstubAllEnvs())

function mount() {
  return render(<MemoryRouter initialEntries={['/']}><Routes>
    <Route path='/' element={<HomePage />} />
    <Route path='/dashboard' element={<ProtectedRoute><h1>Create your organizer profile</h1></ProtectedRoute>} />
    <Route path='/sign-in' element={<SignInPage />} />
    <Route path='/sign-up' element={<SignUpPage />} />
  </Routes></MemoryRouter>)
}

const entryLink = entry => entry === 'footer'
  ? screen.getByRole('link', { name: 'footer.forOrganizers' })
  : screen.getAllByRole('link', { name: 'Start Hosting' })[entry === 'hero' ? 0 : 1]

describe('hosting entry navigation', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    auth.isSignedIn = false
    apiClient.get.mockResolvedValue({ data: { events: [] } })
  })

  it.each(['hero', 'bottom', 'footer'])('takes an already signed-in %s visitor directly into organizer setup', async entry => {
    auth.isSignedIn = true
    mount()
    await userEvent.setup().click(entryLink(entry))
    expect(await screen.findByRole('heading', { name: 'Create your organizer profile' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Create an account' })).not.toBeInTheDocument()
  })

  it.each(['hero', 'bottom', 'footer'])('retains %s hosting intent through guest sign-in and signup', async entry => {
    mount()
    const user = userEvent.setup()
    await user.click(entryLink(entry))
    expect(await screen.findByRole('heading', { name: 'Sign in to continue' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Create an account' })).toHaveAttribute('href', '/sign-up?returnTo=%2Fdashboard')
    await user.click(screen.getByRole('link', { name: 'Create an account' }))
    expect(await screen.findByRole('heading', { name: 'Create an account' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Use an existing account' })).toHaveAttribute('href', '/sign-in?returnTo=%2Fdashboard')
    await user.click(screen.getByRole('button', { name: 'Complete signup' }))
    expect(await screen.findByRole('heading', { name: 'Create your organizer profile' })).toBeInTheDocument()
  })

  it('returns an existing guest account to organizer setup after sign in', async () => {
    mount()
    const user = userEvent.setup()
    await user.click(entryLink('footer'))
    await user.click(await screen.findByRole('button', { name: 'Complete sign in' }))
    expect(await screen.findByRole('heading', { name: 'Create your organizer profile' })).toBeInTheDocument()
  })

  it('keeps event browsing separate while preserving the organizer call to action', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [{ id: 37, slug: 'workshop', title: 'Workshop', starts_at: '2099-10-20T08:00:00Z', timezone: 'Pacific/Guam', ticket_types: [] }] } })
    mount()
    expect(await screen.findByRole('link', { name: 'Browse Events' })).toHaveAttribute('href', '/events')
    expect(screen.getByRole('link', { name: 'Start Hosting' })).toHaveAttribute('href', '/dashboard')
    expect(screen.getByRole('link', { name: 'footer.signIn' })).toHaveAttribute('href', '/sign-in')
  })
})

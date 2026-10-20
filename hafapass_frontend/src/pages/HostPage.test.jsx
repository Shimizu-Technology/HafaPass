import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Link, MemoryRouter, Navigate, Route, Routes, useNavigate } from 'react-router-dom'

const auth = vi.hoisted(() => ({ isLoaded: true, isSignedIn: false }))
// Shared across module resets so each fresh HostPage import sees the same mock.
const apiClient = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('../api/client', () => ({ default: apiClient }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('@clerk/clerk-react', () => ({
  useAuth: () => auth,
  SignIn: function MockSignIn({ forceRedirectUrl }) {
    const navigate = useNavigate()
    return <div><h1>Sign in to continue</h1><button onClick={() => { auth.isSignedIn = true; navigate(forceRedirectUrl) }}>Complete sign in</button></div>
  },
  SignUp: function MockSignUp({ signInUrl, forceRedirectUrl }) {
    const navigate = useNavigate()
    if (auth.isSignedIn) return <Navigate to={forceRedirectUrl} replace />
    return <div><h1>Create an account</h1><Link to={signInUrl}>Use an existing account</Link>
      <button onClick={() => { auth.isSignedIn = true; navigate(forceRedirectUrl) }}>Complete signup</button></div>
  },
}))

const launchConfig = { service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 business days after your event' }

async function load({ clerkKey = 'pk_test_host_fixture' } = {}) {
  vi.resetModules()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', clerkKey)
  const [{ default: HostPage }, { default: ProtectedRoute }, { default: SignInPage }, { default: SignUpPage }] = await Promise.all([
    import('./HostPage'), import('../components/ProtectedRoute'), import('./SignInPage'), import('./SignUpPage'),
  ])
  return render(<MemoryRouter initialEntries={['/host']}><Routes>
    <Route path='/host' element={<HostPage />} />
    <Route path='/dashboard' element={<ProtectedRoute><h1>Create your organizer profile</h1></ProtectedRoute>} />
    <Route path='/sign-in' element={<SignInPage />} />
    <Route path='/sign-up' element={<SignUpPage />} />
  </Routes></MemoryRouter>)
}

const pricing = () => screen.getByRole('region', { name: 'Simple pricing. You only pay when you sell.' })

beforeEach(() => {
  apiClient.get.mockReset()
  apiClient.get.mockResolvedValue({ data: launchConfig })
  Object.assign(auth, { isLoaded: true, isSignedIn: false })
  window.sessionStorage.clear()
})
afterEach(() => vi.unstubAllEnvs())

describe('host page pricing', () => {
  it('shows the configured fee, launch promises and a working calculator', async () => {
    await load()
    expect(await screen.findByTestId('host-fee-summary')).toHaveTextContent('5% + $1.00 per paid ticket')
    expect(apiClient.get).toHaveBeenCalledWith('/config')
    const section = pricing()
    expect(within(section).getByText('Card processing included')).toBeInTheDocument()
    expect(within(section).getByText('Payouts within 3 business days after your event')).toBeInTheDocument()

    const price = within(section).getByLabelText('Ticket price')
    expect(price).toHaveAttribute('inputmode', 'decimal')
    const pass = within(section).getByRole('region', { name: 'Buyer pays the fee' })
    const absorb = within(section).getByRole('region', { name: 'You absorb the fee' })
    expect(within(pass).getByText('$27.25')).toBeInTheDocument()
    expect(within(absorb).getByText('$22.75')).toBeInTheDocument()

    const user = userEvent.setup()
    await user.clear(price)
    await user.type(price, '40')
    await user.clear(within(section).getByLabelText('Tickets'))
    await user.type(within(section).getByLabelText('Tickets'), '2')
    // 5% of $80 = $4.00 plus 2 x $1.00.
    expect(within(pass).getByText('Buyer pays for 2 tickets').nextSibling).toHaveTextContent('$86.00')
    expect(within(absorb).getByText('You receive').nextSibling).toHaveTextContent('$74.00')
    expect(within(absorb).getByText('HåfaPass fee').nextSibling).toHaveTextContent('$6.00')

    await user.clear(price)
    await user.type(price, '0')
    expect(within(section).getByText('Free tickets have no HåfaPass fee.')).toBeInTheDocument()
    expect(within(absorb).getByText('You receive').nextSibling).toHaveTextContent('$0.00')

    await user.clear(price)
    await user.type(price, '12.345')
    expect(price).toHaveAttribute('aria-invalid', 'true')
    expect(price).toHaveAccessibleDescription(/Enter a ticket price like 25 or 12.50/)
    expect(within(pass).getByText('You receive').nextSibling).toHaveTextContent('—')
  })

  it('answers FAQ questions with the configured fee and payout timing', async () => {
    await load()
    await screen.findByTestId('host-fee-summary')
    expect(screen.getByText(/HåfaPass charges 5% \+ \$1\.00 per paid ticket, with card processing included/)).toBeInTheDocument()
    expect(screen.getByText(/Payouts are sent within 3 business days after your event/)).toBeInTheDocument()
  })

  it('hides optional claims the API does not confirm', async () => {
    apiClient.get.mockResolvedValue({ data: { service_fee_percent: '5.0', service_fee_flat_cents: 100 } })
    await load()
    await screen.findByTestId('host-fee-summary')
    expect(screen.queryByText('Card processing included')).not.toBeInTheDocument()
    expect(screen.queryByText(/Payouts within/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Card processing is/)).not.toBeInTheDocument()
  })

  it('shows a calm fallback without numbers when pricing is missing, then recovers on retry', async () => {
    apiClient.get.mockResolvedValueOnce({ data: { payment_mode: 'test' } }).mockResolvedValueOnce({ data: launchConfig })
    await load()
    expect(await screen.findByText('Current rates aren’t available right now')).toBeInTheDocument()
    const section = pricing()
    expect(within(section).queryByLabelText('Ticket price')).not.toBeInTheDocument()
    expect(within(section).queryByText(/\$\d/)).not.toBeInTheDocument()
    expect(within(section).queryByText(/\d%/)).not.toBeInTheDocument()
    expect(within(section).getByText('Free tickets are always free')).toBeInTheDocument()
    expect(screen.getByText(/Paid tickets carry a per-ticket HåfaPass fee\. There are no setup/)).toBeInTheDocument()
    await userEvent.setup().click(within(section).getByRole('button', { name: 'Try again' }))
    expect(await screen.findByTestId('host-fee-summary')).toHaveTextContent('5% + $1.00 per paid ticket')
  })

  it('treats a failed config request the same way', async () => {
    apiClient.get.mockRejectedValue(new Error('Network unavailable'))
    await load()
    expect(await screen.findByText('Current rates aren’t available right now')).toBeInTheDocument()
    expect(screen.queryByTestId('host-fee-summary')).not.toBeInTheDocument()
  })
})

describe('host page calls to action', () => {
  it('sends guests through signup and lands them in organizer setup', async () => {
    await load()
    const [hero] = screen.getAllByRole('link', { name: /Start hosting/ })
    expect(hero).toHaveAttribute('href', '/sign-up?returnTo=%2Fdashboard')
    screen.getAllByRole('link', { name: 'Sign in' }).forEach(link => expect(link).toHaveAttribute('href', '/sign-in?returnTo=%2Fdashboard'))
    const user = userEvent.setup()
    await user.click(hero)
    expect(await screen.findByRole('heading', { name: 'Create an account' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Use an existing account' })).toHaveAttribute('href', '/sign-in?returnTo=%2Fdashboard')
    await user.click(screen.getByRole('button', { name: 'Complete signup' }))
    expect(await screen.findByRole('heading', { name: 'Create your organizer profile' })).toBeInTheDocument()
  })

  it('returns an existing account to organizer setup after sign in', async () => {
    await load()
    const user = userEvent.setup()
    await user.click(screen.getAllByRole('link', { name: 'Sign in' })[1])
    await user.click(await screen.findByRole('button', { name: 'Complete sign in' }))
    expect(await screen.findByRole('heading', { name: 'Create your organizer profile' })).toBeInTheDocument()
  })

  it('takes signed-in organizers straight to the dashboard', async () => {
    auth.isSignedIn = true
    await load()
    const links = screen.getAllByRole('link', { name: /Go to your dashboard/ })
    expect(links).toHaveLength(2)
    links.forEach(link => expect(link).toHaveAttribute('href', '/dashboard'))
    expect(screen.queryByRole('link', { name: 'Sign in' })).not.toBeInTheDocument()
    await userEvent.setup().click(links[0])
    expect(await screen.findByRole('heading', { name: 'Create your organizer profile' })).toBeInTheDocument()
  })

  it('lets the protected dashboard decide while the account is still loading', async () => {
    auth.isLoaded = false
    await load()
    screen.getAllByRole('link', { name: /Start hosting/ }).forEach(link => expect(link).toHaveAttribute('href', '/dashboard'))
    expect(screen.queryByRole('link', { name: 'Sign in' })).not.toBeInTheDocument()
  })

  it('goes straight to the dashboard when sign-in is not configured locally', async () => {
    await load({ clerkKey: '' })
    screen.getAllByRole('link', { name: /Start hosting/ }).forEach(link => expect(link).toHaveAttribute('href', '/dashboard'))
  })
})

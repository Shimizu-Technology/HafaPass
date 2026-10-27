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

// The fee fields the API sends today; the bearer and payout fields are optional.
const feeOnlyConfig = { service_fee_percent: '5.0', service_fee_flat_cents: 100 }
const platformConfig = { ...feeOnlyConfig, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 business days after your event' }
const organizerConfig = { ...feeOnlyConfig, processing_fee_bearer: 'organizer', payout_schedule_text: 'within 3 business days after your event' }

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

const pricing = () => screen.getByRole('region', { name: 'Host your event with HåfaPass' })

beforeEach(() => {
  apiClient.get.mockReset()
  apiClient.get.mockResolvedValue({ data: feeOnlyConfig })
  Object.assign(auth, { isLoaded: true, isSignedIn: false })
  window.sessionStorage.clear()
})
afterEach(() => vi.unstubAllEnvs())

describe('host page pricing', () => {
  const user = () => userEvent.setup()
  const setOrder = async (price, quantity) => {
    const section = pricing()
    await user().clear(within(section).getByLabelText('Ticket price'))
    if (price) await user().type(within(section).getByLabelText('Ticket price'), price)
    await user().clear(within(section).getByLabelText('Tickets'))
    await user().type(within(section).getByLabelText('Tickets'), quantity)
  }
  const value = (card, label) => within(within(pricing()).getByRole('region', { name: card })).getByText(label).nextSibling

  it('keeps the full ticket price for the organizer when HåfaPass covers card processing', async () => {
    apiClient.get.mockResolvedValue({ data: platformConfig })
    await load()
    expect(await screen.findByTestId('host-fee-summary')).toHaveTextContent('5% + $1.00 per paid ticket')
    expect(apiClient.get).toHaveBeenCalledWith('/config')
    const section = pricing()
    expect(within(section).getByText('Card processing included')).toBeInTheDocument()
    expect(within(section).getByText('Payouts within 3 business days after your event')).toBeInTheDocument()
    expect(within(section).getByLabelText('Ticket price')).toHaveAttribute('inputmode', 'decimal')
    expect(within(section).getByText(/Card processing is included in the HåfaPass fee/)).toBeInTheDocument()

    // Default $25 x 1: fee $1.25 + $1.00.
    expect(value('Buyer pays the fee', 'Buyer pays for 1 ticket')).toHaveTextContent('$27.25')
    expect(value('Buyer pays the fee', 'You receive')).toHaveTextContent('$25.00')
    expect(value('You absorb the fee', 'You receive')).toHaveTextContent('$22.75')
    expect(within(section).getByRole('status')).toHaveTextContent('Buyer pays $27.25, you receive $25.00; if you absorb the fee, you receive $22.75.')
    expect(section.querySelector('[aria-live]')).toBeNull()

    await setOrder('40', '2')
    // 5% of $80 = $4.00 plus 2 x $1.00.
    expect(value('Buyer pays the fee', 'Buyer pays for 2 tickets')).toHaveTextContent('$86.00')
    expect(value('You absorb the fee', 'HåfaPass fee')).toHaveTextContent('$6.00')
    expect(value('You absorb the fee', 'You receive')).toHaveTextContent('$74.00')
    expect(screen.getByText(/HåfaPass charges 5% \+ \$1\.00 per paid ticket, with card processing included/)).toBeInTheDocument()
    expect(screen.getByText(/Payouts are sent within 3 business days after your event/)).toBeInTheDocument()
  })

  it.each([
    ['the organizer bears card processing', organizerConfig],
    ['the API does not say who bears card processing', feeOnlyConfig],
  ])('labels proceeds as before card processing when %s', async (_case, config) => {
    apiClient.get.mockResolvedValue({ data: config })
    await load()
    await screen.findByTestId('host-fee-summary')
    const section = pricing()
    expect(within(section).queryByText('Card processing included')).not.toBeInTheDocument()
    expect(within(section).queryAllByText('You receive')).toHaveLength(0)
    expect(value('Buyer pays the fee', 'You receive before card processing')).toHaveTextContent('$25.00')
    expect(value('You absorb the fee', 'You receive before card processing')).toHaveTextContent('$22.75')
    expect(within(section).getByText(/Card processing is deducted from your proceeds at settlement/)).toBeInTheDocument()
    expect(within(section).getByRole('status')).toHaveTextContent('if you absorb the fee, you receive $22.75, before card processing.')
    expect(screen.getByText(/HåfaPass charges 5% \+ \$1\.00 per paid ticket\. Card processing is deducted/)).toBeInTheDocument()
  })

  it('computes both worked examples from the loaded rate and preserves verification and cancellation caveats', async () => {
    apiClient.get.mockResolvedValue({ data: { ...platformConfig, service_fee_percent: '6.0', service_fee_flat_cents: 175 } })
    await load()
    await screen.findByTestId('host-fee-summary')
    const example = screen.getByRole('region', { name: '$59.00 ticket' })
    expect(within(example).getByText('$64.29')).toBeInTheDocument()
    expect(within(example).getByText('$59.00')).toBeInTheDocument()
    expect(within(example).getByText('$53.71')).toBeInTheDocument()
    const smaller = screen.getByRole('region', { name: '$25.00 ticket' })
    expect(within(smaller).getByText('$28.25')).toBeInTheDocument()
    expect(within(smaller).getByText('$21.75')).toBeInTheDocument()
    expect(screen.getByText(/only available through a private preview link/)).toBeInTheDocument()
    expect(screen.getAllByText(/Each device must be prepared online/)).toHaveLength(2)
    expect(screen.getAllByText(/automatically start eligible card refunds, including the service fee/)).toHaveLength(2)
  })

  it('shows payout timing only when the API provides it', async () => {
    apiClient.get.mockResolvedValue({ data: feeOnlyConfig })
    await load()
    await screen.findByTestId('host-fee-summary')
    expect(screen.queryByText(/Payouts within/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Payouts are sent/)).not.toBeInTheDocument()
    expect(screen.getByText(/your dashboard shows a settlement statement/)).toBeInTheDocument()
  })

  it('handles free tickets, a fee larger than the ticket and invalid prices', async () => {
    apiClient.get.mockResolvedValue({ data: platformConfig })
    await load()
    await screen.findByTestId('host-fee-summary')
    const section = pricing()
    await setOrder('0', '3')
    expect(within(section).getByText('Free tickets have no HåfaPass fee.')).toBeInTheDocument()
    expect(value('You absorb the fee', 'HåfaPass fee')).toHaveTextContent('$0.00')

    await setOrder('0.50', '1')
    // 5% of $0.50 rounds to $0.03 plus $1.00: absorbed proceeds floor at $0.00, like checkout.
    expect(value('You absorb the fee', 'HåfaPass fee')).toHaveTextContent('$1.03')
    expect(value('You absorb the fee', 'You receive')).toHaveTextContent('$0.00')
    expect(within(section).getByText(/the fee is more than the ticket price/)).toBeInTheDocument()

    await setOrder('12.345', '1')
    const price = within(section).getByLabelText('Ticket price')
    expect(price).toHaveAttribute('aria-invalid', 'true')
    expect(price).toHaveAccessibleDescription(/Enter a ticket price like 25 or 12.50/)
    expect(value('Buyer pays the fee', 'You receive')).toHaveTextContent('—')
    expect(within(section).getByRole('status')).toBeEmptyDOMElement()
  })

  it('shows a calm fallback without numbers when pricing is missing, then recovers on retry', async () => {
    apiClient.get.mockResolvedValueOnce({ data: { payment_mode: 'test' } }).mockResolvedValueOnce({ data: platformConfig })
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

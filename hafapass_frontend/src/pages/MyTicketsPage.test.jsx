import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import MyTicketsPage from './MyTicketsPage'

const launch = vi.hoisted(() => ({ value: {} }))
vi.mock('../hooks/useLaunchCapabilities', () => ({ default: () => launch.value }))
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
const clerk = vi.hoisted(() => ({ getToken: vi.fn(), signOut: vi.fn() }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ getToken: clerk.getToken }), useClerk: () => ({ signOut: clerk.signOut }) }))
vi.mock('../components/ui/ScrollReveal', () => ({
  StaggerContainer: ({ children }) => <div>{children}</div>,
  StaggerItem: ({ children }) => <div>{children}</div>,
}))

const ticket = {
  id: 3, order_id: 2, display_credential: 'synthetic-display-credential', status: 'issued',
  attendee_name: 'Synthetic Buyer', ticket_type: { name: 'General admission' },
  event: { id: 1, title: 'Island workshop', slug: 'island-workshop', timezone: 'Pacific/Guam', starts_at: '2030-01-01T08:00:00Z' },
}
const renderPage = () => render(<HelmetProvider><MemoryRouter><MyTicketsPage /></MemoryRouter></HelmetProvider>)

describe('MyTicketsPage guest recovery', () => {
  beforeEach(() => { apiClient.get.mockReset(); apiClient.post.mockReset() })

  it('discovers guest purchases after loading known tickets and displays the recovered entry', async () => {
    apiClient.get.mockResolvedValueOnce({ data: { tickets: [] } }).mockResolvedValueOnce({ data: { tickets: [ticket] } })
    apiClient.post.mockResolvedValue({ data: { recovered_orders_count: 1 } })
    renderPage()
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledWith('/me/orders/recover_guest')
    expect(apiClient.get).toHaveBeenCalledTimes(2)
    expect(screen.getByText('General admission').closest('a')).toHaveAttribute('href', '/tickets/synthetic-display-credential')
  })

  it('keeps known tickets visible during failed discovery and recovers on explicit retry', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [ticket] } })
    apiClient.post.mockRejectedValueOnce({ response: { status: 503, data: { code: 'identity_verification_unavailable' } } })
      .mockResolvedValueOnce({ data: {} })
    renderPage()
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    await userEvent.click(await screen.findByRole('button', { name: 'Retry guest purchase recovery' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Retry guest purchase recovery' })).not.toBeInTheDocument())
    expect(screen.getByText('Island workshop')).toBeInTheDocument()
  })

  it('does not report no tickets when guest discovery is unavailable', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [] } })
    apiClient.post.mockRejectedValue(new Error('identity unavailable'))
    renderPage()
    expect(await screen.findByText('Guest purchases need another check')).toBeInTheDocument()
    expect(screen.queryByText('No tickets yet')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Recover an order by email' })).toHaveAttribute('href', '/orders/recover')
  })

  it('keeps known tickets when the post-recovery refresh fails', async () => {
    apiClient.get.mockResolvedValueOnce({ data: { tickets: [ticket] } }).mockRejectedValueOnce(new Error('API unavailable'))
    apiClient.post.mockResolvedValue({ data: { recovered_orders_count: 1 } })
    renderPage()
    await screen.findByRole('button', { name: 'Retry guest purchase recovery' })
    expect(screen.getByText('Island workshop')).toBeInTheDocument()
  })

  it('does not fetch tickets again when recovery changes nothing', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [ticket] } })
    apiClient.post.mockResolvedValue({ data: { recovered_orders_count: 0, recovered_tickets_count: 0 } })
    renderPage()
    await screen.findByText('Island workshop')
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(1))
    expect(apiClient.get).toHaveBeenCalledTimes(1)
  })
})

describe('MyTicketsPage orders tab', () => {
  const purchase = {
    id: 9, reference: 'HP-9', buyer_status: 'partially_refunded', completed_at: '2030-01-01T01:00:00Z',
    event: { id: 1, title: 'Island workshop', timezone: 'Pacific/Guam', starts_at: '2030-01-02T08:00:00Z' },
    order_items: [{ id: 4, item_kind: 'ticket', name: 'General admission', quantity: 2 }],
    refund_history: [{ id: 10, status: 'pending', amount_cents: 1000 }],
    service_fee_cents: 250, discount_cents: 100, total_cents: 5150,
  }

  beforeEach(() => {
    apiClient.get.mockReset()
    apiClient.post.mockReset().mockResolvedValue({ data: {} })
  })

  it('keeps tickets and exposes a paginated, linked order list', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/me/orders'
      ? { orders: [purchase], meta: { current_page: 1, total_pages: 2, next_page: 2, prev_page: null } }
      : { tickets: [ticket] } }))
    renderPage()
    expect(await screen.findByRole('tab', { name: 'Tickets' })).toHaveAttribute('aria-selected', 'true')
    expect(await screen.findByText('General admission')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('tab', { name: 'Orders' }))
    expect(await screen.findByText('Order HP-9')).toBeInTheDocument()
    expect(screen.getByText('Partially refunded')).toBeInTheDocument()
    expect(screen.getByText('Refund pending')).toBeInTheDocument()
    expect(screen.getByText('General admission × 2')).toBeInTheDocument()
    expect(screen.getByText(/Total paid: \$51.50/)).toBeInTheDocument()
    expect(screen.getByText('Island workshop').closest('a')).toHaveAttribute('href', '/orders/9/confirmation')
    await userEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(apiClient.get).toHaveBeenCalledWith('/me/orders', { params: { page: 2 } })
  })

  it('shows loading, empty and retry states for orders', async () => {
    let finishOrders
    apiClient.get.mockImplementation(url => url === '/me/orders' ? new Promise(resolve => { finishOrders = resolve }) : Promise.resolve({ data: { tickets: [] } }))
    renderPage()
    await userEvent.click(await screen.findByRole('tab', { name: 'Orders' }))
    expect(await screen.findByText('Loading orders…')).toBeInTheDocument()
    finishOrders({ data: { orders: [], meta: { current_page: 1, total_pages: 1 } } })
    expect(await screen.findByText('No orders yet')).toBeInTheDocument()
    apiClient.get.mockImplementation(url => url === '/me/orders' ? Promise.reject(new Error('offline')) : Promise.resolve({ data: { tickets: [] } }))
    await userEvent.click(screen.getByRole('tab', { name: 'Tickets' }))
    await userEvent.click(screen.getByRole('tab', { name: 'Orders' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('We couldn’t load your orders')
  })

  it('loads every ticket page before grouping events', async () => {
    const second = { ...ticket, id: 4, display_credential: 'second-page-credential', ticket_type: { name: 'VIP' } }
    apiClient.get.mockImplementation((url, options) => Promise.resolve({ data: url === '/me/tickets' && options?.params?.page === 2
      ? { tickets: [second], meta: { next_page: null } }
      : { tickets: [ticket], meta: { next_page: 2 } } }))
    renderPage()
    expect(await screen.findByText('VIP')).toBeInTheDocument()
    expect(screen.getByText('General admission')).toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledWith('/me/tickets', { params: { page: 2 } })
  })

  it('shows the first ticket page while the next page is pending', async () => {
    let finishSecond
    apiClient.get.mockImplementation((url, options) => url === '/me/tickets' && options?.params?.page === 2
      ? new Promise(resolve => { finishSecond = resolve })
      : Promise.resolve({ data: { tickets: [ticket], meta: { next_page: 2 } } }))
    renderPage()
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    expect(finishSecond).toBeTypeOf('function')
    finishSecond({ data: { tickets: [], meta: {} } })
  })

  it('loads Orders while a ticket page is unresolved', async () => {
    let finishTickets
    apiClient.get.mockImplementation(url => url === '/me/tickets'
      ? new Promise(resolve => { finishTickets = resolve })
      : Promise.resolve({ data: { orders: [purchase], meta: {} } }))
    renderPage()
    await userEvent.click(screen.getByRole('tab', { name: 'Orders' }))
    expect(await screen.findByText('Order HP-9')).toBeInTheDocument()
    finishTickets({ data: { tickets: [] } })
  })

  it('stops at repeated or non-advancing ticket pages', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [ticket], meta: { next_page: 1 } } })
    renderPage()
    await screen.findByText('Island workshop')
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(1))
    expect(apiClient.get).toHaveBeenCalledTimes(1)
  })

  it('caps ticket pagination even when the server always advertises another page', async () => {
    apiClient.get.mockImplementation((url, options) => Promise.resolve({ data: {
      tickets: [ticket], meta: { next_page: (options?.params?.page || 1) + 1 },
    } }))
    renderPage()
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(1))
    expect(apiClient.get).toHaveBeenCalledTimes(20)
  })

  it('labels test purchases and supports tab keyboard navigation', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/me/orders'
      ? { orders: [{ ...purchase, payment_environment: 'test' }], meta: {} }
      : { tickets: [ticket] } }))
    renderPage()
    const ticketsTab = screen.getByRole('tab', { name: 'Tickets' })
    ticketsTab.focus()
    await userEvent.keyboard('{ArrowRight}')
    const ordersTab = screen.getByRole('tab', { name: 'Orders' })
    await waitFor(() => expect(ordersTab).toHaveFocus())
    expect(ordersTab).toHaveAttribute('tabindex', '0')
    expect(ticketsTab).toHaveAttribute('tabindex', '-1')
    expect(ordersTab).toHaveAttribute('aria-controls', 'history-orders-panel')
    expect(await screen.findByText('Test order — no real charge')).toBeInTheDocument()
    expect(screen.getByText(/Test total \(no real charge\): \$51.50/)).toBeInTheDocument()
    await userEvent.keyboard('{Home}')
    await waitFor(() => expect(ticketsTab).toHaveFocus())
    await userEvent.keyboard('{End}')
    await waitFor(() => expect(ordersTab).toHaveFocus())
    await userEvent.keyboard('{ArrowLeft}')
    await waitFor(() => expect(ticketsTab).toHaveFocus())
  })
})

describe('MyTicketsPage expired session', () => {
  beforeEach(() => {
    apiClient.get.mockReset(); apiClient.post.mockReset()
    clerk.getToken.mockReset().mockResolvedValue('fresh-token'); clerk.signOut.mockReset()
  })
  afterEach(() => vi.unstubAllEnvs())
  const renderAt = () => render(<HelmetProvider><MemoryRouter initialEntries={['/my-tickets']}><MyTicketsPage /></MemoryRouter></HelmetProvider>)

  it('retries once with a fresh token before showing any sign-in prompt', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_fixture')
    apiClient.get.mockRejectedValueOnce({ response: { status: 401 } }).mockResolvedValue({ data: { tickets: [ticket] } })
    apiClient.post.mockResolvedValue({ data: {} })
    renderAt()
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    expect(clerk.getToken).toHaveBeenCalledWith({ skipCache: true })
    expect(screen.queryByRole('heading', { name: 'Your session expired' })).not.toBeInTheDocument()
  })

  it('signs out the stale session and returns here after sign-in when the refreshed token is still rejected', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_fixture')
    apiClient.get.mockRejectedValue({ response: { status: 401 } })
    renderAt()
    expect(await screen.findByRole('heading', { name: 'Your session expired' })).toBeInTheDocument()
    expect(clerk.getToken).toHaveBeenCalledTimes(1)
    expect(apiClient.get).toHaveBeenCalledTimes(2)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Sign in again' }))
    expect(clerk.signOut).toHaveBeenCalledWith({ redirectUrl: '/sign-in?returnTo=%2Fmy-tickets' })
  })

  it('treats a failed token refresh as a retryable load error, not an expired session', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_fixture')
    clerk.getToken.mockRejectedValueOnce(new Error('Clerk offline'))
    apiClient.get.mockRejectedValueOnce({ response: { status: 401 } }).mockResolvedValue({ data: { tickets: [ticket] } })
    apiClient.post.mockResolvedValue({ data: {} })
    renderAt()
    expect(await screen.findByRole('alert')).toHaveTextContent('We couldn’t load your tickets. Try again.')
    expect(screen.queryByRole('heading', { name: 'Your session expired' })).not.toBeInTheDocument()
    expect(apiClient.get).toHaveBeenCalledTimes(1)
    expect(clerk.signOut).not.toHaveBeenCalled()
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
  })

  it('links to sign-in when Clerk is not configured', async () => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
    apiClient.get.mockRejectedValue({ response: { status: 401 } })
    renderAt()
    expect(await screen.findByRole('link', { name: 'Sign in again' })).toHaveAttribute('href', '/sign-in?returnTo=%2Fmy-tickets')
    expect(apiClient.get).toHaveBeenCalledTimes(1)
  })

  it('keeps real load failures as a retryable error', async () => {
    apiClient.get.mockRejectedValueOnce({ response: { status: 500 } }).mockResolvedValue({ data: { tickets: [ticket] } })
    apiClient.post.mockResolvedValue({ data: {} })
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('We couldn’t load your tickets. Try again.')
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
  })
})

describe('MyTicketsPage transfers', () => {
  const transferable = { ...ticket, event: { ...ticket.event, transfers_enabled: true } }
  beforeEach(() => { apiClient.get.mockReset(); apiClient.post.mockReset(); launch.value = { ticket_transfers: true } })
  afterEach(() => { launch.value = {} })

  it('hides Transfer while the platform capability is off', async () => {
    launch.value = { ticket_transfers: false }
    apiClient.get.mockResolvedValue({ data: { tickets: [transferable] } })
    apiClient.post.mockResolvedValue({ data: {} })
    renderPage()
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Transfer' })).not.toBeInTheDocument()
  })

  it('hides Transfer when the event does not allow it', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [{ ...ticket, event: { ...ticket.event, transfers_enabled: false } }] } })
    apiClient.post.mockResolvedValue({ data: {} })
    renderPage()
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Transfer' })).not.toBeInTheDocument()
  })

  it('sends a transfer from a dialog and keeps the address after an error', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [transferable] } })
    apiClient.post.mockImplementation(url => url === '/me/orders/recover_guest' ? Promise.resolve({ data: {} })
      : apiClient.post.mock.calls.filter(([path]) => path.endsWith('/transfer')).length === 1
        ? Promise.reject({ response: { status: 422, data: { error: 'Recipient must be different from the current ticket holder' } } })
        : Promise.resolve({ data: { id: 9, status: 'pending' } }))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Transfer' }))
    const dialog = screen.getByRole('dialog', { name: /Transfer your General admission ticket/ })
    expect(dialog).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Send transfer' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Enter the recipient’s email address.')
    expect(screen.getByLabelText('Recipient email')).toHaveFocus()
    await userEvent.type(screen.getByLabelText('Recipient email'), 'friend@example.com')
    await userEvent.click(screen.getByRole('button', { name: 'Send transfer' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Recipient must be different')
    expect(screen.getByLabelText('Recipient email')).toHaveValue('friend@example.com')
    await waitFor(() => expect(screen.getByLabelText('Recipient email')).toHaveFocus())
    await userEvent.click(screen.getByRole('button', { name: 'Send transfer' }))
    expect(await screen.findByRole('dialog', { name: 'Transfer sent' })).toHaveTextContent('friend@example.com')
    expect(apiClient.post).toHaveBeenLastCalledWith('/me/tickets/3/transfer', { recipient_email: 'friend@example.com', recipient_name: undefined })
    await userEvent.click(screen.getByRole('button', { name: 'Done' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  const pending = { ...transferable, pending_transfer: { id: 9, recipient_email: 'friend@example.com', expires_at: '2029-12-27T08:00:00Z' } }

  it('shows a pending transfer instead of Transfer and returns the ticket to normal after cancel', async () => {
    let tickets = [pending]
    apiClient.get.mockImplementation(() => Promise.resolve({ data: { tickets } }))
    apiClient.post.mockResolvedValue({ data: {} })
    apiClient.delete.mockImplementation(() => { tickets = [transferable]; return Promise.resolve({ data: { status: 'cancelled' } }) })
    renderPage()
    expect((await screen.findByText(/Transfer pending/)).closest('p')).toHaveTextContent('sent to friend@example.com · expires Dec 27')
    expect(screen.queryByRole('button', { name: 'Transfer' })).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Cancel transfer' }))
    await userEvent.click(within(screen.getByRole('dialog', { name: 'Cancel this transfer?' })).getByRole('button', { name: 'Cancel transfer' }))
    expect(apiClient.delete).toHaveBeenCalledWith('/me/tickets/3/transfer')
    expect(await screen.findByText('Transfer cancelled. Your ticket stays with you.')).toBeInTheDocument()
    expect(await screen.findByRole('button', { name: 'Transfer' })).toBeInTheDocument()
    expect(screen.queryByText(/Transfer pending/)).not.toBeInTheDocument()
  })

  it('refreshes gracefully when the recipient already accepted', async () => {
    let tickets = [pending]
    apiClient.get.mockImplementation(() => Promise.resolve({ data: { tickets } }))
    apiClient.post.mockResolvedValue({ data: {} })
    apiClient.delete.mockImplementation(() => { tickets = []; return Promise.reject({ response: { status: 404, data: { error: 'Ticket not found' } } }) })
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Cancel transfer' }))
    await userEvent.click(within(screen.getByRole('dialog', { name: 'Cancel this transfer?' })).getByRole('button', { name: 'Cancel transfer' }))
    expect(await screen.findByText(/This transfer already ended/)).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByText('Island workshop')).not.toBeInTheDocument())
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('keeps the dialog open with an error when cancelling fails for another reason', async () => {
    apiClient.get.mockResolvedValue({ data: { tickets: [pending] } })
    apiClient.post.mockResolvedValue({ data: {} })
    apiClient.delete.mockRejectedValue(new Error('offline'))
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Cancel transfer' }))
    const dialog = screen.getByRole('dialog', { name: 'Cancel this transfer?' })
    await userEvent.click(within(dialog).getByRole('button', { name: 'Cancel transfer' }))
    expect(await within(dialog).findByRole('alert')).toHaveTextContent('We could not cancel the transfer')
  })

  it('reloads the list after sending so the pending state appears', async () => {
    let tickets = [transferable]
    apiClient.get.mockImplementation(() => Promise.resolve({ data: { tickets } }))
    apiClient.post.mockImplementation(url => {
      if (url.endsWith('/transfer')) tickets = [pending]
      return Promise.resolve({ data: {} })
    })
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Transfer' }))
    await userEvent.type(screen.getByLabelText('Recipient email'), 'friend@example.com')
    await userEvent.click(screen.getByRole('button', { name: 'Send transfer' }))
    await userEvent.click(await screen.findByRole('button', { name: 'Done' }))
    expect(await screen.findByText(/Transfer pending/)).toBeInTheDocument()
  })
})

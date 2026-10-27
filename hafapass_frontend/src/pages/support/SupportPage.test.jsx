import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import SupportPage from './SupportPage'
import { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import { publishAccountRole } from '../../utils/workspace'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn() } }))

let uninstallAuth = null

describe('support record lookup', () => {
  beforeEach(() => vi.clearAllMocks())
  afterEach(() => {
    publishAccountRole(null, null)
    uninstallAuth?.()
    uninstallAuth = null
  })

  it('shows order, ticket, and event API matches and resends the matched ticket’s original order', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.includes('/search') ? {
      orders: [{ id: 922, reference: 'HP-922', event_title: 'Door Event', status: 'completed', buyer_name: 'Buyer', buyer_email: 'buyer@example.invalid', ticket_count: 1 }],
      tickets: [{ id: 501, order_id: 923, order_reference: 'HP-923', event_title: 'Ticket Event', attendee_name: 'Attendee', attendee_email: 'attendee@example.invalid', ticket_type: 'General', status: 'issued' }],
      events: [{ id: 37, title: 'Published Event', organization_name: 'Organizer', status: 'published', slug: 'published-event' }],
    } : { deliveries: [] } }))
    apiClient.post.mockResolvedValue({ data: {} })
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    const user = userEvent.setup()
    await user.type(screen.getByLabelText('Order, ticket, attendee, or event lookup'), 'Guest')
    await user.click(screen.getByRole('button', { name: 'Search' }))
    expect(await screen.findByText('HP-T501 · Order HP-923')).toBeInTheDocument()
    expect(screen.getByText('Published Event')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open event page' })).toHaveAttribute('href', '/events/published-event')
    await user.click(within(screen.getByText('HP-T501 · Order HP-923').closest('article')).getByRole('button', { name: 'Resend order tickets' }))
    expect(apiClient.post).toHaveBeenCalledWith('/support/message_deliveries/orders/923/fulfill', {}, expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(await screen.findByText("The order's ticket email was queued.")).toBeVisible()
  })

  it('shows order results only after a successful search, including empty order matches', async () => {
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url.includes('/search')
      ? { orders: [], tickets: [], events: [{ id: 1, title: 'Matched event', organization_name: 'Organizer', status: 'draft' }] }
      : { deliveries: [] } }))
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    await screen.findByText('No recent message deliveries.')
    expect(screen.queryByRole('heading', { name: 'Order results' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Search' })).toBeDisabled()
    await userEvent.type(screen.getByLabelText('Order, ticket, attendee, or event lookup'), 'event')
    await userEvent.click(screen.getByRole('button', { name: 'Search' }))
    expect(await screen.findByText('No orders match this search.')).toBeVisible()
    expect(screen.getByText('Matched event')).toBeVisible()
  })

  it('enables Retry delivery for an unsent failed message and reports queueing', async () => {
    apiClient.get.mockResolvedValue({ data: { deliveries: [{ id: 42, template: 'order_confirmation', recipient: 'buyer@example.invalid', status: 'failed', provider_id: null, attempts: 1 }] } })
    apiClient.post.mockResolvedValue({ data: {} })
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    const retry = await screen.findByRole('button', { name: 'Retry delivery' })
    expect(retry).toBeEnabled()
    await userEvent.click(retry)
    expect(apiClient.post).toHaveBeenCalledWith('/support/message_deliveries/42/resend', {}, expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(await screen.findByText('The original message was queued for another delivery attempt.')).toBeVisible()
  })

  it('offers retry only for failed messages not yet accepted by the provider', async () => {
    const delivery = { template: 'ticket_email', recipient: 'guest@example.invalid', attempts: 1 }
    apiClient.get.mockResolvedValue({ data: { deliveries: [
      { ...delivery, id: 1, status: 'delivered', provider_id: 'accepted' },
      { ...delivery, id: 2, status: 'queued', provider_id: null },
      { ...delivery, id: 3, status: 'failed', provider_id: 'accepted' },
      { ...delivery, id: 4, status: 'failed', provider_id: null },
    ] } })
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    await screen.findByText('#4')
    for (const id of [1, 2, 3]) expect(within(screen.getByText(new RegExp(`^#${id}(?: ·|$)`)).closest('tr')).queryByRole('button')).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Retry delivery' })).toHaveLength(1)
    expect(screen.getAllByRole('columnheader').map(header => header.textContent)).toEqual(['Message', 'Recipient', 'State', 'Attempts', 'Action'])
    for (const header of screen.getAllByRole('columnheader')) expect(header).toHaveAttribute('scope', 'col')
    expect(within(screen.getByText('#4').closest('tr')).getByRole('button', { name: 'Retry delivery' })).toBeEnabled()
  })

  it('offers a way back to the admin panel only to an admin of the current account', async () => {
    apiClient.get.mockResolvedValue({ data: { deliveries: [] } })
    uninstallAuth = setAuthTokenGetter(async () => 'token', { userId: 'admin-a', sessionId: 'session-a', ready: true })
    publishAccountRole(getApiAuthContext(), 'support')
    const view = render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Support console' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Back to admin panel' })).not.toBeInTheDocument()
    view.unmount()
    publishAccountRole(getApiAuthContext(), 'admin')
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    expect(await screen.findByRole('link', { name: 'Back to admin panel' })).toHaveAttribute('href', '/admin')
  })
})

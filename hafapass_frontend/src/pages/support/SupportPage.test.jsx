import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import SupportPage from './SupportPage'
import { getApiAuthContext, setAuthTokenGetter } from '../../api/client'
import { publishAccountRole } from '../../utils/workspace'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), post: vi.fn() } }))

describe('support record lookup', () => {
  beforeEach(() => vi.clearAllMocks())

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
    await user.click(screen.getByRole('button', { name: 'Resend order tickets' }))
    expect(apiClient.post).toHaveBeenCalledWith('/support/message_deliveries/orders/923/fulfill', {}, expect.objectContaining({ signal: expect.any(AbortSignal) }))
  })

  it('offers a way back to the admin panel only to an admin of the current account', async () => {
    apiClient.get.mockResolvedValue({ data: { deliveries: [] } })
    setAuthTokenGetter(async () => 'token', { userId: 'admin-a', sessionId: 'session-a', ready: true })
    publishAccountRole(getApiAuthContext(), 'support')
    const view = render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Support console' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Back to admin panel' })).not.toBeInTheDocument()
    view.unmount()
    publishAccountRole(getApiAuthContext(), 'admin')
    render(<MemoryRouter initialEntries={['/support']}><SupportPage /></MemoryRouter>)
    expect(await screen.findByRole('link', { name: 'Back to admin panel' })).toHaveAttribute('href', '/admin')
    publishAccountRole(null, null)
  })
})

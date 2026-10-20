import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminDisputesPage from './AdminDisputesPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const dispute = {
  id: 5, provider_dispute_id: 'dp_123', amount_cents: 5350, currency: 'usd', status: 'open', reason: 'fraudulent',
  opened_at: '2026-10-01T00:00:00Z', closed_at: null,
  order: { id: 42, buyer_name: 'Ana Cruz', buyer_email: 'ana@example.com', total_cents: 5350 },
  event: { id: 4, title: 'Night Market' }, organization: { id: 1, name: 'GuamTime Events' },
}
const respond = disputes => apiClient.get.mockResolvedValue({ data: { disputes, meta: { page: 1, total_pages: 1, total_count: disputes.length }, status_counts: { open: disputes.length, won: 0, lost: 0 } } })

describe('AdminDisputesPage', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lists disputes read-only with a link to the order', async () => {
    respond([dispute])
    render(<MemoryRouter initialEntries={['/admin/disputes']}><AdminDisputesPage /></MemoryRouter>)
    const link = await screen.findByRole('link', { name: 'Order #42' })
    expect(link).toHaveAttribute('href', '/admin/orders?search=%2342')
    expect(screen.getByText('Fraudulent')).toBeInTheDocument()
    expect(screen.getByText('$53.50')).toBeInTheDocument()
    expect(screen.getByText('GuamTime Events')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Open (1)' })).toBeInTheDocument()
  })

  it('filters by status and shows an empty state', async () => {
    const user = userEvent.setup()
    respond([])
    render(<MemoryRouter initialEntries={['/admin/disputes']}><AdminDisputesPage /></MemoryRouter>)
    expect(await screen.findByText('No disputes recorded.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /^Lost/ }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/disputes', expect.objectContaining({ params: { status: 'lost', page: 1 } })))
    expect(await screen.findByText('No disputes match these filters.')).toBeInTheDocument()
  })

  it('offers a retry when the list cannot load', async () => {
    apiClient.get.mockRejectedValue({ response: { status: 500 } })
    render(<MemoryRouter initialEntries={['/admin/disputes']}><AdminDisputesPage /></MemoryRouter>)
    expect(await screen.findByRole('alert')).toHaveTextContent('could not be loaded')
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument()
  })
})

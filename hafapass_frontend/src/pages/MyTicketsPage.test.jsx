import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import MyTicketsPage from './MyTicketsPage'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
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
    apiClient.post.mockResolvedValue({ data: {} })
    renderPage()
    await screen.findByRole('button', { name: 'Retry guest purchase recovery' })
    expect(screen.getByText('Island workshop')).toBeInTheDocument()
  })
})

import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import MyTicketsPage from './MyTicketsPage'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
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
    apiClient.post.mockResolvedValue({ data: {} })
    renderPage()
    await screen.findByRole('button', { name: 'Retry guest purchase recovery' })
    expect(screen.getByText('Island workshop')).toBeInTheDocument()
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

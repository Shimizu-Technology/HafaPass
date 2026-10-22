import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import { AxiosError } from 'axios'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../api/client'
import MyTicketsPage from './MyTicketsPage'

// Uses the real api/client interceptors; only the HTTP adapter and Clerk are faked.
const clerk = vi.hoisted(() => ({ token: 'stale-token', getToken: null, signOut: null }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ getToken: clerk.getToken }), useClerk: () => ({ signOut: clerk.signOut }) }))
vi.mock('../monitoring', () => ({ Sentry: { captureException: vi.fn() } }))
vi.mock('../components/ui/ScrollReveal', () => ({
  StaggerContainer: ({ children }) => <div>{children}</div>,
  StaggerItem: ({ children }) => <div>{children}</div>,
}))

const ticket = {
  id: 3, order_id: 2, display_credential: 'synthetic-display-credential', status: 'issued',
  attendee_name: 'Synthetic Buyer', ticket_type: { name: 'General admission' },
  event: { id: 1, title: 'Island workshop', slug: 'island-workshop', timezone: 'Pacific/Guam', starts_at: '2030-01-01T08:00:00Z' },
}

describe('MyTicketsPage session refresh through the real API client', () => {
  let originalAdapter
  let uninstall
  let ticketRequests
  let orderRequests

  beforeEach(() => {
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', 'pk_test_fixture')
    clerk.token = 'stale-token'
    // Like Clerk, a skipCache call mints a new token that later cached reads return.
    clerk.getToken = vi.fn(async options => {
      if (options?.skipCache) clerk.token = 'fresh-token'
      return clerk.token
    })
    clerk.signOut = vi.fn()
    uninstall = setAuthTokenGetter(() => clerk.getToken(), { userId: 'user_1', sessionId: 'sess_1', ready: true })
    ticketRequests = []
    orderRequests = []
    originalAdapter = apiClient.defaults.adapter
    apiClient.defaults.adapter = async config => {
      const authorization = config.headers.Authorization
      if (config.url === '/me/tickets') {
        ticketRequests.push(authorization)
        if (authorization !== 'Bearer fresh-token') {
          const response = { status: 401, statusText: 'Unauthorized', data: { error: 'expired' }, headers: {}, config }
          throw new AxiosError('Unauthorized', 'ERR_BAD_REQUEST', config, null, response)
        }
        return { status: 200, statusText: 'OK', data: { tickets: [ticket] }, headers: {}, config }
      }
      if (config.url === '/me/orders') {
        orderRequests.push(authorization)
        if (authorization !== 'Bearer fresh-token') {
          const response = { status: 401, statusText: 'Unauthorized', data: { error: 'expired' }, headers: {}, config }
          throw new AxiosError('Unauthorized', 'ERR_BAD_REQUEST', config, null, response)
        }
        return { status: 200, statusText: 'OK', data: { orders: [], meta: {} }, headers: {}, config }
      }
      return { status: 200, statusText: 'OK', data: {}, headers: {}, config }
    }
  })

  afterEach(() => {
    apiClient.defaults.adapter = originalAdapter
    uninstall()
    vi.unstubAllEnvs()
  })

  it('sends the refreshed bearer token on the retried tickets request', async () => {
    render(<HelmetProvider><MemoryRouter initialEntries={['/my-tickets']}><MyTicketsPage /></MemoryRouter></HelmetProvider>)
    expect(await screen.findByText('Island workshop')).toBeInTheDocument()
    expect(clerk.getToken).toHaveBeenCalledWith({ skipCache: true })
    expect(ticketRequests.slice(0, 2)).toEqual(['Bearer stale-token', 'Bearer fresh-token'])
    expect(clerk.signOut).not.toHaveBeenCalled()
  })

  it('refreshes and retries the orders request after a 401', async () => {
    render(<HelmetProvider><MemoryRouter initialEntries={['/my-tickets']}><MyTicketsPage /></MemoryRouter></HelmetProvider>)
    await screen.findByText('Island workshop')
    clerk.token = 'stale-token'
    await userEvent.click(screen.getByRole('tab', { name: 'Orders' }))
    await waitFor(() => expect(orderRequests.slice(0, 2)).toEqual(['Bearer stale-token', 'Bearer fresh-token']))
    expect(await screen.findByText('No orders yet')).toBeInTheDocument()
    expect(screen.queryByText('We couldn’t load your orders. Try again.')).not.toBeInTheDocument()
  })
})

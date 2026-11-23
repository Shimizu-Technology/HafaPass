import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router-dom'
import TicketPage from './TicketPage'
import Layout from '../components/Layout'
import api from '../api/client'

vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/Navbar', () => ({ default: () => null }))
vi.mock('../components/Footer', () => ({ default: () => null, WorkspaceFooter: () => null }))
vi.mock('../components/EnvironmentBanner', () => ({ default: () => null }))

const event = { title: 'Alumni night', status: 'published', starts_at: '2099-01-01T08:00:00Z', timezone: 'Pacific/Guam', venue_name: 'QA Gym' }
const ticket = credential => ({ id: Number(credential.slice(-1)), status: 'issued', admission_allowed: true, scan_credential: `scan-${credential}`,
  wallet_availability: { apple: false, google: false }, event, ticket_type: { name: credential === 'cred-3' ? 'Free Alumni' : 'Adult' } })
const order = { id: 9, tickets: [
  { id: 1, display_credential: 'cred-1', attendee_name: 'Avery Lindqvist', ticket_type: { name: 'Adult' } },
  { id: 2, display_credential: 'cred-2', attendee_name: 'Bram Okafor', ticket_type: { name: 'Adult' } },
  { id: 3, display_credential: 'cred-3', attendee_name: 'Calla Yorke', ticket_type: { name: 'Free Alumni' } },
  { id: 4, display_credential: null, attendee_name: 'Transferred away', ticket_type: { name: 'Adult' } },
] }
function Back() { const navigate = useNavigate(); return <button type="button" onClick={() => navigate(-1)}>Browser back</button> }
const show = path => render(<MemoryRouter initialEntries={[path]}><Back /><Routes><Route path="/tickets/:credential" element={<TicketPage />} /></Routes></MemoryRouter>)
const orderCalls = () => api.get.mock.calls.filter(([url]) => url === '/orders/9')

describe('group order ticket switcher', () => {
  beforeEach(() => {
    api.get.mockReset().mockImplementation(url => url === '/orders/9'
      ? Promise.resolve({ data: order })
      : Promise.resolve({ data: ticket(decodeURIComponent(url.split('/').pop())) }))
  })
  afterEach(() => vi.unstubAllGlobals())

  it('shows one ticket at a time with who it is for, and steps through the order', async () => {
    show('/tickets/cred-1?order=9')
    const switcher = await screen.findByRole('navigation', { name: 'Tickets in this order' })
    expect(switcher).toHaveTextContent('Ticket 1 of 3 — Avery Lindqvist')
    expect(within(switcher).getByRole('button', { name: 'Previous ticket' })).toBeDisabled()
    const next = within(switcher).getByRole('link', { name: 'Next ticket' })
    expect(next).toHaveAttribute('href', '/tickets/cred-2?order=9')
    expect(next).toHaveClass('min-h-12', 'min-w-12')
    // Ticket type and attendee read at arm's length under the QR.
    expect(screen.getByText('Adult')).toHaveClass('text-2xl')
    expect(screen.getByText('Avery Lindqvist')).toHaveClass('text-xl')
    expect(screen.getByText('Tip: turn your screen brightness up at the door.')).toBeInTheDocument()

    await userEvent.setup().click(next)
    expect(await screen.findByText('Ticket 2 of 3 — Bram Okafor')).toBeInTheDocument()
    await userEvent.setup().click(screen.getByRole('link', { name: 'Next ticket' }))
    expect(await screen.findByText('Ticket 3 of 3 — Calla Yorke')).toBeInTheDocument()
    expect(screen.getByText('Free Alumni')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Next ticket' })).toBeDisabled()
    expect(screen.getByRole('link', { name: 'Previous ticket' })).toHaveAttribute('href', '/tickets/cred-2?order=9')
    expect(screen.getAllByRole('img', { name: 'Ticket entry QR code' })).toHaveLength(1)
  })

  it('shows a single ticket alone when the order has one ticket or cannot load', async () => {
    api.get.mockImplementation(url => url === '/orders/9' ? Promise.reject(new Error('offline')) : Promise.resolve({ data: ticket('cred-1') }))
    show('/tickets/cred-1?order=9')
    expect(await screen.findByRole('img', { name: 'Ticket entry QR code' })).toBeInTheDocument()
    expect(screen.queryByRole('navigation', { name: 'Tickets in this order' })).not.toBeInTheDocument()
  })

  it('does not look up an order the ticket was not opened from', async () => {
    show('/tickets/cred-1')
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    expect(api.get.mock.calls.map(([url]) => url)).toEqual(['/tickets/cred-1'])
  })

  it('keeps the order list while paging, even when the connection drops after the first load', async () => {
    let orderLoads = 0
    api.get.mockImplementation(url => {
      if (url !== '/orders/9') return Promise.resolve({ data: ticket(decodeURIComponent(url.split('/').pop())) })
      orderLoads += 1
      return orderLoads === 1 ? Promise.resolve({ data: order }) : Promise.reject(new Error('weak signal'))
    })
    show('/tickets/cred-1?order=9')
    const user = userEvent.setup()
    await user.click(await screen.findByRole('link', { name: 'Next ticket' }))
    expect(await screen.findByText('Ticket 2 of 3 — Bram Okafor')).toBeInTheDocument()
    await user.click(screen.getByRole('link', { name: 'Next ticket' }))
    expect(await screen.findByText('Ticket 3 of 3 — Calla Yorke')).toBeInTheDocument()
    expect(orderCalls()).toHaveLength(1)
    // Each ticket still fetches its own QR.
    expect(api.get.mock.calls.map(([url]) => url).filter(url => url.startsWith('/tickets/'))).toEqual(['/tickets/cred-1', '/tickets/cred-2', '/tickets/cred-3'])
  })

  it('keeps keyboard focus on the switcher after paging and records each ticket in history', async () => {
    show('/tickets/cred-2?order=9')
    const user = userEvent.setup()
    await user.click(await screen.findByRole('link', { name: 'Next ticket' }))
    await screen.findByText('Ticket 3 of 3 — Calla Yorke')
    // Next is now disabled at the end, so focus lands on Previous rather than the page heading.
    expect(screen.getByRole('link', { name: 'Previous ticket' })).toHaveFocus()
    await user.click(screen.getByRole('link', { name: 'Previous ticket' }))
    await screen.findByText('Ticket 2 of 3 — Bram Okafor')
    expect(screen.getByRole('link', { name: 'Previous ticket' })).toHaveFocus()
    await user.click(screen.getByRole('button', { name: 'Browser back' }))
    expect(await screen.findByText('Ticket 3 of 3 — Calla Yorke')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Browser back' }))
    expect(await screen.findByText('Ticket 2 of 3 — Bram Okafor')).toBeInTheDocument()
  })

  it('shows a paged ticket in place without replaying the entrance', async () => {
    show('/tickets/cred-1?order=9')
    const user = userEvent.setup()
    await user.click(await screen.findByRole('link', { name: 'Next ticket' }))
    await screen.findByText('Ticket 2 of 3 — Bram Okafor')
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    const card = document.querySelector('.wallet-tilt').parentElement
    expect(card.style.transform || 'none').toBe('none')
  })

  describe('inside the app layout', () => {
    const deferred = () => { let settle; const promise = new Promise((resolve, reject) => { settle = { resolve, reject } }); return { promise, ...settle } }
    const showInLayout = path => render(<MemoryRouter initialEntries={[path]}><Routes>
      <Route element={<Layout />}><Route path="/tickets/:credential" element={<TicketPage />} /></Route>
    </Routes></MemoryRouter>)

    it('keeps the switcher, its focus and the scroll position through loading, failure and success', async () => {
      const pending = {}
      api.get.mockImplementation(url => {
        if (url === '/orders/9') return Promise.resolve({ data: order })
        const credential = decodeURIComponent(url.split('/').pop())
        if (credential === 'cred-1') return Promise.resolve({ data: ticket(credential) })
        pending[credential] = deferred()
        return pending[credential].promise
      })
      showInLayout('/tickets/cred-1?order=9')
      const user = userEvent.setup()
      const next = await screen.findByRole('link', { name: 'Next ticket' })
      await screen.findByRole('img', { name: 'Ticket entry QR code' })
      const scroll = vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
      const nav = screen.getByRole('navigation', { name: 'Tickets in this order' })

      await user.click(next)
      // Loading: the same switcher stays, focus stays on Next, and a calm placeholder holds the card's place.
      expect(screen.getByRole('navigation', { name: 'Tickets in this order' })).toBe(nav)
      expect(nav).toHaveTextContent('Ticket 2 of 3 — Bram Okafor')
      expect(screen.getByRole('link', { name: 'Next ticket' })).toHaveFocus()
      expect(screen.getByText('Loading this ticket…').closest('[role="status"]')).toBeInTheDocument()
      expect(screen.queryByRole('img', { name: 'Ticket entry QR code' })).not.toBeInTheDocument()

      // Failure: the error shows in the card's place and paging still works.
      await act(async () => pending['cred-2'].reject(new Error('weak signal')))
      expect(await screen.findByRole('alert')).toHaveTextContent("We couldn't load this ticket.")
      expect(screen.getByRole('navigation', { name: 'Tickets in this order' })).toBe(nav)
      expect(screen.getByRole('link', { name: 'Next ticket' })).toHaveFocus()

      await user.click(screen.getByRole('link', { name: 'Next ticket' }))
      // At the end Next is disabled, so focus moves to Previous, not to the page.
      expect(nav).toHaveTextContent('Ticket 3 of 3 — Calla Yorke')
      expect(screen.getByRole('link', { name: 'Previous ticket' })).toHaveFocus()
      await act(async () => pending['cred-3'].resolve({ data: ticket('cred-3') }))
      expect(await screen.findByRole('img', { name: 'Ticket entry QR code' })).toBeInTheDocument()
      expect(screen.getByRole('navigation', { name: 'Tickets in this order' })).toBe(nav)
      expect(screen.getByRole('link', { name: 'Previous ticket' })).toHaveFocus()
      expect(document.getElementById('main-content')).not.toHaveFocus()
      expect(scroll).not.toHaveBeenCalled()
      scroll.mockRestore()
    })

    it('still moves focus and scroll for an ordinary route change', async () => {
      const scroll = vi.spyOn(window, 'scrollTo').mockImplementation(() => {})
      function Leave() { const navigate = useNavigate(); return <button type="button" onClick={() => navigate('/tickets/cred-3?order=9')}>Open another ticket</button> }
      render(<MemoryRouter initialEntries={['/tickets/cred-1?order=9']}><Leave /><Routes>
        <Route element={<Layout />}><Route path="/tickets/:credential" element={<TicketPage />} /></Route>
      </Routes></MemoryRouter>)
      await screen.findByRole('img', { name: 'Ticket entry QR code' })
      await userEvent.setup().click(screen.getByRole('button', { name: 'Open another ticket' }))
      expect(scroll).toHaveBeenCalled()
      scroll.mockRestore()
    })
  })
})


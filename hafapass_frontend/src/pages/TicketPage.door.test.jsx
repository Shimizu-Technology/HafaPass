import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import TicketPage from './TicketPage'
import api from '../api/client'

vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))

const ticket = { id: 3, status: 'issued', admission_allowed: true, scan_credential: 'synthetic-scan',
  wallet_availability: { apple: true, google: true },
  event: { title: 'Door ticket', status: 'published', starts_at: '2030-01-01T08:00:00Z', doors_open_at: '2030-01-01T07:30:00Z',
    timezone: 'Pacific/Guam', venue_name: 'QA Venue', venue_address: '1 Marine Corps Dr' },
  ticket_type: { name: 'Admission' } }
const showTicket = () => render(<MemoryRouter initialEntries={['/tickets/display?order=2']}><Routes><Route path="/tickets/:credential" element={<TicketPage />} /></Routes></MemoryRouter>)
const iPhone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1'
const android = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36'

describe('ticket at the door', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })
  afterEach(() => vi.restoreAllMocks())

  it('explains offline loading on the dark ticket background and points to the wallet', async () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    api.get.mockRejectedValue(new Error('Network Error'))
    showTicket()
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent("You're offline. Reconnect to show your ticket QR, or open it from Apple Wallet if you added it.")
    expect(alert.closest('.bg-brand-950')).not.toBeNull()
    expect(screen.getByRole('button', { name: 'Try again' })).toBeEnabled()
  })

  it('keeps the load error when the device is online', async () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
    api.get.mockRejectedValue(new Error('Server Error'))
    showTicket()
    expect(await screen.findByRole('alert')).toHaveTextContent("We couldn't load this ticket.")
  })

  it('renders a large QR that shrinks on narrow screens and readable details', async () => {
    api.get.mockResolvedValue({ data: ticket })
    showTicket()
    const qr = await screen.findByRole('img', { name: 'Ticket entry QR code' })
    expect(qr).toHaveAttribute('width', '280')
    expect(qr).toHaveClass('w-full', 'max-w-[17.5rem]', 'h-auto')
    expect(screen.getByText('1 Marine Corps Dr')).toHaveClass('text-sm')
    expect(screen.getByText(/Doors open/)).toHaveClass('text-sm')
  })

  it.each([
    [iPhone, ['Apple Wallet']],
    [android, ['Google Wallet']],
  ])('shows only the wallet this device can use (%s)', async (userAgent, labels) => {
    vi.spyOn(navigator, 'userAgent', 'get').mockReturnValue(userAgent)
    api.get.mockResolvedValue({ data: ticket })
    showTicket()
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    const buttons = screen.getAllByRole('button', { name: /Wallet/ })
    expect(buttons.map(button => button.textContent)).toEqual(labels)
    for (const button of buttons) expect(button).toHaveClass('min-h-11')
  })

  it('keeps both wallets when the device is unknown and none when wallets are off', async () => {
    api.get.mockResolvedValue({ data: ticket })
    const view = showTicket()
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    expect(screen.getByRole('button', { name: 'Apple Wallet' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Google Wallet' })).toBeInTheDocument()
    view.unmount()
    api.get.mockResolvedValue({ data: { ...ticket, wallet_availability: { apple: false, google: false } } })
    showTicket()
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    expect(screen.queryByRole('button', { name: /Wallet/ })).not.toBeInTheDocument()
  })
})

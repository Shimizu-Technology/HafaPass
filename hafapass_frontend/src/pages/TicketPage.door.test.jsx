import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen } from '@testing-library/react'
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
const mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
const windows = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
// jsdom has no navigator.maxTouchPoints; iPadOS detection reads it.
const setTouchPoints = value => Object.defineProperty(navigator, 'maxTouchPoints', { configurable: true, get: () => value })
const offlineMessage = "You're offline. Reconnect to show your ticket QR, or open it from your phone's wallet app if you added it."

describe('ticket at the door', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })
  afterEach(() => { vi.restoreAllMocks(); delete navigator.maxTouchPoints })

  it('explains offline loading on the dark ticket background and points to the wallet', async () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    api.get.mockRejectedValue(new Error('Network Error'))
    showTicket()
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent(offlineMessage)
    expect(alert).not.toHaveTextContent('Apple Wallet')
    expect(alert.closest('.bg-brand-950')).not.toBeNull()
    expect(screen.getByRole('button', { name: 'Try again' })).toBeEnabled()
  })

  it('switches between the offline explanation and the load error as connectivity changes', async () => {
    const onLine = vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(true)
    api.get.mockRejectedValue(new Error('Server Error'))
    showTicket()
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent("We couldn't load this ticket.")
    onLine.mockReturnValue(false)
    act(() => { window.dispatchEvent(new Event('offline')) })
    expect(screen.getByRole('alert')).toHaveTextContent(offlineMessage)
    onLine.mockReturnValue(true)
    act(() => { window.dispatchEvent(new Event('online')) })
    expect(screen.getByRole('alert')).toHaveTextContent("We couldn't load this ticket.")
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
    [mac, ['Apple Wallet', 'Google Wallet']],
    [windows, ['Apple Wallet', 'Google Wallet']],
  ])('shows only the wallets this device can use (%s)', async (userAgent, labels) => {
    vi.spyOn(navigator, 'userAgent', 'get').mockReturnValue(userAgent)
    setTouchPoints(userAgent === iPhone || userAgent === android ? 5 : 0)
    api.get.mockResolvedValue({ data: ticket })
    showTicket()
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    const buttons = screen.getAllByRole('button', { name: /Wallet/ })
    expect(buttons.map(button => button.textContent)).toEqual(labels)
    for (const button of buttons) expect(button).toHaveClass('min-h-11')
  })

  it('treats a touch-screen Mac user agent as iPadOS', async () => {
    vi.spyOn(navigator, 'userAgent', 'get').mockReturnValue(mac)
    setTouchPoints(5)
    api.get.mockResolvedValue({ data: ticket })
    showTicket()
    await screen.findByRole('img', { name: 'Ticket entry QR code' })
    expect(screen.getAllByRole('button', { name: /Wallet/ }).map(button => button.textContent)).toEqual(['Apple Wallet'])
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

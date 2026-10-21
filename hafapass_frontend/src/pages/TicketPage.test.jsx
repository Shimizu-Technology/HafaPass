import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import TicketPage from './TicketPage'
import api from '../api/client'

vi.mock('../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn() } }))
const motionPreference = vi.hoisted(() => ({ reduced: false }))
vi.mock('framer-motion', async original => ({ ...await original(), useReducedMotion: () => motionPreference.reduced }))

vi.mock('../components/QRCode', () => ({ default: () => <div>Entry QR</div> }))

describe('ticket download recovery', () => {
  beforeEach(() => { vi.clearAllMocks(); motionPreference.reduced = false; window.sessionStorage.clear() })

  it('uses the public focal point for an approved ticket cover', async () => {
    api.get.mockResolvedValue({ data: {
      id: 3, status: 'issued', admission_allowed: true, scan_credential: 'synthetic-scan', wallet: {},
      event: { title: 'Rehearsal', status: 'published', starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam',
        cover_image_url: 'https://storage.invalid/uploads/cover.webp', image_asset_host: 'storage.invalid',
        page_customization: { focal_point: { x: 20, y: 80 } } },
      ticket_type: { name: 'Admission' },
    } })
    render(<MemoryRouter initialEntries={['/tickets/synthetic-display']}><Routes>
      <Route path="/tickets/:credential" element={<TicketPage />} />
    </Routes></MemoryRouter>)
    expect(await screen.findByRole('img', { name: 'Rehearsal' })).toHaveStyle({ objectPosition: '20% 80%' })
  })

  it.each([404, 503])('orients a failed ticket load with a heading and alert (HTTP %s)', async status => {
    api.get.mockRejectedValue({ response: { status } })
    render(<MemoryRouter initialEntries={['/tickets/synthetic-display?order=2']}><Routes>
      <Route path="/tickets/:credential" element={<TicketPage />} />
    </Routes></MemoryRouter>)
    expect(await screen.findByRole('heading', { name: 'Ticket unavailable', level: 1 })).toBeVisible()
    expect(screen.getByRole('alert')).toHaveTextContent(status === 404 ? 'Ticket not found' : 'Failed to load ticket')
    expect(screen.queryByText('Entry QR')).not.toBeInTheDocument()
  })

  for (const reason of ['Ticket access is paused while its refund is pending', 'Payment dispute under review']) {
    it(`shows access paused rather than valid for an issued ticket: ${reason}`, async () => {
      api.get.mockResolvedValue({ data: {
        id: 3, status: 'issued', admission_allowed: false, admission_block_reason: reason, scan_credential: null,
        event: { title: 'Paused ticket', status: 'published', starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam' },
        ticket_type: { name: 'Admission' },
      } })
      render(<MemoryRouter initialEntries={['/tickets/synthetic-display?order=2']}><Routes>
        <Route path="/tickets/:credential" element={<TicketPage />} />
      </Routes></MemoryRouter>)
      expect(await screen.findByText('Access paused')).toBeInTheDocument()
      expect(screen.queryByText('Valid', { exact: true })).not.toBeInTheDocument()
      expect(screen.getByText(reason, { exact: false })).toBeInTheDocument()
      expect(screen.queryByText('Entry QR')).not.toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Download PDF' })).toBeDisabled()
    })
  }

  it('explains unsupported PDF text from the blob response and keeps the browser ticket usable', async () => {
    const ticket = {
      id: 3, status: 'issued', admission_allowed: true, scan_credential: 'synthetic-scan', wallet: {},
      event: { title: '日本語 rehearsal', status: 'published', starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam', venue_name: 'QA Venue' },
      ticket_type: { name: 'Admission' },
    }
    api.get.mockImplementation(url => url.endsWith('/download')
      ? Promise.reject({ response: { status: 422, data: { text: async () => JSON.stringify({ error_code: 'unsupported_pdf_text' }) } } })
      : Promise.resolve({ data: ticket }))
    render(<MemoryRouter initialEntries={['/tickets/synthetic-display?order=2']}><Routes>
      <Route path="/tickets/:credential" element={<TicketPage />} />
    </Routes></MemoryRouter>)
    const download = await screen.findByRole('button', { name: 'Download PDF' })
    // Door credentials must be visible immediately rather than waiting for an animation.
    expect(screen.getByText('Entry QR').parentElement.parentElement).toHaveStyle({ opacity: '1' })
    await userEvent.setup().click(download)
    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent('Use this browser ticket or contact the organizer')
    expect(alert).not.toHaveTextContent('Check your connection')
    expect(screen.getByText('Entry QR')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Download PDF' })).toBeEnabled()
  })

  it('keeps the usable ticket visible and allows retry after a lost PDF response', async () => {
    const ticket = {
      id: 3, status: 'issued', admission_allowed: true, scan_credential: 'synthetic-scan', wallet: {},
      event: { title: 'Rehearsal', status: 'published', starts_at: '2026-11-20T07:00:00Z', timezone: 'Pacific/Guam', venue_name: 'QA Venue' },
      ticket_type: { name: 'Admission' },
    }
    api.get.mockImplementation(url => url.endsWith('/download')
      ? Promise.reject(new Error('connection lost')) : Promise.resolve({ data: ticket }))
    render(<MemoryRouter initialEntries={['/tickets/synthetic-display?order=2']}><Routes>
      <Route path="/tickets/:credential" element={<TicketPage />} />
    </Routes></MemoryRouter>)
    const user = userEvent.setup()
    const download = await screen.findByRole('button', { name: 'Download PDF' })
    await user.click(download)
    expect(await screen.findByRole('alert')).toHaveTextContent('Your ticket is still available here')
    expect(screen.getByText('Entry QR')).toBeInTheDocument()
    expect(download).toBeEnabled()
    await user.click(download)
    expect(api.get.mock.calls.filter(([url]) => url.endsWith('/download'))).toHaveLength(2)
  })
})

it('keeps admission and expandable device instructions immediately usable with reduced motion', async () => {
  motionPreference.reduced = true
  const userAgent = vi.spyOn(navigator, 'userAgent', 'get').mockReturnValue('Synthetic Android device')
  api.get.mockResolvedValue({ data: { id: 3, status: 'issued', admission_allowed: true, scan_credential: 'synthetic-scan', wallet: {}, event: { title: 'Reduced-motion rehearsal', status: 'published', starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam' }, ticket_type: { name: 'Admission' } } })
  try {
    render(<MemoryRouter initialEntries={['/tickets/synthetic-display?order=2']}><Routes><Route path="/tickets/:credential" element={<TicketPage />} /></Routes></MemoryRouter>)
    expect(await screen.findByText('Entry QR')).toBeVisible()
    expect(screen.getByRole('button', { name: 'Download PDF' })).toBeEnabled()
    const instructions = screen.getByRole('button', { name: 'Add to Home Screen' })
    await userEvent.click(instructions)
    expect(screen.getByText('Android Instructions:')).toBeVisible()
    expect(instructions).toHaveAttribute('aria-expanded', 'true')
    expect(document.querySelector('.animate-pulse')).toHaveClass('motion-reduce:animate-none')
    await userEvent.click(instructions)
    expect(instructions).toHaveAttribute('aria-expanded', 'false')
    expect(screen.getByText('Entry QR')).toBeVisible()
  } finally { userAgent.mockRestore(); motionPreference.reduced = false }
})

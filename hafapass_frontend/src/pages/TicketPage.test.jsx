import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import TicketPage from './TicketPage'
import api from '../api/client'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('../components/QRCode', () => ({ default: () => <div>Entry QR</div> }))

describe('ticket download recovery', () => {
  beforeEach(() => { vi.clearAllMocks(); window.sessionStorage.clear() })

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

import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import BoxOfficePage from './BoxOfficePage'

vi.mock('../../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/SeatSelector', () => ({ default: () => null }))
vi.mock('../../components/QRCode', () => ({ default: () => null }))

function mountBoxOffice() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/box-office']}><Routes><Route path="/dashboard/events/:id/box-office" element={<BoxOfficePage />} /></Routes></MemoryRouter>) }

describe('uncertain box office sale', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    window.sessionStorage.clear()
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: { door_card: true } } : url === '/organizer/card_present_account' ? { payment_ready: true } : url.endsWith('/summary') ? {} : { id: 37, title: 'Door Event', ticket_types: [{ id: 7, name: 'Admission', price_cents: 500, quantity_available: 10, quantity_sold: 0 }] } }))
  })

  it('retries the original operation and immutable payload after losing a response and reloading', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('response lost'))
    const first = mountBoxOffice()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Add Admission' }))
    await user.click(screen.getByRole('button', { name: 'Card at Door' }))
    await user.type(screen.getByLabelText('Buyer name'), 'Door Buyer')
    await user.click(screen.getByRole('button', { name: /Process Sale/ }))
    await screen.findByText('Do not charge the card again')
    const [url, payload, options] = apiClient.post.mock.calls[0]
    expect(options.headers['Idempotency-Key']).toBeTruthy()
    expect(screen.getByLabelText('Buyer name')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Cash' })).toBeDisabled()
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: { id: 922, buyer_name: 'Door Buyer', total_cents: 500, tickets: [] } })
    mountBoxOffice()
    await user.click(await screen.findByRole('button', { name: /Retry saved sale/ }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledTimes(2))
    expect(apiClient.post.mock.calls[1]).toEqual([url, payload, options])
    expect(await screen.findByText('Sale Complete!')).toBeInTheDocument()
    expect(window.sessionStorage.getItem('hafapass:pending-box-office:local-preview:37')).toBeNull()
  })
})

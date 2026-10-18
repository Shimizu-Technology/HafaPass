import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../../api/client'
import BoxOfficePage from './BoxOfficePage'

vi.mock('../../api/client', async importOriginal => ({ ...(await importOriginal()), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../components/SeatSelector', () => ({ default: () => null }))
vi.mock('../../components/QRCode', () => ({ default: () => null }))

function mountBoxOffice() { return render(<MemoryRouter initialEntries={['/dashboard/events/37/box-office']}><Routes><Route path="/dashboard/events/:id/box-office" element={<BoxOfficePage />} /></Routes></MemoryRouter>) }

// A retry keeps the operation fixed but receives its own cancellable transport.
const operation = ([url, payload, { signal: _signal, ...config }]) => [url, payload, config]

describe('uncertain box office sale', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    window.sessionStorage.clear()
    apiClient.get.mockImplementation(url => Promise.resolve({ data: url === '/config' ? { launch_capabilities: { door_card: true } } : url === '/organizer/card_present_account' ? { payment_ready: true } : url.endsWith('/summary') ? {} : { id: 37, organization_id: 1, permissions: { box_office: true }, title: 'Door Event', ticket_types: [{ id: 7, name: 'Admission', price_cents: 500, quantity_available: 10, quantity_sold: 0 }] } }))
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
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation([url, payload, options]))
    expect(await screen.findByText('Sale Complete!')).toBeInTheDocument()
    expect(window.sessionStorage.getItem('hafapass:pending-box-office:v2:local-preview:default:37')).toBeNull()
  })

  it('preserves a cash sale identity across a lost response and reload', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('cash response lost'))
    const first = mountBoxOffice()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Add Admission' }))
    await user.click(screen.getByRole('button', { name: /Process Sale/ }))
    await screen.findByText('A saved sale needs confirmation')
    expect(screen.getByText('Do not record another cash sale')).toBeInTheDocument()
    const original = apiClient.post.mock.calls[0]
    expect(original[1].payment_method).toBe('door_cash')
    first.unmount()
    apiClient.post.mockResolvedValueOnce({ data: { id: 922, buyer_name: 'Walk-in', total_cents: 500, tickets: [] } })
    mountBoxOffice()
    await user.click(await screen.findByRole('button', { name: /Retry saved sale/ }))
    await screen.findByText('Sale Complete!')
    expect(operation(apiClient.post.mock.calls[1])).toEqual(operation(original))
    expect(window.sessionStorage.getItem('hafapass:pending-box-office:v2:local-preview:default:37')).toBeNull()
  })

  it('retains the original card key and locks new sales when an initiated replay requires reconciliation', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('original response interrupted'))
    const first = mountBoxOffice()
    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Add Admission' }))
    await user.click(screen.getByRole('button', { name: 'Card at Door' }))
    await user.type(screen.getByLabelText('Buyer name'), 'Interrupted Buyer')
    await user.click(screen.getByRole('button', { name: /Process Sale/ }))
    await screen.findByText('Do not charge the card again')
    const original = apiClient.post.mock.calls[0]
    const storageKey = 'hafapass:pending-box-office:v2:local-preview:default:37'
    const saved = window.sessionStorage.getItem(storageKey)
    first.unmount()

    // Exact backend contract for a persisted initiated attempt's replay.
    apiClient.post.mockRejectedValue({ response: { status: 502, data: {
      error: 'Card payment requires reconciliation before another submission',
      payment_status: 'result_unknown', reconciliation_required: true, order_id: 922,
    } } })
    const second = mountBoxOffice()
    await user.click(await screen.findByRole('button', { name: /Retry saved sale/ }))
    await screen.findByText('Card payment requires reconciliation before another submission')
    expect(window.sessionStorage.getItem(storageKey)).toBe(saved)
    expect(screen.getByLabelText('Buyer name')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Cash' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Add Admission' })).toBeDisabled()
    expect(screen.queryByRole('button', { name: /Process Sale/ })).not.toBeInTheDocument()
    second.unmount()

    mountBoxOffice()
    await user.click(await screen.findByRole('button', { name: /Retry saved sale/ }))
    await screen.findByText('Card payment requires reconciliation before another submission')
    expect(apiClient.post).toHaveBeenCalledTimes(3)
    for (const call of apiClient.post.mock.calls) expect(operation(call)).toEqual(operation(original))
    expect(window.sessionStorage.getItem(storageKey)).toBe(saved)
    expect(screen.queryByText('Sale Complete!')).not.toBeInTheDocument()
  })
})

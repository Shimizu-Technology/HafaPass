import { act, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import OrderConfirmationPage from './OrderConfirmationPage'
import { saveOrderAccess } from '../utils/orderAccess'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../hooks/useLaunchCapabilities', () => ({ default: () => ({}) }))
vi.mock('../components/SEO', () => ({ default: () => null }))
const baseOrder = {
  id: 42, reference: 'HP-42', status: 'completed', buyer_email: 'synthetic@example.invalid', total_cents: 0, order_items: [],
  tickets: [{ id: 1, status: 'issued', refundable_cents: 0, display_credential: 'display', ticket_type: { id: 1, name: 'Admission' } }],
  event: { slug: 'synthetic-event', status: 'published', title: 'Synthetic event', starts_at: '2026-10-20T08:00:00Z', timezone: 'Pacific/Guam' },
}
const withDelivery = (status, simulated = false) => ({ ...baseOrder, confirmation_delivery: { status, simulated } })
const requests = () => apiClient.get.mock.calls.filter(([path]) => path.startsWith('/orders/'))
async function mount(extra = null) {
  const view = render(<MemoryRouter initialEntries={['/orders/42/confirmation']}><Routes><Route path='/orders/:id/confirmation' element={<OrderConfirmationPage />} /></Routes>{extra}</MemoryRouter>)
  await act(async () => {})
  return view
}
async function advance(milliseconds) { await act(async () => { await vi.advanceTimersByTimeAsync(milliseconds) }) }
let visibility
let online
beforeEach(() => {
  vi.clearAllMocks()
  vi.useFakeTimers()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  vi.stubEnv('VITE_SUPPORT_EMAIL', 'operator@example.test')
  window.localStorage.clear()
  window.sessionStorage.clear()
  saveOrderAccess(42, 'fixture-order-access')
  visibility = 'visible'
  online = true
  vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility)
  vi.spyOn(navigator, 'onLine', 'get').mockImplementation(() => online)
})
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllEnvs() })

describe('completed-order email status updates', () => {
  it('updates a queued email to delivered without another ticket action and stops after delivery', async () => {
    apiClient.get.mockResolvedValueOnce({ data: withDelivery('queued') }).mockResolvedValue({ data: withDelivery('delivered') })
    await mount()
    expect(screen.getByText(/queued for delivery/)).toBeInTheDocument()
    await advance(10_000)
    expect(screen.getByText('Your ticket email was delivered.')).toBeInTheDocument()
    expect(requests()).toHaveLength(2)
    expect(requests()[1][1]).toEqual({ headers: { 'X-Guest-Order-Token': 'fixture-order-access' }, timeout: 10_000 })
    await advance(120_000)
    expect(requests()).toHaveLength(2)
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it('caps sent-email updates at six sequential checks and then offers manual status recovery', async () => {
    apiClient.get.mockImplementation(() => Promise.resolve({ data: withDelivery('sent') }))
    await mount()
    await advance(60_000)
    expect(requests()).toHaveLength(7)
    expect(screen.getByText(/Automatic email updates have paused/)).toBeInTheDocument()
    await advance(300_000)
    expect(requests()).toHaveLength(7)
    expect(screen.getByRole('button', { name: 'Refresh status' })).toBeEnabled()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it.each(['delivered', 'failed', 'bounced', 'complained', 'suppressed', 'cancelled', 'delayed'])('does not automatically refresh the %s delivery state', async status => {
    apiClient.get.mockResolvedValue({ data: withDelivery(status) })
    await mount()
    await advance(120_000)
    expect(requests()).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Refresh status' })).toBeEnabled()
  })
  it('does not poll simulated delivery or present it as a real delivered email', async () => {
    apiClient.get.mockResolvedValue({ data: withDelivery('sent', true) })
    await mount()
    await advance(120_000)
    expect(requests()).toHaveLength(1)
    expect(screen.queryByRole('button', { name: 'Refresh status' })).not.toBeInTheDocument()
    expect(screen.getByText(/Email is simulated/)).toBeInTheDocument()
  })
  it('pauses while hidden or offline and resumes only while visible and online', async () => {
    apiClient.get.mockImplementation(() => Promise.resolve({ data: withDelivery('queued') }))
    await mount()
    visibility = 'hidden'
    fireEvent(document, new Event('visibilitychange'))
    await advance(10_000)
    expect(requests()).toHaveLength(1)
    visibility = 'visible'
    online = false
    fireEvent(document, new Event('visibilitychange'))
    await advance(10_000)
    expect(requests()).toHaveLength(1)
    online = true
    fireEvent(window, new Event('online'))
    await advance(10_000)
    expect(requests()).toHaveLength(2)
  })
  it('retains tickets after an email-status error and performs only a read when manually refreshed', async () => {
    apiClient.get.mockResolvedValueOnce({ data: withDelivery('queued') }).mockRejectedValueOnce(new Error('connection lost')).mockResolvedValue({ data: withDelivery('delivered') })
    await mount()
    await advance(10_000)
    expect(screen.getByRole('alert')).toHaveTextContent('Unable to refresh email status')
    expect(screen.getByText('Tickets (1)')).toBeInTheDocument()
    await advance(120_000)
    expect(requests()).toHaveLength(2)
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Refresh status' })) })
    expect(screen.getByText('Your ticket email was delivered.')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it('uses manual status refresh for a delayed email without attempting another send', async () => {
    apiClient.get.mockResolvedValueOnce({ data: withDelivery('delayed') }).mockResolvedValue({ data: withDelivery('delivered') })
    await mount()
    expect(screen.getByText(/ticket email is delayed/)).toBeInTheDocument()
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Refresh status' })) })
    expect(screen.getByText('Your ticket email was delivered.')).toBeInTheDocument()
    expect(requests()).toHaveLength(2)
    expect(apiClient.post).not.toHaveBeenCalled()
  })
  it('keeps an accepted resend distinct from a failed status lookup and never automatically resends', async () => {
    apiClient.get.mockResolvedValueOnce({ data: withDelivery('failed') }).mockRejectedValue(new Error('status unavailable'))
    apiClient.post.mockResolvedValue({ data: {} })
    await mount()
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Resend', exact: true })) })
    expect(screen.getByText('Your email request was saved. Check the delivery status above.')).toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent('Unable to refresh email status')
    expect(screen.getByText('Tickets (1)')).toBeInTheDocument()
    await advance(120_000)
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(requests()).toHaveLength(2)
  })
  it('does not issue an email status request offline or after losing the bound buyer', async () => {
    apiClient.get.mockResolvedValue({ data: withDelivery('queued') })
    await mount()
    online = false
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Refresh status' })) })
    expect(screen.getByRole('alert')).toHaveTextContent('Connect to the internet')
    online = true
    window.localStorage.setItem('hafapass_scanner_user_id', 'different-buyer')
    await advance(30_000)
    expect(requests()).toHaveLength(1)
  })
  it('does not overlap automatic reads while a status request is in flight', async () => {
    let finish
    apiClient.get.mockResolvedValueOnce({ data: withDelivery('queued') }).mockImplementation(() => new Promise(resolve => { finish = resolve }))
    await mount()
    await advance(10_000)
    await advance(20_000)
    expect(requests()).toHaveLength(2)
    expect(screen.getByRole('button', { name: 'Refreshing status…' })).toBeDisabled()
    await act(async () => { finish({ data: withDelivery('delivered') }) })
    expect(screen.getByText('Your ticket email was delivered.')).toBeInTheDocument()
  })
  it('discards an old-order status result after navigation and clears its update timer', async () => {
    let finish
    apiClient.get.mockImplementation(path => path === '/orders/43' ? Promise.resolve({ data: { ...withDelivery('delivered'), id: 43, reference: 'HP-43', event: { ...baseOrder.event, title: 'New order event' } } }) : requests().length === 1 ? Promise.resolve({ data: withDelivery('queued') }) : new Promise(resolve => { finish = resolve }))
    function NavigateOrder() { const navigate = useNavigate(); return <button onClick={() => navigate('/orders/43/confirmation')}>Open next order</button> }
    await mount(<NavigateOrder />)
    await advance(10_000)
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Open next order' })) })
    expect(screen.getByText('New order event')).toBeInTheDocument()
    await act(async () => { finish({ data: withDelivery('failed') }) })
    expect(screen.getByText('New order event')).toBeInTheDocument()
    expect(screen.queryByText(/delivery needs attention/)).not.toBeInTheDocument()
    const before = requests().length
    await advance(120_000)
    expect(requests()).toHaveLength(before)
  })
  it('preserves the bounded check budget across a long hidden pause', async () => {
    apiClient.get.mockImplementation(() => Promise.resolve({ data: withDelivery('sent') }))
    await mount()
    visibility = 'hidden'
    fireEvent(document, new Event('visibilitychange'))
    await advance(120_000)
    expect(requests()).toHaveLength(1)
    visibility = 'visible'
    fireEvent(document, new Event('visibilitychange'))
    await advance(60_000)
    expect(requests()).toHaveLength(7)
    await advance(120_000)
    expect(requests()).toHaveLength(7)
  })
  it('waits for an older status read before fetching the fresh saved resend outcome', async () => {
    let finishOlderRead
    let getCount = 0
    const sequence = []
    apiClient.get.mockImplementation(() => {
      getCount += 1
      sequence.push(`get${getCount}`)
      if (getCount === 2) return new Promise(resolve => { finishOlderRead = data => { sequence.push('older-read-finished'); resolve({ data }) } })
      return Promise.resolve({ data: withDelivery(getCount > 3 ? 'delivered' : 'queued') })
    })
    apiClient.post.mockImplementation(() => { sequence.push('resend-saved'); return Promise.resolve({ data: {} }) })
    await mount()
    await advance(10_000)
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Resend', exact: true })) })
    expect(requests()).toHaveLength(2)
    await act(async () => { finishOlderRead(withDelivery('delivered')) })
    expect(requests()).toHaveLength(3)
    expect(sequence).toEqual(['get1', 'get2', 'resend-saved', 'older-read-finished', 'get3'])
    expect(screen.getByText(/queued for delivery/)).toBeInTheDocument()
    await advance(10_000)
    expect(screen.getByText('Your ticket email was delivered.')).toBeInTheDocument()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

})

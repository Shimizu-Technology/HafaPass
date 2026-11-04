import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminOrderRefundDialog from './AdminOrderRefundDialog'

vi.mock('../../api/client', async importOriginal => ({
  ...await importOriginal(),
  default: { get: vi.fn(), post: vi.fn() },
}))

const order = { id: 42 }
const options = {
  order_id: 42, currency: 'usd', refundable_cents: 10500, event_paid_out: false, organization_name: 'Ambros',
  tickets: [
    { id: 1, ticket_type: 'General', attendee_name: 'Ana', refundable_cents: 5250, transferred: true },
    { id: 2, ticket_type: 'General', attendee_name: 'Ben', refundable_cents: 5250, transferred: false },
    { id: 3, ticket_type: 'General', attendee_name: 'Cy', refundable_cents: 0, transferred: false, unavailable_reason: 'Already scanned' },
  ],
}
const succeeded = { refund: { id: 9, status: 'succeeded', amount_cents: 10500 }, order: { id: 42 } }

function setup(data = options) {
  apiClient.get.mockResolvedValue({ data })
  const onRefunded = vi.fn()
  const onClose = vi.fn()
  render(<AdminOrderRefundDialog order={order} onClose={onClose} onRefunded={onRefunded} />)
  return { onRefunded, onClose, user: userEvent.setup() }
}

describe('AdminOrderRefundDialog', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.post.mockReset()
    window.sessionStorage.clear()
  })

  it('refunds everything left only after a note, with one saved request key', async () => {
    apiClient.post.mockResolvedValue({ data: succeeded })
    const { user, onRefunded } = setup()
    const pay = await screen.findByRole('button', { name: 'Refund $105.00' })
    await user.click(pay)
    expect(screen.getByRole('alert')).toHaveTextContent('Add a note')
    expect(apiClient.post).not.toHaveBeenCalled()

    await user.type(screen.getByLabelText('Note for the audit log'), 'Duplicate purchase')
    await user.click(pay)

    await waitFor(() => expect(onRefunded).toHaveBeenCalledWith(succeeded))
    const [path, body, config] = apiClient.post.mock.calls[0]
    expect(path).toBe('/admin/orders/42/refund')
    expect(body).toEqual({ note: 'Duplicate purchase' })
    expect(config.headers['Idempotency-Key']).toBeTruthy()
    expect(window.sessionStorage.getItem('hafapass_admin_refund:42')).toBeNull()
  })

  it('warns who pays once the event has been paid out', async () => {
    setup({ ...options, event_paid_out: true })
    expect(await screen.findByText('This event has already been paid out.')).toBeInTheDocument()
    expect(screen.getByText(/Ambros's balance becomes a negative balance they owe/)).toBeInTheDocument()
  })

  it('warns that refunding everything also cancels a transferred ticket', async () => {
    setup()
    expect(await screen.findByText(/also cancels a ticket transferred to someone else/)).toBeInTheDocument()
  })

  it('refunds selected tickets, blocks scanned ones and warns about the new holder', async () => {
    apiClient.post.mockResolvedValue({ data: succeeded })
    const { user } = setup()
    await user.click(await screen.findByRole('radio', { name: /Selected tickets/ }))
    await user.click(screen.getByRole('button', { name: 'Refund' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Choose at least one ticket')

    expect(screen.getByRole('checkbox', { name: /Cy/ })).toBeDisabled()
    await user.click(screen.getByRole('checkbox', { name: /Ana/ }))
    expect(screen.getByText(/current holder loses this ticket/)).toBeInTheDocument()
    await user.type(screen.getByLabelText('Note for the audit log'), 'Postponed; holder asked support')
    await user.click(screen.getByRole('button', { name: 'Refund $52.50' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalled())
    expect(apiClient.post.mock.calls[0][1]).toEqual({ note: 'Postponed; holder asked support', ticket_ids: [1] })
  })

  it.each([['abc', 'Enter an amount'], ['0', 'Enter an amount'], ['12.345', 'Enter an amount'], ['200', 'most you can refund is $105.00']])(
    'rejects the amount %s', async (value, message) => {
      const { user } = setup()
      await user.click(await screen.findByRole('radio', { name: /A set amount/ }))
      await user.type(screen.getByLabelText('Amount in dollars'), value)
      await user.type(screen.getByLabelText('Note for the audit log'), 'Goodwill')
      await user.click(screen.getByRole('button', { name: /^Refund/ }))
      expect(screen.getByRole('alert')).toHaveTextContent(message)
      expect(apiClient.post).not.toHaveBeenCalled()
    })

  it('sends a set amount in whole cents', async () => {
    apiClient.post.mockResolvedValue({ data: succeeded })
    const { user } = setup()
    await user.click(await screen.findByRole('radio', { name: /A set amount/ }))
    await user.type(screen.getByLabelText('Amount in dollars'), '19.99')
    await user.type(screen.getByLabelText('Note for the audit log'), 'Goodwill')
    await user.click(screen.getByRole('button', { name: 'Refund $19.99' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalled())
    expect(apiClient.post.mock.calls[0][1]).toEqual({ note: 'Goodwill', amount_cents: 1999 })
  })

  it('keeps an unconfirmed request and replays the same key, even after reopening', async () => {
    apiClient.post.mockRejectedValueOnce(new Error('timeout'))
    const first = setup()
    await first.user.type(await screen.findByLabelText('Note for the audit log'), 'Duplicate purchase')
    await first.user.click(screen.getByRole('button', { name: 'Refund $105.00' }))
    expect(await screen.findByRole('alert')).toHaveTextContent("isn't confirmed")
    const key = apiClient.post.mock.calls[0][2].headers['Idempotency-Key']
    expect(screen.queryByLabelText('Note for the audit log')).not.toBeInTheDocument()

    document.body.innerHTML = ''
    apiClient.post.mockResolvedValueOnce({ data: succeeded })
    const reopened = setup({ ...options, refundable_cents: 0 })
    await reopened.user.click(await screen.findByRole('button', { name: 'Check this refund' }))

    await waitFor(() => expect(reopened.onRefunded).toHaveBeenCalledWith(succeeded))
    expect(apiClient.post.mock.calls[1][2].headers['Idempotency-Key']).toBe(key)
    expect(apiClient.post.mock.calls[1][1]).toEqual({ note: 'Duplicate purchase' })
    expect(window.sessionStorage.getItem('hafapass_admin_refund:42')).toBeNull()
  })

  it('keeps the key for a refund still pending at Stripe', async () => {
    const pending = { ...succeeded, refund: { ...succeeded.refund, status: 'pending' } }
    apiClient.post.mockResolvedValue({ data: pending })
    const { user, onRefunded } = setup()
    await user.type(await screen.findByLabelText('Note for the audit log'), 'Duplicate purchase')
    await user.click(screen.getByRole('button', { name: 'Refund $105.00' }))
    await waitFor(() => expect(onRefunded).toHaveBeenCalledWith(pending))
    expect(window.sessionStorage.getItem('hafapass_admin_refund:42')).toBeTruthy()
  })

  it('clears a request the server definitely rejected and allows a new one', async () => {
    apiClient.post.mockRejectedValueOnce({ response: { status: 422, data: { error: 'Refund provider rejected the request', reconciliation_required: false } } })
    const { user } = setup()
    await user.type(await screen.findByLabelText('Note for the audit log'), 'Duplicate purchase')
    await user.click(screen.getByRole('button', { name: 'Refund $105.00' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Refund provider rejected the request No refund was sent.')
    expect(window.sessionStorage.getItem('hafapass_admin_refund:42')).toBeNull()
    expect(await screen.findByLabelText('Note for the audit log')).toBeInTheDocument()
  })

  it('explains an order that cannot be refunded here and offers no refund button', async () => {
    const { user, onClose } = setup({ ...options, refundable_cents: 0, unavailable_reason: 'This order needs finance review first. Resolve it in Refund issues.' })
    expect(await screen.findByRole('alert')).toHaveTextContent('finance review')
    expect(screen.queryByRole('button', { name: /^Refund/ })).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Close' }))
    expect(onClose).toHaveBeenCalled()
  })

  it('offers a retry when the refund details fail to load', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('down')).mockResolvedValue({ data: options })
    const user = userEvent.setup()
    render(<AdminOrderRefundDialog order={order} onClose={vi.fn()} onRefunded={vi.fn()} />)
    expect(await screen.findByRole('alert')).toHaveTextContent("couldn't load")
    await user.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByRole('button', { name: 'Refund $105.00' })).toBeInTheDocument()
  })
})

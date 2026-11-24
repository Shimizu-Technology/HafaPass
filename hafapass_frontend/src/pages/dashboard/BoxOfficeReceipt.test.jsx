import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import BoxOfficeReceipt from './BoxOfficeReceipt'

vi.mock('../../components/QRCode', () => ({ default: () => null }))

const base = { id: 9, reference: 'DEMO-R', status: 'completed', total_cents: 500, event_title: 'Demo Door Event', admissions: [], email_available: true }
const mountReceipt = (receipt, props = {}) => render(
  <BoxOfficeReceipt eventId="1" order={{ id: 9, receipt }} requestApi={vi.fn()} current={() => true} {...props} />,
)

describe('box office receipt email', () => {
  it('hands an email update back to the page so a remount does not revert it', async () => {
    const onReceiptChange = vi.fn()
    const requestApi = vi.fn().mockResolvedValue({ data: { email: 'buyer@example.test', email_status: 'queued' } })
    mountReceipt({ ...base, email: null, email_status: null }, { requestApi, onReceiptChange })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Email tickets' }))
    await user.type(screen.getByLabelText('Confirm buyer email'), 'buyer@example.test')
    await user.click(screen.getByRole('button', { name: 'Send tickets' }))
    expect(await screen.findByText('Ticket email queued for buyer@example.test.')).toBeInTheDocument()
    expect(onReceiptChange).toHaveBeenLastCalledWith(expect.objectContaining({ id: 9, email: 'buyer@example.test', email_status: 'queued' }))
  })

  it('offers no email action and explains why when the address is suppressed', () => {
    mountReceipt({ ...base, email: 'optout@example.test', email_status: 'suppressed' })
    expect(screen.queryByRole('button', { name: 'Email tickets' })).not.toBeInTheDocument()
    expect(screen.getByText(/cannot receive ticket emails/)).toBeInTheDocument()
  })

  it('only takes focus for a sale that just completed', () => {
    const { unmount } = mountReceipt(base)
    expect(document.activeElement).not.toBe(screen.getByRole('heading', { name: 'Sale complete!' }))
    unmount()
    render(<BoxOfficeReceipt eventId="1" order={{ id: 9, receipt: base, fresh: true }} requestApi={vi.fn()} current={() => true} />)
    expect(document.activeElement).toBe(screen.getByRole('heading', { name: 'Sale complete!' }))
  })
})

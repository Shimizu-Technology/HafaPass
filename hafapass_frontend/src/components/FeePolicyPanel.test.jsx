import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../api/client'
import FeePolicyPanel from './FeePolicyPanel'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), put: vi.fn() } }))

const config = { service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 business days after your event' }
const request = { config: { organizationId: '1' }, current: () => true, release: vi.fn() }

function mount(props = {}) {
  const onSaved = vi.fn()
  const view = render(<FeePolicyPanel eventId="11" event={{ fee_policy: 'buyer_pays', buyer_fee_percent: 100 }} canEdit
    beginRequest={() => request} onSaved={onSaved} {...props} />)
  return { ...view, onSaved }
}

describe('FeePolicyPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: config })
  })

  it('shows the all-in example from server fee terms and updates it for each policy', async () => {
    const user = userEvent.setup()
    mount()
    // $25.00 ticket: 5% ($1.25) + $1.00 = $2.25 fee.
    expect(await screen.findByTestId('fee-example')).toHaveTextContent('On a $25.00 ticket: buyer pays $27.25, you receive $25.00.')
    expect(screen.getByTestId('fee-terms-note')).toHaveTextContent('which includes card processing. You receive the full ticket price.')

    await user.click(screen.getByRole('radio', { name: /I cover the fee/ }))
    expect(screen.getByTestId('fee-example')).toHaveTextContent('buyer pays $25.00, you receive $22.75.')
    expect(screen.getByTestId('fee-terms-note')).toHaveTextContent('HåfaPass covers card processing out of this fee.')

    await user.click(screen.getByRole('radio', { name: /Split the fee/ }))
    const share = screen.getByLabelText('Buyer share of the fee (%)')
    expect(share).toHaveValue(50)
    expect(screen.getByTestId('fee-example')).toHaveTextContent('buyer pays $26.13, you receive $23.88.')
    await user.clear(share); await user.type(share, '100')
    expect(screen.getByText('Enter a whole number from 1 to 99.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save fee choice' })).toBeDisabled()
  })

  it('saves the choice through the event update API and reports it applies to new orders', async () => {
    const user = userEvent.setup()
    apiClient.put.mockResolvedValue({ data: { fee_policy: 'split_fees', buyer_fee_percent: 40 } })
    const { onSaved } = mount()
    await screen.findByTestId('fee-example')
    expect(screen.getByRole('button', { name: 'Save fee choice' })).toBeDisabled()
    await user.click(screen.getByRole('radio', { name: /Split the fee/ }))
    const share = screen.getByLabelText('Buyer share of the fee (%)')
    await user.clear(share); await user.type(share, '40')
    await user.click(screen.getByRole('button', { name: 'Save fee choice' }))

    expect(apiClient.put).toHaveBeenCalledWith('/organizer/events/11', { fee_policy: 'split_fees', buyer_fee_percent: 40 }, request.config)
    expect(onSaved).toHaveBeenCalledWith({ fee_policy: 'split_fees', buyer_fee_percent: 40 })
    expect(await screen.findByRole('status')).toHaveTextContent('Fee choice saved. It applies to new orders.')
  })

  it('is read-only for members who cannot manage the event and shows the organizer bearer copy', async () => {
    apiClient.get.mockResolvedValue({ data: { ...config, processing_fee_bearer: 'organizer' } })
    mount({ canEdit: false })
    expect(await screen.findByTestId('fee-example')).toHaveTextContent('you receive $25.00 before card processing.')
    expect(screen.getByRole('radio', { name: /Buyer pays the fee/ })).toBeDisabled()
    expect(screen.queryByRole('button', { name: 'Save fee choice' })).not.toBeInTheDocument()
  })

  it('offers a retry instead of a guessed example when fee terms cannot load', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ data: config })
    mount()
    await userEvent.click(await screen.findByRole('button', { name: 'Retry fee terms' }))
    await waitFor(() => expect(screen.getByTestId('fee-example')).toBeInTheDocument())
  })
})

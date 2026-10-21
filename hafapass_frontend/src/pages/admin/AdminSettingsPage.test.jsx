import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import AdminSettingsPage from './AdminSettingsPage'

vi.mock('../../api/client', async importOriginal => ({ ...await importOriginal(), default: { get: vi.fn(), patch: vi.fn() } }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const settings = {
  payment_mode: 'test', platform_name: 'HåfaPass', platform_email: 'help@example.com', platform_phone: '',
  service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform',
  payout_schedule_text: 'within 3 business days after your event',
  stripe_test_configured: true, stripe_live_configured: true, stripe_live_approved: false,
}
const renderPage = () => render(<MemoryRouter initialEntries={['/admin/settings']}><AdminSettingsPage /></MemoryRouter>)

describe('AdminSettingsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: settings })
    apiClient.patch.mockImplementation((_path, body) => Promise.resolve({ data: { ...settings, ...body } }))
  })

  it('shows a live fee example using checkout rounding and the processing bearer', async () => {
    const user = userEvent.setup()
    renderPage()
    const example = await screen.findByRole('region', { name: 'Fee example' })
    // $25.00 ticket at 5% + $1.00: 125 + 100 = 225.
    expect(within(example).getByText('Buyer pays').nextElementSibling).toHaveTextContent('$27.25')
    expect(within(example).getByText('Organizer receives').nextElementSibling).toHaveTextContent('$25.00')
    expect(example).toHaveTextContent('HåfaPass keeps $2.25 and pays card processing')

    await user.click(screen.getByRole('radio', { name: /Deducted from organizer proceeds/ }))
    expect(example).toHaveTextContent('minus the actual card processing cost')
    await user.clear(screen.getByLabelText('Service fee percentage', { exact: false }))
    await user.type(screen.getByLabelText('Service fee percentage', { exact: false }), '10')
    expect(within(example).getByText('Buyer pays').nextElementSibling).toHaveTextContent('$28.50')
  })

  it('confirms fee changes in a dialog and saves only the changed fields', async () => {
    const user = userEvent.setup()
    renderPage()
    const flat = await screen.findByLabelText('Flat fee per paid ticket', { exact: false })
    await user.clear(flat)
    await user.type(flat, '0.75')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))

    const dialog = screen.getByRole('dialog', { name: 'Change fee terms for new orders?' })
    expect(dialog).toHaveTextContent('Existing orders, settlements and payouts keep the terms')
    expect(dialog).toHaveTextContent('$1.00')
    expect(dialog).toHaveTextContent('$0.75')
    expect(within(dialog).getByTestId('policy-terms-effect')).toHaveTextContent('Every organizer must accept the updated agreement')
    expect(within(dialog).getByTestId('policy-terms-effect')).toHaveTextContent('needs a new approval')
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.click(within(dialog).getByRole('button', { name: 'Save fee terms' }))

    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings', { service_fee_flat_cents: 75 }, expect.anything()))
    expect(await screen.findByRole('status')).toHaveTextContent('existing orders keep theirs')
  })

  it('saves contact details without the fee dialog', async () => {
    const user = userEvent.setup()
    renderPage()
    await user.type(await screen.findByLabelText('Support phone', { exact: false }), '671-555-0100')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings', { platform_phone: '671-555-0100' }, expect.anything()))
  })

  it('shows validation errors inline and in a summary', async () => {
    const user = userEvent.setup()
    renderPage()
    const percent = await screen.findByLabelText('Service fee percentage', { exact: false })
    await user.clear(percent)
    await user.type(percent, '40')
    await user.clear(screen.getByLabelText('Support email', { exact: false }))
    await user.type(screen.getByLabelText('Support email', { exact: false }), 'not-an-email')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))

    expect(screen.getByRole('alert')).toHaveTextContent('Check these settings')
    expect(percent).toHaveAttribute('aria-invalid', 'true')
    expect(percent).toHaveAccessibleDescription(/between 0% and 25%/)
    expect(apiClient.patch).not.toHaveBeenCalled()
  })

  it('maps server validation messages to their fields', async () => {
    const user = userEvent.setup()
    apiClient.patch.mockRejectedValue({ response: { status: 422, data: { errors: ['Payout schedule text is too long'] } } })
    renderPage()
    await user.type(await screen.findByLabelText('Support phone', { exact: false }), '1')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    expect(await screen.findByText('Payout schedule text is too long', { selector: 'p' })).toBeInTheDocument()
  })

  it('shows the payment mode read-only with the live gates and a link to provider readiness', async () => {
    renderPage()
    const section = await screen.findByRole('region', { name: 'Payment mode' })
    expect(section).toHaveTextContent('Test (Stripe sandbox)')
    expect(section).toHaveTextContent('Live provider evidence independently approved: No')
    expect(within(section).queryByRole('button')).not.toBeInTheDocument()
    expect(within(section).getByRole('link', { name: 'Review provider readiness' })).toHaveAttribute('href', '/admin/provider-readiness')
  })
})

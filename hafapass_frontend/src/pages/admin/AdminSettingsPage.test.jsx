import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
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
  fee_notice_days: 30,
  policy_register_approved: true,
  stripe_test_configured: true, stripe_live_configured: true, stripe_live_approved: false,
  environment: 'production', payments_by_mode: { test: 12 },
  payment_mode_readiness: {
    test: { mode: 'test', ready: true, checks: [{ key: 'test_secret_key', label: 'Test secret key', met: true, help: null }] },
    live: { mode: 'live', ready: false, checks: [
      { key: 'live_secret_key', label: 'Live secret key', met: true, help: null },
      { key: 'stripe_live_approved', label: 'Stripe live payments approved in Provider readiness', met: false, help: 'Open Provider readiness, submit the Stripe live payments evidence, then approve it. One admin can do both.' },
    ] },
  },
}
const liveReady = { ...settings.payment_mode_readiness.live, ready: true, checks: settings.payment_mode_readiness.live.checks.map(check => ({ ...check, met: true, help: null })) }
const renderPage = () => render(<MemoryRouter initialEntries={['/admin/settings']}><AdminSettingsPage /></MemoryRouter>)

describe('AdminSettingsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('fee_change_preview')
      ? { affected_organizer_count: 4, owner_email_count: 3,
        unreachable_organization_ids: [9], unreachable_organizations: [{ id: 9, name: 'Missing Owner Events' }],
        minimum_notice_days: 30, registry_digest: 'a'.repeat(64) } : settings }))
    apiClient.patch.mockImplementation((_path, body) => Promise.resolve({ data: { ...settings, ...body } }))
  })

  it('requires an explicit production acknowledgment before enabling live retention purge', async () => {
    const user = userEvent.setup()
    renderPage()
    const button = await screen.findByRole('button', { name: 'Enable scheduled purge' })
    expect(screen.getByText(/two-day sales-export S3 cleanup runs independently of these retention controls/))
      .toHaveTextContent('still respects legal holds')
    expect(screen.getByText('Deletion is disabled on this server')).toBeInTheDocument()
    expect(button).toBeDisabled()
    await user.click(screen.getByRole('checkbox', { name: /reviewed the retention schedule/ }))
    await user.click(button)
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings',
      { retention_purge_enabled: true }, expect.anything()))
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

  it('previews recipients and schedules fee changes with an effective date', async () => {
    const user = userEvent.setup()
    renderPage()
    const flat = await screen.findByLabelText('Flat fee per paid ticket', { exact: false })
    await user.clear(flat)
    await user.type(flat, '0.75')
    const noticeDays = screen.getByLabelText('Minimum organizer notice (days)', { exact: false })
    await user.clear(noticeDays)
    await user.type(noticeDays, '45')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))

    const dialog = await screen.findByRole('dialog', { name: 'Schedule fee term changes?' })
    expect(dialog).toHaveTextContent('4 organizations affected · 3 owners will be emailed')
    expect(dialog).toHaveTextContent('1 affected organization has no reachable owner')
    expect(dialog).toHaveTextContent('Missing Owner Events')
    expect(dialog).toHaveTextContent(`Future policy register digest: ${'a'.repeat(64)}`)
    expect(apiClient.get).toHaveBeenCalledWith('/admin/settings/fee_change_preview', {
      params: { service_fee_flat_cents: 75 },
    })
    expect(dialog).toHaveTextContent('At least 45 days from now')
    expect(dialog).toHaveTextContent('$1.00')
    expect(dialog).toHaveTextContent('$0.75')
    expect(within(dialog).getByTestId('policy-terms-effect')).toHaveTextContent('Every organizer must accept the updated agreement')
    expect(within(dialog).getByTestId('policy-terms-effect')).toHaveTextContent('Approve the exact future terms')
    expect(apiClient.patch).not.toHaveBeenCalled()
    fireEvent.change(within(dialog).getByLabelText(/Effective date and time/), { target: { value: '2027-12-01T12:00' } })
    expect(within(dialog).getByRole('button', { name: 'Schedule fee change' })).toBeDisabled()
    await user.click(within(dialog).getByLabelText(/I approve these exact future fee/))
    await user.click(within(dialog).getByRole('button', { name: 'Schedule fee change' }))

    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings',
      expect.objectContaining({ service_fee_flat_cents: 75, fee_notice_days: 45, effective_at: expect.any(String),
        future_terms_approved: true,
        approved_registry_digest: 'a'.repeat(64) }), expect.anything()))
    expect(await screen.findByRole('status')).toHaveTextContent('Fee change scheduled')
  })

  it('saves contact details without the fee dialog', async () => {
    const user = userEvent.setup()
    renderPage()
    await user.type(await screen.findByLabelText('Support phone', { exact: false }), '671-555-0100')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings', {
      platform_phone: '671-555-0100', tax_year: String(new Date().getFullYear()),
    }, expect.anything()))
  })

  it('loads and saves a prior tax year threshold with its selected year', async () => {
    const user = userEvent.setup()
    apiClient.get.mockImplementation((_path, config) => Promise.resolve({ data: {
      ...settings,
      tax_year: Number(config.params.tax_year),
      tax_reporting_thresholds: config.params.tax_year === '2025'
        ? { '1099-nec': 60000, '1099-misc': 60000, '1099-k': 2000000 }
        : { '1099-nec': 200000, '1099-misc': 200000, '1099-k': 2000000 },
    } }))
    renderPage()
    await screen.findByLabelText('Tax year')
    await user.selectOptions(screen.getByLabelText('Tax year'), '2025')
    const threshold = await screen.findByLabelText('1099-NEC threshold (cents)')
    await waitFor(() => expect(threshold).toHaveValue(60000))
    await user.clear(threshold)
    await user.type(threshold, '65000')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings', {
      tax_year: '2025', tax_reporting_thresholds: { '1099-nec': 65000, '1099-misc': 60000, '1099-k': 2000000 },
    }, expect.anything()))
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

  it('caps the withholding rate below 10000 basis points', async () => {
    const user = userEvent.setup()
    renderPage()
    const rate = await screen.findByLabelText('Withholding rate (basis points)')
    expect(rate).toHaveAttribute('max', '9999')
    await user.clear(rate)
    await user.type(rate, '10000')
    await user.click(screen.getByRole('button', { name: 'Save settings' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Enter a rate from 1 to 9999 basis points.')
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

  it('shows the current mode and explains what live payments still need', async () => {
    renderPage()
    const section = await screen.findByRole('region', { name: 'Payment mode' })
    expect(section).toHaveTextContent('Test payments')
    expect(section).toHaveTextContent('12 test, 0 live')
    expect(section).toHaveTextContent('Stripe live payments approved in Provider readiness: missing')
    expect(section).toHaveTextContent('One admin can do both.')
    expect(within(section).getByRole('button', { name: 'Switch to live payments' })).toBeDisabled()
    expect(within(section).queryByRole('button', { name: 'Switch to test mode' })).not.toBeInTheDocument()
    expect(within(section).getByRole('link', { name: 'Review provider readiness' })).toHaveAttribute('href', '/admin/provider-readiness')
  })

  it('switches to live payments only after confirming the effects', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...settings, payment_mode_readiness: { ...settings.payment_mode_readiness, live: liveReady } } })
    renderPage()
    const section = await screen.findByRole('region', { name: 'Payment mode' })
    await user.click(within(section).getByRole('button', { name: 'Switch to live payments' }))

    const dialog = screen.getByRole('dialog', { name: 'Switch to live payments?' })
    expect(dialog).toHaveTextContent('charged real money')
    expect(dialog).toHaveTextContent('Orders already paid in test mode stay test orders')
    expect(dialog).toHaveTextContent('Tickets bought with test cards stop working at the door.')
    expect(dialog).toHaveTextContent('Door staff: refresh the scanner (re-download the event) after this switch so it uses the new mode.')
    expect(apiClient.patch).not.toHaveBeenCalled()
    await user.click(within(dialog).getByRole('button', { name: 'Yes, take real payments' }))

    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/settings', { payment_mode: 'live' }, expect.anything()))
    expect(await within(section).findByRole('status')).toHaveTextContent('Payments are now live')
    expect(section).toHaveTextContent('Live payments')
    expect(within(section).getByRole('button', { name: 'Switch to test mode' })).toBeEnabled()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('keeps the dialog open with the server reason when a switch is refused', async () => {
    const user = userEvent.setup()
    apiClient.get.mockResolvedValue({ data: { ...settings, payment_mode: 'live', payment_mode_readiness: { ...settings.payment_mode_readiness, live: liveReady } } })
    apiClient.patch.mockRejectedValue({ response: { status: 422, data: { error: 'Cannot switch to test payments yet. Still needed: Test webhook signing secret.' } } })
    renderPage()
    const section = await screen.findByRole('region', { name: 'Payment mode' })
    expect(section).toHaveTextContent('Live payments')
    await user.click(within(section).getByRole('button', { name: 'Switch to test mode' }))
    const dialog = screen.getByRole('dialog', { name: 'Switch to test payments?' })
    expect(dialog).toHaveTextContent('Live orders already paid stay live.')
    expect(dialog).toHaveTextContent('Door staff: refresh the scanner (re-download the event) after this switch so it uses the new mode.')
    expect(dialog).toHaveTextContent('Paid events keep selling, but only Stripe test cards work. Real buyers can’t pay until you switch back to live.')
    await user.click(within(dialog).getByRole('button', { name: 'Switch to test mode' }))

    expect(await within(dialog).findByRole('alert')).toHaveTextContent('Still needed: Test webhook signing secret.')
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(section).toHaveTextContent('Live payments')
  })
  it('says exactly what test mode does and re-checks readiness without reloading', async () => {
    const user = userEvent.setup()
    renderPage()
    const section = await screen.findByRole('region', { name: 'Payment mode' })
    expect(section).toHaveTextContent('Only Stripe test cards work (for example 4242 4242 4242 4242); real cards are declined and nothing is charged.')
    expect(section).toHaveTextContent('While in test mode only HåfaPass admins can buy paid tickets; everyone else sees “Paid ticket sales open soon.” Free tickets work for everyone.')
    expect(section).not.toHaveTextContent('reload this page')
    await user.type(screen.getByLabelText('Support phone', { exact: false }), '9')
    apiClient.get.mockResolvedValue({ data: { ...settings, payment_mode_readiness: { ...settings.payment_mode_readiness, live: liveReady } } })
    await user.click(within(section).getByRole('button', { name: 'Check again' }))
    await waitFor(() => expect(within(section).getByRole('button', { name: 'Switch to live payments' })).toBeEnabled())
    expect(apiClient.get).toHaveBeenCalledTimes(2)
    expect(within(section).queryByRole('button', { name: 'Check again' })).not.toBeInTheDocument()
    expect(screen.getByLabelText('Support phone', { exact: false })).toHaveValue('9')
  })

  it('calls simulated checkout in production what it is: paid sales are off', async () => {
    apiClient.get.mockResolvedValue({ data: { ...settings, payment_mode: 'simulate' } })
    renderPage()
    const section = await screen.findByRole('region', { name: 'Payment mode' })
    expect(section).toHaveTextContent('Paid sales are off')
    expect(section).toHaveTextContent('Paid checkout is turned off until you switch to test or live payments. Free events still work.')
    expect(section).not.toHaveTextContent('Simulated payments')
    expect(within(section).getByRole('button', { name: 'Switch to test mode' })).toBeEnabled()
    expect(within(section).queryByRole('button', { name: /simulat/i })).not.toBeInTheDocument()
  })
})

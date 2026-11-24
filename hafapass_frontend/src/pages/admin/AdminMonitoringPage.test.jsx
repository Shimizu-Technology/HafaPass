import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import AdminMonitoringPage from './AdminMonitoringPage'
import { publishAccountRole } from '../../utils/workspace'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, isSignedIn: true, userId: 'synthetic' }) }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const webhooks = {
  checked_at: '2027-01-05T10:00:00Z', last_receipt_at: '2027-01-05T09:58:00Z', last_processed_at: '2027-01-05T09:58:00Z',
  receipts_last_hour: 12, failed_in_window: 0, stuck_processing: 0, failed_total: 0, paid_without_webhook: 0, unresolved_paid_without_webhook: 0,
  recent_payment_attempts: 3, silent: false, failing: false, unverified_failing: false, rejected_in_window: 0, mode: 'live',
  thresholds: { failure_window_minutes: 15, failure_threshold: 3, silence_minutes: 30, silence_lookback_minutes: 360, silence_min_attempts: 10 },
}
const body = (overrides = {}) => ({
  stripe_webhooks: { ...webhooks, ...overrides },
  summary: {
    guam_date: '2027-01-04', window: { partial: false },
    sales: { orders: 20, tickets: 31, gross_cents: 52700, refund_cents: 0, online: { gross_cents: 50000, orders: 19 }, door_cash: { gross_cents: 2700, orders: 1 } },
    on_sale: [{ event_id: 1, title: 'Copa de Marianas Gran Campeonato Internacional Extremadamente Largo '.repeat(2), max_capacity: 900, capacity_remaining: 212 }],
    health: { readiness: 'ready', job_queue: { available: true, ready: 0 } },
  },
  sentry: { configured: true, sending_enabled: true, environment: 'production' },
  test_alert_kinds: ['stripe_webhooks_silent', 'checkout', 'sentry_connectivity'],
})
const renderPage = () => render(<MemoryRouter initialEntries={['/admin/monitoring']}><AdminMonitoringPage /></MemoryRouter>)

beforeEach(() => { vi.clearAllMocks(); setAuthTokenGetter(null)(); apiClient.get.mockResolvedValue({ data: body() }) })
afterEach(() => { cleanup(); publishAccountRole(null, null) })

describe('monitoring page', () => {
  it('shows a calm healthy state, the sales summary and capacity', async () => {
    renderPage()
    expect(await screen.findByText(/Webhooks are arriving and being processed/)).toBeVisible()
    expect(screen.getByText('Sales, 2027-01-04 (Guam)')).toBeVisible()
    expect(screen.getByText('$527.00')).toBeVisible()
    expect(screen.getByText(/212 of 900 left/)).toBeVisible()
    expect(apiClient.get).toHaveBeenCalledWith('/admin/monitoring', expect.anything())
  })

  it('shows silence and failures prominently and warns when Sentry is not configured', async () => {
    apiClient.get.mockResolvedValue({ data: { ...body({ silent: true, failing: true, paid_without_webhook: 2, failed_in_window: 3 }), sentry: { configured: false, sending_enabled: false } } })
    renderPage()
    expect(await screen.findByText(/Webhooks look silent while payments are being made/)).toBeVisible()
    expect(screen.getByText(/SENTRY_DSN/)).toBeVisible()
  })

  it('does not show all clear when an aged-out paid payment still lacks its webhook', async () => {
    apiClient.get.mockResolvedValue({ data: body({ unresolved_paid_without_webhook: 2 }) })
    renderPage()
    expect(await screen.findByText(/2 paid payments from the last 7 days still have no success webhook/)).toBeVisible()
    expect(screen.getByText(/not all clear/)).toBeVisible()
  })

  it('says plainly when the signing secret is being rejected', async () => {
    apiClient.get.mockResolvedValue({ data: body({ unverified_failing: true, rejected_in_window: 7 }) })
    renderPage()
    expect(await screen.findByText(/bad signature/)).toBeVisible()
    expect(screen.getByText('Stripe webhooks (live mode)')).toBeVisible()
  })

  it('warns when Sentry has a DSN but is switched off for this environment', async () => {
    apiClient.get.mockResolvedValue({ data: { ...body(), sentry: { configured: true, sending_enabled: false, environment: 'staging' } } })
    renderPage()
    expect(await screen.findByText(/switched off for this environment \(staging\)/)).toBeVisible()
  })

  it('shows a clear failure when Sentry queues nothing', async () => {
    apiClient.post.mockRejectedValue({ response: { status: 502, data: { sent: false, error: 'Sentry did not accept the test alert, so nothing was sent.' } } })
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Send test alert' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Sentry did not accept the test alert')
  })

  it('sends a labelled test alert once and reports success', async () => {
    apiClient.post.mockResolvedValue({ data: { sent: true } })
    renderPage()
    await userEvent.selectOptions(await screen.findByLabelText('Alert to test'), 'stripe_webhooks_silent')
    await userEvent.click(screen.getByRole('button', { name: 'Send test alert' }))
    expect(await screen.findByText('Sentry accepted the test alert. Check your phone in a minute or two.')).toBeVisible()
    expect(apiClient.post).toHaveBeenCalledTimes(1)
    expect(apiClient.post).toHaveBeenCalledWith('/admin/monitoring/test_alert', { kind: 'stripe_webhooks_silent' }, expect.anything())
  })

  it('shows the server reason when a test alert is refused', async () => {
    apiClient.post.mockRejectedValue({ response: { status: 429, data: { error: 'A test alert was just sent. Wait a moment before sending another.' } } })
    renderPage()
    await userEvent.click(await screen.findByRole('button', { name: 'Send test alert' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('A test alert was just sent')
  })

  it('offers retry when loading fails', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('outage'))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('Monitoring could not be loaded.')
    await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(await screen.findByText(/Webhooks are arriving/)).toBeVisible()
  })
})

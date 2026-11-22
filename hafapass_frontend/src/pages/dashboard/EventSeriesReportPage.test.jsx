import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient, { setAuthTokenGetter } from '../../api/client'
import { saveBlob } from '../../utils/download'
import { resetOrganizerOrganizations } from '../../utils/organizerOrganizations'
import EventSeriesReportPage from './EventSeriesReportPage'

vi.mock('../../api/client', async (original) => ({
  ...(await original()),
  default: { get: vi.fn(), patch: vi.fn() },
}))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))

const sampleReport = {
  series: {
    id: 10,
    organization_id: 1,
    name: 'FD Alumni Tournament 2026',
    slug: 'fd-alumni-2026',
    description: 'Annual basketball tournament across 14 nights.',
    status: 'active',
    revenue_share_bps: 1600,
    revenue_share_base: 'admissions_net_proceeds',
    revenue_share_includes_door_cash: true,
    revenue_share_label: 'School Share',
    primary_share_label: 'Alumni Share',
    events_count: 2,
  },
  organization: {
    id: 1,
    name: 'FD Alumni Association',
    slug: 'fd-alumni',
    timezone: 'Pacific/Guam',
  },
  currency: 'usd',
  groups: {
    admissions: {
      events_count: 1,
      gross_cents: 10000,
      discount_cents: 500,
      refund_cents: 0,
      organizer_proceeds_cents: 9500,
      door_cash_retained_cents: 2000,
      reserve_cents: 500,
      payable_cents: 7000,
      paid_cents: 2000,
      owed_cents: 5000,
      tickets_issued_count: 8,
      checked_in_count: 6,
    },
    registration: {
      events_count: 1,
      gross_cents: 30000,
      discount_cents: 0,
      refund_cents: 0,
      organizer_proceeds_cents: 30000,
      door_cash_retained_cents: 0,
      reserve_cents: 0,
      payable_cents: 30000,
      paid_cents: 30000,
      owed_cents: 0,
      tickets_issued_count: 1,
      checked_in_count: 0,
    },
    other: {
      events_count: 0,
      gross_cents: 0,
      organizer_proceeds_cents: 0,
      owed_cents: 0,
      tickets_issued_count: 0,
      checked_in_count: 0,
    },
    combined: {
      events_count: 2,
      gross_cents: 40000,
      discount_cents: 500,
      refund_cents: 0,
      organizer_proceeds_cents: 39500,
      door_cash_retained_cents: 2000,
      reserve_cents: 500,
      payable_cents: 37000,
      paid_cents: 32000,
      owed_cents: 5000,
      tickets_issued_count: 9,
      checked_in_count: 6,
    },
  },
  channels: {
    online_stripe: {
      channel: 'online_stripe',
      label: 'Online (Stripe)',
      orders_count: 4,
      tickets_issued_count: 5,
      checked_in_count: 3,
      gross_cents: 38000,
      organizer_proceeds_cents: 37500,
      door_cash_retained_cents: 0,
    },
    door_card: {
      channel: 'door_card',
      label: 'Door (Card)',
      orders_count: 1,
      tickets_issued_count: 1,
      checked_in_count: 1,
      gross_cents: 1500,
      organizer_proceeds_cents: 1500,
      door_cash_retained_cents: 0,
    },
    door_cash: {
      channel: 'door_cash',
      label: 'Door Cash',
      orders_count: 2,
      tickets_issued_count: 2,
      checked_in_count: 2,
      gross_cents: 2000,
      organizer_proceeds_cents: 2000,
      door_cash_retained_cents: 2000,
    },
    free_comp: {
      channel: 'free_comp',
      label: 'Free / Comp',
      orders_count: 1,
      tickets_issued_count: 2,
      checked_in_count: 1,
      gross_cents: 0,
      organizer_proceeds_cents: 0,
      door_cash_retained_cents: 0,
    },
  },
  revenue_share: {
    revenue_share_bps: 1600,
    primary_share_bps: 8400,
    revenue_share_label: 'School Share',
    primary_share_label: 'Alumni Share',
    revenue_share_base: 'admissions_net_proceeds',
    revenue_share_includes_door_cash: true,
    base_cents: 9500,
    share_cents: 1520,
    primary_cents: 7980,
    door_cash_retained_cents: 2000,
    net_platform_payable_cents: 37000,
    paid_cents: 32000,
    owed_cents: 5000,
    reserve_cents: 500,
  },
  closeout_checklist: {
    events_total: 2,
    awaiting_completion_count: 0,
    not_finalized_count: 0,
    changed_since_finalization_count: 0,
    ready_for_payout_count: 1,
    paid_count: 1,
    active_reserve_count: 1,
    total_reserve_cents: 500,
    total_owed_cents: 5000,
    check_reference_pattern: 'CHK-<check_number>-E<event_id>',
    guidance: 'Finalize each completed event individually and use CHK-<check_number>-E<event_id>.',
  },
  events: [
    {
      event_id: 101,
      title: 'Night 1 - Pool Play',
      slug: 'night-1',
      status: 'completed',
      starts_at: '2026-12-01T08:00:00Z',
      timezone: 'Pacific/Guam',
      role: 'regular_night',
      position: 0,
      awaiting_completion: false,
      gross_cents: 10000,
      discount_cents: 500,
      refund_cents: 0,
      processing_fee_cents: 0,
      organizer_proceeds_cents: 9500,
      door_cash_retained_cents: 2000,
      payable_cents: 7000,
      paid_cents: 2000,
      owed_cents: 5000,
      settlement: { id: 1, version: 1, current: true },
      settlement_state: 'finalized',
      payout_state: 'ready',
      tickets_issued_count: 8,
      direct_paid_tickets_count: 6,
      free_tickets_count: 2,
      pass_child_tickets_count: 0,
      checked_in_count: 6,
    },
    {
      event_id: 102,
      title: 'Team Registration',
      slug: 'team-registration',
      status: 'completed',
      starts_at: '2026-11-20T08:00:00Z',
      timezone: 'Pacific/Guam',
      role: 'registration',
      position: 1,
      awaiting_completion: false,
      gross_cents: 30000,
      discount_cents: 0,
      refund_cents: 0,
      processing_fee_cents: 0,
      organizer_proceeds_cents: 30000,
      door_cash_retained_cents: 0,
      payable_cents: 30000,
      paid_cents: 30000,
      owed_cents: 0,
      settlement: { id: 2, version: 1, current: true },
      settlement_state: 'finalized',
      payout_state: 'paid',
      tickets_issued_count: 1,
      direct_paid_tickets_count: 1,
      free_tickets_count: 0,
      pass_child_tickets_count: 0,
      checked_in_count: 0,
    },
  ],
  ticket_types: [
    {
      event_id: 101,
      event_title: 'Night 1 - Pool Play',
      role: 'regular_night',
      ticket_type_id: 501,
      ticket_type_name: 'General Admission',
      pricing_tier_id: 601,
      pricing_tier_name: 'Early Bird',
      price_cents: 1000,
      tickets_issued_count: 6,
      checked_in_count: 5,
      gross_cents: 10000,
      discount_cents: 500,
      refunded_proceeds_cents: 0,
      organizer_proceeds_cents: 9500,
    },
  ],
  generated_at: '2026-12-06T00:00:00Z',
}

const financeOrg = {
  id: 1,
  name: 'FD Alumni Association',
  permissions: { view_finance: true, manage_finance: true, manage_events: false },
}

let clearAuth

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/dashboard/series/10/report']}>
      <Routes>
        <Route path="/dashboard/series/:seriesId/report" element={<EventSeriesReportPage />} />
      </Routes>
    </MemoryRouter>
  )
}

describe('EventSeriesReportPage', () => {
  beforeEach(() => {
    resetOrganizerOrganizations()
    window.localStorage.clear()
    vi.clearAllMocks()
    apiClient.get.mockReset()
    apiClient.patch.mockReset()
    saveBlob.mockReset()
    vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
    window.localStorage.setItem('hafapass_scanner_user_id', 'finance-user')
    window.localStorage.setItem('hafapass_organization_id', '1')
    clearAuth = setAuthTokenGetter(() => Promise.resolve('synthetic-token'), {
      userId: 'finance-user',
      sessionId: 'session-1',
      ready: true,
    })
  })

  afterEach(() => {
    cleanup()
    clearAuth?.()
    vi.unstubAllEnvs()
  })

  it('renders KPIs, revenue-share worksheet, closeout checklist, channels, events, and ticket types', async () => {
    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') return Promise.resolve({ data: sampleReport })
      if (url === '/organizer/organizations') return Promise.resolve({ data: [financeOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()

    expect(await screen.findByRole('heading', { name: 'FD Alumni Tournament 2026' })).toBeInTheDocument()

    // KPIs
    const highlights = screen.getByRole('region', { name: 'Series financial highlights' })
    expect(within(highlights).getByText('$100.00')).toBeInTheDocument()
    expect(within(highlights).getByText('$395.00')).toBeInTheDocument()
    expect(within(highlights).getByText('$20.00')).toBeInTheDocument()
    expect(within(highlights).getByText('$370.00')).toBeInTheDocument()
    expect(within(highlights).getByText('$50.00')).toBeInTheDocument()

    // Revenue-share worksheet
    const worksheet = screen.getByTestId('revenue-share-worksheet')
    expect(within(worksheet).getByText('School Share')).toBeInTheDocument()
    expect(within(worksheet).getByText('$15.20')).toBeInTheDocument()
    expect(within(worksheet).getByText('Alumni Share')).toBeInTheDocument()
    expect(within(worksheet).getByText('$79.80')).toBeInTheDocument()

    // Closeout checklist & check reference pattern
    const checklist = screen.getByRole('region', { name: 'Closeout & Payout Checklist' })
    expect(within(checklist).getByText('CHK-<check_number>-E<event_id>')).toBeInTheDocument()
    expect(within(checklist).getByText(/30-day reserve holdback reminder/i)).toBeInTheDocument()

    // Channel & Per-Event & Ticket-Type sections
    const channelsSection = screen.getByRole('region', { name: 'Channel Breakdown' })
    expect(within(channelsSection).getByText('Online (Stripe)')).toBeInTheDocument()
    expect(within(channelsSection).getByText('Door (Card)')).toBeInTheDocument()
    expect(within(channelsSection).getByText('Door Cash')).toBeInTheDocument()
    expect(within(channelsSection).getByText('Free / Comp')).toBeInTheDocument()
    const eventLinks = screen.getAllByRole('link', { name: 'Night 1 - Pool Play' })
    expect(eventLinks[0]).toHaveAttribute('href', '/dashboard/events/101/analytics#settlement')
    expect(screen.getAllByText(/General Admission/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Early Bird/).length).toBeGreaterThan(0)
    // Mobile cards also display non-zero discounts
    expect(screen.getAllByText(/Discounts −\$5\.00/).length).toBeGreaterThanOrEqual(2)
  })

  it('hides split settings editor for managers who lack manage_finance permission', async () => {
    const managerOrg = {
      id: 1,
      name: 'FD Alumni Association',
      permissions: { view_finance: true, manage_events: true, manage_finance: false },
    }
    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') return Promise.resolve({ data: sampleReport })
      if (url === '/organizer/organizations') return Promise.resolve({ data: [managerOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()
    expect(await screen.findByRole('heading', { name: 'FD Alumni Tournament 2026' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Edit Split Settings/i })).not.toBeInTheDocument()
  })

  it('triggers CSV export download', async () => {
    const user = userEvent.setup()
    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') return Promise.resolve({ data: sampleReport })
      if (url === '/organizer/organizations') return Promise.resolve({ data: [financeOrg] })
      if (url === '/organizer/event_series/10/report_export') {
        return Promise.resolve({ data: new Blob(['csv-content'], { type: 'text/csv' }) })
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()
    const exportBtn = await screen.findByRole('button', { name: /Export CSV/i })
    await user.click(exportBtn)

    await waitFor(() => {
      expect(apiClient.get).toHaveBeenCalledWith(
        '/organizer/event_series/10/report_export',
        expect.objectContaining({ responseType: 'blob' })
      )
    })
    expect(saveBlob).toHaveBeenCalledWith(expect.any(Blob), 'fd-alumni-2026-series-report.csv')
  })

  it('allows permitted users to edit split settings and reloads the report', async () => {
    const user = userEvent.setup()
    let currentReport = structuredClone(sampleReport)

    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') return Promise.resolve({ data: currentReport })
      if (url === '/organizer/organizations') return Promise.resolve({ data: [financeOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    apiClient.patch.mockImplementation((url, payload) => {
      if (url === '/organizer/event_series/10') {
        currentReport = {
          ...currentReport,
          revenue_share: {
            ...currentReport.revenue_share,
            revenue_share_bps: payload.revenue_share_bps,
            primary_share_bps: 10000 - payload.revenue_share_bps,
            revenue_share_base: payload.revenue_share_base,
            revenue_share_includes_door_cash: payload.revenue_share_includes_door_cash,
            base_cents: 7500,
            share_cents: 1500,
            primary_cents: 6000,
          },
        }
        return Promise.resolve({ data: { id: 10, ...payload } })
      }
      return Promise.reject(new Error(`Unexpected PATCH ${url}`))
    })

    renderPage()
    const editBtn = await screen.findByRole('button', { name: /Edit Split Settings/i })
    expect(editBtn).toHaveAttribute('aria-expanded', 'false')
    await user.click(editBtn)
    expect(screen.getByRole('button', { name: /Cancel edit/i })).toHaveAttribute('aria-expanded', 'true')

    const pctInput = screen.getByLabelText(/Revenue share \(%\)/i)
    await user.clear(pctInput)
    await user.type(pctInput, '20')
    await user.selectOptions(screen.getByLabelText(/Calculation base/i), 'admissions_gross')
    await user.click(screen.getByLabelText(/Include door cash sales/i))
    await user.click(screen.getByRole('button', { name: /Save Split Settings/i }))

    await waitFor(() => {
      expect(apiClient.patch).toHaveBeenCalledWith(
        '/organizer/event_series/10',
        expect.objectContaining({
          revenue_share_bps: 2000,
          revenue_share_base: 'admissions_gross',
          revenue_share_includes_door_cash: false,
        }),
        expect.any(Object)
      )
    })

    expect(await screen.findByRole('status')).toHaveTextContent('Revenue-share settings updated.')
    expect(within(screen.getByTestId('revenue-share-worksheet')).getByText('$15.00')).toBeInTheDocument()
  })

  it('keeps the loaded report visible with an inline error notice when refresh fails after saving split settings', async () => {
    const user = userEvent.setup()
    let reportLoads = 0

    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') {
        reportLoads += 1
        if (reportLoads === 1) return Promise.resolve({ data: sampleReport })
        return Promise.reject({ response: { status: 500 } })
      }
      if (url === '/organizer/organizations') return Promise.resolve({ data: [financeOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })
    apiClient.patch.mockResolvedValue({ data: { id: 10, revenue_share_bps: 2000 } })

    renderPage()
    await user.click(await screen.findByRole('button', { name: /Edit Split Settings/i }))
    await user.click(screen.getByRole('button', { name: /Save Split Settings/i }))

    expect(await screen.findByRole('alert')).toHaveTextContent(/Split settings were saved, but the report could not be refreshed/i)
    expect(screen.getByRole('heading', { name: 'FD Alumni Tournament 2026' })).toBeInTheDocument()
    expect(screen.getByTestId('revenue-share-worksheet')).toBeInTheDocument()
  })

  it('retains saved split settings when report refresh fails so reopening and saving a label-only edit does not revert percentage', async () => {
    const user = userEvent.setup()
    let reportLoads = 0

    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') {
        reportLoads += 1
        if (reportLoads === 1) return Promise.resolve({ data: sampleReport })
        return Promise.reject({ response: { status: 500 } })
      }
      if (url === '/organizer/organizations') return Promise.resolve({ data: [financeOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })
    apiClient.patch.mockImplementation((url, payload) => {
      if (url === '/organizer/event_series/10') {
        return Promise.resolve({
          data: {
            id: 10,
            revenue_share_bps: payload.revenue_share_bps,
            revenue_share_base: payload.revenue_share_base,
            revenue_share_includes_door_cash: payload.revenue_share_includes_door_cash,
            revenue_share_label: payload.revenue_share_label,
            primary_share_label: payload.primary_share_label,
          },
        })
      }
      return Promise.reject(new Error(`Unexpected PATCH ${url}`))
    })

    renderPage()
    // 1. Open editor, change 16% -> 20%, save (PATCH succeeds, report refresh fails)
    await user.click(await screen.findByRole('button', { name: /Edit Split Settings/i }))
    const pctInput = screen.getByLabelText(/Revenue share \(%\)/i)
    expect(pctInput).toHaveValue(16)
    await user.clear(pctInput)
    await user.type(pctInput, '20')
    await user.click(screen.getByRole('button', { name: /Save Split Settings/i }))

    expect(await screen.findByRole('alert')).toHaveTextContent(/Split settings were saved, but the report could not be refreshed/i)
    expect(apiClient.patch).toHaveBeenNthCalledWith(
      1,
      '/organizer/event_series/10',
      expect.objectContaining({
        revenue_share_bps: 2000,
        revenue_share_label: 'School Share',
      }),
      expect.any(Object)
    )

    // 2. Reopen editor while stale report data (16%) is still displayed -> must still show 20%
    await user.click(screen.getByRole('button', { name: /Edit Split Settings/i }))
    const reopenedPctInput = screen.getByLabelText(/Revenue share \(%\)/i)
    expect(reopenedPctInput).toHaveValue(20)

    // 3. Edit only the revenue-share label and save -> PATCH must still send 2000 bps (20%)
    const labelInput = screen.getByLabelText(/Revenue-share label/i)
    await user.clear(labelInput)
    await user.type(labelInput, 'School Athletics Fund')
    await user.click(screen.getByRole('button', { name: /Save Split Settings/i }))

    await waitFor(() => {
      expect(apiClient.patch).toHaveBeenNthCalledWith(
        2,
        '/organizer/event_series/10',
        expect.objectContaining({
          revenue_share_bps: 2000,
          revenue_share_label: 'School Athletics Fund',
        }),
        expect.any(Object)
      )
    })
  })

  it('surfaces negative balance and unresolved buyer liability in KPIs, alert callout, and per-event breakdown', async () => {
    const overpaidReport = structuredClone(sampleReport)
    overpaidReport.groups.combined.owed_cents = 0
    overpaidReport.groups.combined.negative_balance_cents = 5000
    overpaidReport.groups.combined.unresolved_buyer_liability_cents = 1500
    overpaidReport.events[0].owed_cents = 0
    overpaidReport.events[0].payout_state = 'paid'
    overpaidReport.events[0].negative_balance_cents = 5000
    overpaidReport.events[0].unresolved_buyer_liability_cents = 1500

    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') return Promise.resolve({ data: overpaidReport })
      if (url === '/organizer/organizations') return Promise.resolve({ data: [financeOrg] })
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()
    expect(await screen.findByRole('heading', { name: 'FD Alumni Tournament 2026' })).toBeInTheDocument()

    const highlights = screen.getByRole('region', { name: 'Series financial highlights' })
    expect(within(highlights).getByText(/Overpaid: −\$50\.00/)).toBeInTheDocument()
    expect(within(highlights).getByText(/Buyer liability: \$15\.00/)).toBeInTheDocument()

    const alert = screen.getByRole('alert')
    expect(alert).toHaveTextContent('−$50.00')
    expect(alert).toHaveTextContent('$15.00')

    const eventsSection = screen.getByRole('region', { name: 'Per-Event Breakdown' })
    expect(within(eventsSection).getAllByText(/Overpaid −\$50\.00/).length).toBeGreaterThan(0)
    expect(within(eventsSection).getAllByText(/Liability \$15\.00/).length).toBeGreaterThan(0)
  })

  it('shows a graceful no-access notice on 403', async () => {
    apiClient.get.mockImplementation((url) => {
      if (url === '/organizer/event_series/10/report') {
        return Promise.reject({ response: { status: 403 } })
      }
      if (url === '/organizer/organizations') {
        return Promise.resolve({ data: [{ id: 1, name: 'FD Alumni', permissions: { scan: true } }] })
      }
      return Promise.reject(new Error(`Unexpected GET ${url}`))
    })

    renderPage()
    expect(await screen.findByText('Series financial reports aren’t part of your role')).toBeInTheDocument()
  })
})

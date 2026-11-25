import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import apiClient from '../../api/client'
import { saveBlob } from '../../utils/download'
import AdminTaxReportsPage from './AdminTaxReportsPage'

vi.mock('../../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('../../utils/download', () => ({ saveBlob: vi.fn() }))
vi.mock('./AdminLayout', () => ({ default: ({ children }) => <div>{children}</div> }))

const guamParts = new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit' }).formatToParts(new Date())
const year = Number(guamParts.find(part => part.type === 'year').value)
const currentMonth = guamParts.find(part => part.type === 'month').value

const report = {
  year,
  note: "HåfaPass's gross receipts are its service fees; ticket proceeds belong to organizers (agent model). Confirm with your accountant.",
  organizers: [{
    organization_id: 7, organization_name: 'Island Events', w9_on_file: true, current_w9_on_file: true,
    tax_snapshot_status: 'W-9 snapshotted at payout', gross_ticket_proceeds_cents: 2500, gross_add_on_proceeds_cents: 500,
    gross_donation_proceeds_cents: 0, gross_other_proceeds_cents: 0, gross_non_ticket_proceeds_cents: 500,
    ticket_refunds_cents: 500, non_ticket_refunds_cents: 0, unallocated_refunds_cents: 0, fee_refunds_cents: 100,
    fees_collected_cents: 225, reconciliation_adjustments_cents: 0, net_paid_cents: 2375,
    tax_information: { legal_name: 'Island Events LLC', tax_classification: 'llc_c', masked_tin: '***-**-5678' },
  }],
  months: [{ month: 1, fees_collected_cents: 225, fees_refunded_cents: 100, gross_receipts_cents: 125, card_processing_costs_cents: 80 }],
}

const makeCpaMonthly = (y, m, overrides = {}) => {
  const padded = String(m).padStart(2, '0')
  return {
    year: Number(y),
    month: Number(m),
    period: `${y}-${padded}`,
    timezone: 'Pacific/Guam',
    currency: 'usd',
    bpt_rate_bps: 400,
    bpt_rate_pct: '4.00',
    bpt_rate_note: '4.00% statutory § 26202(c) service-business BPT estimate (P.L. 38-136; excludes § 26203.2 small-business relief — confirm with CPA)',
    note: 'Preparation aid only.',
    rows: [{
      organization_id: 7, event_id: 42, w9_nonprofit_classification: true, drt_exemption_verified: 'not_tracked',
      nonprofit_exemption_note: 'W-9 nonprofit; DRT exemption not tracked — verify externally',
      opening_custodial_liability_cents: 10000, proceeds_collected_cents: 50000, proceeds_refunded_cents: 2000,
      chargebacks_cents: 1000, organizer_processing_deducted_cents: 0, other_adjustments_cents: 0,
      organizer_payouts_made_cents: 45000, payout_reversals_cents: 0,
      closing_custodial_liability_cents: 12000, closing_custodial_payables_cents: 12000, closing_organizer_deficits_cents: 0,
      reserve_held_cents: 5000, reserve_released_cents: 0, ending_reserve_balance_cents: 5000,
      unallocated_refunds_exception_cents: 0, reconciliation_exception_flag: false, non_custodial_settlement_bridge_cents: 0,
      backup_withholding_memo_cents: 0, fee_revenue_gross_cents: 3500, fee_refunds_cents: 250,
      fee_revenue_net_cents: 3250, stripe_processing_costs_cents: 1650,
      bpt_base_fee_revenue_estimate_cents: 3250, estimated_bpt_rate_pct: '4.00',
      estimated_bpt_on_fee_revenue_estimate_cents: 130,
    }],
    totals: {
      w9_nonprofit_row_count: 1, drt_exemption_verified: 'not_tracked',
      nonprofit_exemption_note: '1 W-9 nonprofit row(s); DRT exemption not tracked',
      opening_custodial_liability_cents: 10000, proceeds_collected_cents: 50000, proceeds_refunded_cents: 2000,
      chargebacks_cents: 1000, organizer_processing_deducted_cents: 0, other_adjustments_cents: 0,
      organizer_payouts_made_cents: 45000, payout_reversals_cents: 0,
      closing_custodial_liability_cents: 12000, closing_custodial_payables_cents: 12000, closing_organizer_deficits_cents: 0,
      reserve_held_cents: 5000, reserve_released_cents: 0, ending_reserve_balance_cents: 5000,
      unallocated_refunds_exception_cents: 0, reconciliation_exception_flag: false, non_custodial_settlement_bridge_cents: 0,
      backup_withholding_memo_cents: 0, fee_revenue_gross_cents: 3500, fee_refunds_cents: 250,
      fee_revenue_net_cents: 3250, stripe_processing_costs_cents: 1650,
      bpt_base_fee_revenue_estimate_cents: 3250, estimated_bpt_rate_pct: '4.00',
      estimated_bpt_on_fee_revenue_estimate_cents: 130,
    },
    ...overrides,
  }
}

const show = () => render(<MemoryRouter initialEntries={['/admin/tax-reports']}><AdminTaxReportsPage /></MemoryRouter>)

describe('AdminTaxReportsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports/cpa_monthly') {
        return Promise.resolve({ data: makeCpaMonthly(cfg?.params?.year || year, cfg?.params?.month || currentMonth) })
      }
      return Promise.resolve({ data: { ...report, year: Number(cfg?.params?.year || year) } })
    })
  })

  it('shows masked identities, custodial vs fee revenue summary, W-9 nonprofit / DRT-unverified status, and accountant note', async () => {
    show()
    expect(await screen.findByText('***-**-5678')).toBeInTheDocument()
    expect(screen.getByText(/Live-mode USD payments only/)).toBeInTheDocument()
    expect(screen.getByText(report.note)).toBeInTheDocument()
    expect(screen.getByText('$1.25')).toBeInTheDocument()
    expect(await screen.findByText('Custodial liability (organizer proceeds)')).toBeInTheDocument()
    expect(screen.getByText('HåfaPass fee revenue & Guam BPT estimate')).toBeInTheDocument()
    expect(screen.getByText('W-9 nonprofit · DRT unverified')).toBeInTheDocument()
    expect(screen.getAllByText('$120.00').length).toBeGreaterThan(0)
    expect(screen.getAllByText('$1.30').length).toBeGreaterThan(0)
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Calendar year'), String(year - 1))
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/admin/tax_reports', expect.objectContaining({ params: { year: String(year - 1) } })))
  })

  // Regression test for Material Finding #7 (and CodeRabbit #8): never render one
  // month's figures under another month's heading while a slow request is pending
  // or arrives late; enable deferral only after initial load so the test works in
  // every calendar month (including March and April Guam time).
  it('hides stale month figures while loading and ignores out-of-order responses', async () => {
    const firstTarget = currentMonth === '03' ? '05' : '03'
    const secondTarget = currentMonth === '04' ? '06' : '04'
    const monthName = m => new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', month: 'long' }).format(Date.UTC(2000, Number(m) - 1, 1))
    let deferTargets = false
    let resolveFirst
    let resolveSecond
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports') return Promise.resolve({ data: report })
      if (url === '/admin/tax_reports/cpa_monthly') {
        const m = String(cfg?.params?.month)
        if (deferTargets && m === firstTarget) return new Promise(resolve => { resolveFirst = resolve })
        if (deferTargets && m === secondTarget) return new Promise(resolve => { resolveSecond = resolve })
        return Promise.resolve({ data: makeCpaMonthly(year, m) })
      }
      return Promise.resolve({ data: report })
    })

    show()
    expect(await screen.findByText('Custodial liability (organizer proceeds)')).toBeInTheDocument()
    expect(screen.getAllByText('$120.00').length).toBeGreaterThan(0)

    deferTargets = true
    const monthSelect = screen.getByLabelText('Guam calendar month')
    await userEvent.selectOptions(monthSelect, firstTarget)

    // While firstTarget is pending, previous month's $120.00 figures MUST NOT appear under the new heading
    expect(screen.getByRole('heading', { name: new RegExp(`${monthName(firstTarget)} ${year}`) })).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent(`Loading monthly CPA summary for ${monthName(firstTarget)} ${year}`)
    expect(screen.queryByText('Custodial liability (organizer proceeds)')).not.toBeInTheDocument()

    // Switch immediately to secondTarget before firstTarget resolves
    await userEvent.selectOptions(monthSelect, secondTarget)
    expect(screen.getByRole('heading', { name: new RegExp(`${monthName(secondTarget)} ${year}`) })).toBeInTheDocument()

    // secondTarget resolves first with $444.00
    const secondData = makeCpaMonthly(year, secondTarget)
    secondData.totals.closing_custodial_payables_cents = 44400
    secondData.totals.closing_custodial_liability_cents = 44400
    secondData.rows[0].closing_custodial_liability_cents = 44400
    resolveSecond({ data: secondData })
    expect(await screen.findAllByText('$444.00')).not.toHaveLength(0)

    // Stale firstTarget response arrives late with $333.00 — MUST be ignored
    const firstData = makeCpaMonthly(year, firstTarget)
    firstData.totals.closing_custodial_payables_cents = 33300
    firstData.totals.closing_custodial_liability_cents = 33300
    firstData.rows[0].closing_custodial_liability_cents = 33300
    resolveFirst({ data: firstData })
    await waitFor(() => {
      expect(screen.getAllByText('$444.00').length).toBeGreaterThan(0)
      expect(screen.queryByText('$333.00')).not.toBeInTheDocument()
    })
  })

  it('shows a retryable error instead of endless loading when the current CPA response has a mismatched period or missing totals', async () => {
    let returnBad = true
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports') return Promise.resolve({ data: report })
      if (url === '/admin/tax_reports/cpa_monthly') {
        if (returnBad) return Promise.resolve({ data: { period: '1999-01', totals: null } })
        return Promise.resolve({ data: makeCpaMonthly(cfg?.params?.year || year, cfg?.params?.month || currentMonth) })
      }
      return Promise.resolve({ data: report })
    })

    show()
    expect(await screen.findByRole('alert')).toHaveTextContent('Received an unexpected monthly CPA summary response')
    expect(screen.queryByText(/Loading monthly CPA summary/)).not.toBeInTheDocument()

    returnBad = false
    await userEvent.click(screen.getByRole('button', { name: 'Retry monthly CPA report' }))
    expect(await screen.findByText('Custodial liability (organizer proceeds)')).toBeInTheDocument()
  })

  it('keeps full TINs off the admin page', async () => {
    show()
    await screen.findByText('***-**-5678')
    expect(screen.queryByRole('button', { name: /reveal.*TIN/i })).not.toBeInTheDocument()
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
  })

  it('downloads masked CSV by GET and explicitly labelled 1099 CSV by audited POST', async () => {
    const blob = new Blob(['fixture'], { type: 'text/csv' })
    show()
    await screen.findByText('***-**-5678')
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports/cpa_monthly') return Promise.resolve({ data: makeCpaMonthly(cfg?.params?.year || year, cfg?.params?.month || currentMonth) })
      return Promise.resolve({ data: blob })
    })
    apiClient.post.mockResolvedValue({ data: blob })
    await userEvent.click(screen.getByRole('button', { name: 'Export masked CSV' }))
    await waitFor(() => expect(saveBlob).toHaveBeenCalledWith(blob, `hafapass-organizers_export-${year}-masked.csv`))
    vi.spyOn(window, 'prompt').mockReturnValue('CPA filing preparation')
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    await userEvent.click(screen.getByRole('button', { name: 'Export full TINs for 1099 preparation (audited)' }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/tax_reports/preparation_export', { year, include_full_tins: true, purpose: 'CPA filing preparation' }, expect.objectContaining({ responseType: 'blob' })))
    vi.restoreAllMocks()
    await userEvent.click(screen.getByRole('button', { name: 'Export gross receipts CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/admin/tax_reports/receipts_export', expect.objectContaining({ responseType: 'blob' }))
  })

  it('downloads both the monthly CPA custodial CSV and event-level BPT CSV for the selected Guam month', async () => {
    const blob = new Blob(['row_type,month'], { type: 'text/csv' })
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports') return Promise.resolve({ data: { ...report, year: Number(cfg?.params?.year || year) } })
      if (url === '/admin/tax_reports/cpa_monthly') return Promise.resolve({ data: makeCpaMonthly(cfg?.params?.year || year, cfg?.params?.month || currentMonth) })
      return Promise.resolve({ data: blob })
    })
    show()
    await screen.findByRole('button', { name: 'Export monthly CPA CSV' })
    await userEvent.selectOptions(screen.getByLabelText('Calendar year'), String(year - 1))
    const month = await screen.findByLabelText('Guam calendar month')
    await userEvent.selectOptions(month, '03')

    await userEvent.click(screen.getByRole('button', { name: 'Export monthly CPA CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/admin/tax_reports/cpa_monthly_export', expect.objectContaining({
      params: { year: year - 1, month: '03' }, responseType: 'blob',
    }))
    expect(saveBlob).toHaveBeenCalledWith(blob, `hafapass-cpa-monthly-${year - 1}-03.csv`)

    await userEvent.click(screen.getByRole('button', { name: 'Export monthly BPT detail CSV' }))
    expect(apiClient.get).toHaveBeenCalledWith('/admin/tax_reports/bpt_events_export', expect.objectContaining({
      params: { year: year - 1, month: '03' }, responseType: 'blob',
    }))
    expect(saveBlob).toHaveBeenCalledWith(blob, `hafapass-bpt-events-${year - 1}-03.csv`)
  })

  it('shows cumulative unallocated-refund exception when current month is $0, renders prior-period labels, and marks pre-Apr 2018 BPT rate not supported', async () => {
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports') return Promise.resolve({ data: { ...report, year: Number(cfg?.params?.year || year) } })
      if (url === '/admin/tax_reports/cpa_monthly') {
        const data = makeCpaMonthly(cfg?.params?.year || year, cfg?.params?.month || currentMonth, {
          bpt_rate_bps: null,
          bpt_rate_pct: 'not_supported',
          bpt_rate_note: 'Periods before April 2018 are not supported for automatic Guam BPT estimation — confirm with CPA',
        })
        data.rows[0].unallocated_refunds_exception_cents = 0
        data.rows[0].cumulative_unallocated_refunds_exception_cents = 1500
        data.rows[0].reconciliation_exception_flag = true
        data.rows[0].reconciliation_exception_note = 'Unallocated legacy refunds: $15.00 cumulative ($0.00 in month)'
        data.rows[0].prior_period_note = 'Payout reversal relates to Oct 2026'
        data.rows[0].estimated_bpt_rate_pct = 'not_supported'
        data.rows[0].estimated_bpt_on_fee_revenue_estimate_cents = null
        data.totals.unallocated_refunds_exception_cents = 0
        data.totals.cumulative_unallocated_refunds_exception_cents = 1500
        data.totals.backup_withholding_memo_cents = -120
        data.totals.reconciliation_exception_flag = true
        data.totals.reconciliation_exception_note = 'Unallocated legacy refunds: $15.00 cumulative ($0.00 in month)'
        data.totals.estimated_bpt_rate_pct = 'not_supported'
        data.totals.estimated_bpt_on_fee_revenue_estimate_cents = null
        data.current_integrity_alerts = {
          as_of: 'current_at_export_time',
          excluded_from_closed_month_csv: true,
          has_alerts: true,
          summary: 'Reversed payout(s) missing reversal audit evidence ($90.00)',
        }
        return Promise.resolve({ data })
      }
      return Promise.resolve({ data: report })
    })

    show()
    expect(await screen.findByText(/Unallocated legacy refunds: \$15\.00 cumulative \(\$0\.00 in month\)/)).toBeInTheDocument()
    expect(screen.getByText(/Current ledger integrity alerts \(as of export — excluded from closed-month CSV\)/)).toBeInTheDocument()
    expect(screen.getByText(/Reversed payout\(s\) missing reversal audit evidence \(\$90\.00\)/)).toBeInTheDocument()
    expect(screen.getByText(/Net backup withholding memo \(paid minus reversed\): -\$1\.20/)).toBeInTheDocument()
    expect(screen.getAllByText(/Payout reversal relates to Oct 2026/).length).toBeGreaterThan(0)
    expect(screen.getByText('Not supported')).toBeInTheDocument()
    expect(screen.getByText(/W-9 \(current\) \/ DRT status/)).toBeInTheDocument()
  })

  it('shows recovery for failures and handles zero-activity months and empty annual reports', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('offline'))
    show()
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not load tax reports')
    apiClient.get.mockImplementation((url, cfg) => {
      if (url === '/admin/tax_reports/cpa_monthly') {
        const zero = makeCpaMonthly(cfg?.params?.year || year, cfg?.params?.month || currentMonth, { rows: [] })
        zero.totals = {
          ...zero.totals,
          w9_nonprofit_row_count: 0, nonprofit_exemption_note: '0 W-9 nonprofit row(s); DRT exemption not tracked',
          opening_custodial_liability_cents: 0, proceeds_collected_cents: 0, proceeds_refunded_cents: 0,
          chargebacks_cents: 0, organizer_payouts_made_cents: 0, payout_reversals_cents: 0,
          closing_custodial_liability_cents: 0, closing_custodial_payables_cents: 0, closing_organizer_deficits_cents: 0,
          reserve_held_cents: 0, reserve_released_cents: 0, ending_reserve_balance_cents: 0,
          fee_revenue_gross_cents: 0, fee_refunds_cents: 0, fee_revenue_net_cents: 0,
          stripe_processing_costs_cents: 0, bpt_base_fee_revenue_estimate_cents: 0,
          estimated_bpt_on_fee_revenue_estimate_cents: 0,
        }
        return Promise.resolve({ data: zero })
      }
      return Promise.resolve({ data: { ...report, organizers: [] } })
    })
    await userEvent.click(screen.getByRole('button', { name: 'Retry reports' }))
    expect(await screen.findByText('No live financial activity for this year.')).toBeInTheDocument()
    expect(await screen.findByText(/No live custodial or fee activity/)).toBeInTheDocument()
  })
})

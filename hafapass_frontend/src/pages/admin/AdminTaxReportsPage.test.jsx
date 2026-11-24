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
const year = Number(new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Guam', year: 'numeric' }).format(new Date()))
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
const cpaMonthly = {
  year,
  month: 10,
  period: `${year}-10`,
  timezone: 'Pacific/Guam',
  currency: 'usd',
  bpt_rate_bps: 400,
  bpt_rate_pct: '4.00',
  bpt_rate_note: '4.00% statutory general BPT estimate (11 GCA § 26202; excludes § 26203.2 small-business relief — confirm with CPA)',
  note: 'Preparation aid only.',
  rows: [{
    organization_id: 7, event_id: 42, nonprofit_exempt_flag: true, nonprofit_exemption_note: 'W-9 nonprofit; verify DRT exemption',
    opening_custodial_liability_cents: 10000, proceeds_collected_cents: 50000, proceeds_refunded_cents: 2000,
    chargebacks_cents: 1000, organizer_processing_deducted_cents: 0, other_adjustments_cents: 0,
    organizer_payouts_made_cents: 45000, closing_custodial_liability_cents: 12000,
    reserve_held_cents: 5000, reserve_released_cents: 0, ending_reserve_balance_cents: 5000,
    backup_withholding_memo_cents: 0, fee_revenue_gross_cents: 3500, fee_refunds_cents: 250,
    fee_revenue_net_cents: 3250, stripe_processing_costs_cents: 1650,
    bpt_base_fee_revenue_estimate_cents: 3250, estimated_bpt_rate_pct: '4.00',
    estimated_bpt_on_fee_revenue_estimate_cents: 130,
  }],
  totals: {
    nonprofit_event_count: 1, nonprofit_exemption_note: '1 nonprofit-flagged row(s)',
    opening_custodial_liability_cents: 10000, proceeds_collected_cents: 50000, proceeds_refunded_cents: 2000,
    chargebacks_cents: 1000, organizer_processing_deducted_cents: 0, other_adjustments_cents: 0,
    organizer_payouts_made_cents: 45000, closing_custodial_liability_cents: 12000,
    reserve_held_cents: 5000, reserve_released_cents: 0, ending_reserve_balance_cents: 5000,
    backup_withholding_memo_cents: 0, fee_revenue_gross_cents: 3500, fee_refunds_cents: 250,
    fee_revenue_net_cents: 3250, stripe_processing_costs_cents: 1650,
    bpt_base_fee_revenue_estimate_cents: 3250, estimated_bpt_rate_pct: '4.00',
    estimated_bpt_on_fee_revenue_estimate_cents: 130,
  },
}
const show = () => render(<MemoryRouter initialEntries={['/admin/tax-reports']}><AdminTaxReportsPage /></MemoryRouter>)

describe('AdminTaxReportsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockImplementation(url => {
      if (url === '/admin/tax_reports/cpa_monthly') return Promise.resolve({ data: cpaMonthly })
      return Promise.resolve({ data: report })
    })
  })

  it('shows masked identities, custodial vs fee revenue summary, nonprofit flag, and accountant note', async () => {
    show()
    expect(await screen.findByText('***-**-5678')).toBeInTheDocument()
    expect(screen.getByText(/Live-mode USD payments only/)).toBeInTheDocument()
    expect(screen.getByText(report.note)).toBeInTheDocument()
    expect(screen.getByText('$1.25')).toBeInTheDocument()
    expect(await screen.findByText('Custodial liability (organizer proceeds)')).toBeInTheDocument()
    expect(screen.getByText('HåfaPass fee revenue & Guam BPT estimate')).toBeInTheDocument()
    expect(screen.getByText('Nonprofit (W-9)')).toBeInTheDocument()
    expect(screen.getAllByText('$120.00').length).toBeGreaterThan(0)
    expect(screen.getAllByText('$1.30').length).toBeGreaterThan(0)
    expect(screen.queryByText('012345678')).not.toBeInTheDocument()
    await userEvent.selectOptions(screen.getByLabelText('Calendar year'), String(year - 1))
    await waitFor(() => expect(apiClient.get).toHaveBeenCalledWith('/admin/tax_reports', expect.objectContaining({ params: { year: String(year - 1) } })))
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
    apiClient.get.mockImplementation(url => {
      if (url === '/admin/tax_reports/cpa_monthly') return Promise.resolve({ data: cpaMonthly })
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
      if (url === '/admin/tax_reports/cpa_monthly') return Promise.resolve({ data: cpaMonthly })
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

  it('shows recovery for failures and handles zero-activity months and empty annual reports', async () => {
    apiClient.get.mockRejectedValueOnce(new Error('offline'))
    show()
    expect(await screen.findByRole('alert')).toHaveTextContent('Could not load tax reports')
    apiClient.get.mockImplementation(url => {
      if (url === '/admin/tax_reports/cpa_monthly') {
        return Promise.resolve({
          data: {
            ...cpaMonthly,
            rows: [],
            totals: {
              ...cpaMonthly.totals,
              nonprofit_event_count: 0, nonprofit_exemption_note: '0 nonprofit-flagged row(s)',
              opening_custodial_liability_cents: 0, proceeds_collected_cents: 0, proceeds_refunded_cents: 0,
              chargebacks_cents: 0, organizer_payouts_made_cents: 0, closing_custodial_liability_cents: 0,
              reserve_held_cents: 0, reserve_released_cents: 0, ending_reserve_balance_cents: 0,
              fee_revenue_gross_cents: 0, fee_refunds_cents: 0, fee_revenue_net_cents: 0,
              stripe_processing_costs_cents: 0, bpt_base_fee_revenue_estimate_cents: 0,
              estimated_bpt_on_fee_revenue_estimate_cents: 0,
            },
          },
        })
      }
      return Promise.resolve({ data: { ...report, organizers: [] } })
    })
    await userEvent.click(screen.getByRole('button', { name: 'Retry reports' }))
    expect(await screen.findByText('No live financial activity for this year.')).toBeInTheDocument()
    expect(await screen.findByText(/No live custodial or fee activity/)).toBeInTheDocument()
  })
})

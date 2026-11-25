import { describe, expect, it } from 'vitest'
import { handle } from './cpa-export'

describe('cpa-export demo handler', () => {
  it('returns undefined for unrelated routes', async () => {
    expect(await handle({ method: 'get', path: '/admin/payouts', params: new URLSearchParams() })).toBeUndefined()
    expect(await handle({ method: 'post', path: '/admin/tax_reports', params: new URLSearchParams() })).toBeUndefined()
  })

  it('serves self-reconciling monthly custodial liability and BPT totals', async () => {
    const res = await handle({
      method: 'get',
      path: '/admin/tax_reports/cpa_monthly',
      params: new URLSearchParams('year=2026&month=11'),
    })
    expect(res.status).toBe(200)
    expect(res.data.rows.length).toBe(2)
    expect(res.data.rows.some(row => row.w9_nonprofit_classification)).toBe(true)
    expect(res.data.rows.every(row => row.drt_exemption_verified === 'not_tracked')).toBe(true)
    for (const row of [...res.data.rows, res.data.totals]) {
      const expectedClosing = row.opening_custodial_liability_cents +
        row.proceeds_collected_cents -
        row.proceeds_refunded_cents -
        row.chargebacks_cents -
        row.organizer_processing_deducted_cents +
        row.other_adjustments_cents -
        row.organizer_payouts_made_cents +
        row.payout_reversals_cents
      expect(row.closing_custodial_liability_cents).toBe(expectedClosing)
      expect(row.closing_buyer_refunds_owed_cents).toBe(
        row.opening_buyer_refunds_owed_cents + row.buyer_refund_captures_cents - row.buyer_refunds_paid_cents,
      )
    }
    expect(res.data.totals.closing_buyer_refunds_owed_cents).toBe(1700)
    expect(res.data.totals.closing_custodial_payables_cents - res.data.totals.closing_organizer_deficits_cents)
      .toBe(res.data.totals.closing_custodial_liability_cents)
  })

  it('serves a zero-activity month for February and exports a CSV blob with totals row', async () => {
    const feb = await handle({
      method: 'get',
      path: '/admin/tax_reports/cpa_monthly',
      params: new URLSearchParams('year=2026&month=02'),
    })
    expect(feb.status).toBe(200)
    expect(feb.data.rows).toEqual([])
    expect(feb.data.totals.closing_custodial_liability_cents).toBe(0)

    const csv = await handle({
      method: 'get',
      path: '/admin/tax_reports/cpa_monthly_export',
      params: new URLSearchParams('year=2026&month=02'),
    })
    expect(csv.status).toBe(200)
    const text = await new Promise((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(String(reader.result))
      reader.onerror = reject
      reader.readAsText(csv.data)
    })
    expect(text).toContain('"row_type","month","organization_id"')
    expect(text).toContain('"cumulative_unallocated_refunds_exception"')
    expect(text).toContain('"prior_period_note"')
    expect(text).toContain('"closing_organizer_deficits","opening_buyer_refunds_owed","buyer_refund_captures","buyer_refunds_paid","closing_buyer_refunds_owed","reserve_held"')
    expect(text).toContain('"total","2026-02"')

    const pre2018 = await handle({
      method: 'get',
      path: '/admin/tax_reports/cpa_monthly',
      params: new URLSearchParams('year=2017&month=12'),
    })
    expect(pre2018.status).toBe(200)
    expect(pre2018.data.bpt_rate_bps).toBeNull()
    expect(pre2018.data.bpt_rate_pct).toBe('not_supported')
    expect(pre2018.data.totals.estimated_bpt_on_fee_revenue_estimate_cents).toBeNull()
  })

  it('rejects invalid months', async () => {
    const bad = await handle({
      method: 'get',
      path: '/admin/tax_reports/cpa_monthly',
      params: new URLSearchParams('year=2026&month=13'),
    })
    expect(bad.status).toBe(422)
  })
})

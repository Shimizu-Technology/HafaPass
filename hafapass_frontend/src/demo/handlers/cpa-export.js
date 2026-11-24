// Preview-only demo handler for Admin -> Tax reports and the monthly CPA
// custodial & BPT export. All organizations, figures and identifiers are
// fictional (see ../README.md).
import { json, unprocessable } from './respond'
import { DEMO_ORG_ID, DEMO_ORGANIZATION } from '../staff/fixtures'

export const DEMO_CPA_EXPORT_SENTINEL = 'HAFAPASS_DEMO_CPA_EXPORT_SENTINEL'

const CSV_HEADER = [
  'row_type', 'month', 'organization_id', 'event_id', 'w9_nonprofit_classification', 'drt_exemption_verified',
  'nonprofit_exemption_note', 'opening_custodial_liability', 'proceeds_collected', 'proceeds_refunded', 'chargebacks',
  'organizer_processing_deducted', 'other_adjustments', 'organizer_payouts_made', 'payout_reversals',
  'closing_custodial_liability', 'closing_custodial_payables', 'closing_organizer_deficits',
  'reserve_held', 'reserve_released', 'ending_reserve_balance',
  'unallocated_refunds_exception', 'reconciliation_exception_flag', 'non_custodial_settlement_bridge',
  'backup_withholding_memo', 'fee_revenue_gross', 'fee_refunds', 'fee_revenue_net',
  'stripe_processing_costs_informational', 'bpt_base_fee_revenue_estimate', 'estimated_bpt_rate_pct',
  'estimated_bpt_on_fee_revenue_estimate', 'currency',
]

const BPT_HEADER = [
  'month', 'organization_id', 'event_id', 'gross_service_fees', 'refunded_service_fees',
  'net_service_fees', 'stripe_processing_fees_informational', 'ticket_face_value_collected_as_agent',
  'organizer_payouts', 'currency',
]

const fmt = cents => `${cents < 0 ? '-' : ''}${Math.floor(Math.abs(cents) / 100)}.${String(Math.abs(cents) % 100).padStart(2, '0')}`
const csvCell = value => `"${String(value ?? '').replaceAll('"', '""')}"`
const csvLine = values => `${values.map(csvCell).join(',')}\n`

function bptRateBps(year, month) {
  if (year > 2026 || (year === 2026 && month >= 10)) return 400
  if (year > 2025 || (year === 2025 && month >= 10)) return 450
  return 500
}

function estimateBpt(baseCents, rateBps) {
  if (baseCents <= 0) return 0
  return Math.floor((baseCents * rateBps + 5000) / 10000)
}

function buildDemoCpaMonthly(year, month) {
  const rateBps = bptRateBps(year, month)
  const ratePct = (rateBps / 100).toFixed(2)
  const period = `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}`
  const rateNote = (year > 2025 || (year === 2025 && month >= 10))
    ? `${ratePct}% statutory § 26202(c) service-business BPT estimate (P.L. 38-136; excludes § 26203.2 small-business relief — confirm with CPA)`
    : `${ratePct}% pre-P.L. 38-136 historical BPT estimate (prior 11 GCA § 26202; confirm applicable rate with CPA)`

  // Month 2 (February) intentionally demonstrates a zero-activity month.
  const rows = month === 2 ? [] : [
    {
      organization_id: DEMO_ORG_ID,
      event_id: 101,
      w9_nonprofit_classification: true,
      drt_exemption_verified: 'not_tracked',
      nonprofit_exemption_note: 'W-9 nonprofit; DRT exemption not tracked — verify externally',
      opening_custodial_liability_cents: 125000,
      proceeds_collected_cents: 1204000,
      proceeds_refunded_cents: 24000,
      chargebacks_cents: 1700,
      organizer_processing_deducted_cents: 0,
      other_adjustments_cents: 0,
      organizer_payouts_made_cents: 1080000,
      payout_reversals_cents: 0,
      closing_custodial_liability_cents: 223300,
      closing_custodial_payables_cents: 223300,
      closing_organizer_deficits_cents: 0,
      reserve_held_cents: 120400,
      reserve_released_cents: 125000,
      ending_reserve_balance_cents: 120400,
      unallocated_refunds_exception_cents: 0,
      reconciliation_exception_flag: false,
      non_custodial_settlement_bridge_cents: 0,
      backup_withholding_memo_cents: 0,
      fee_revenue_gross_cents: 142300,
      fee_refunds_cents: 2600,
      fee_revenue_net_cents: 139700,
      stripe_processing_costs_cents: 41200,
      bpt_base_fee_revenue_estimate_cents: 139700,
      estimated_bpt_rate_pct: ratePct,
      estimated_bpt_on_fee_revenue_estimate_cents: estimateBpt(139700, rateBps),
    },
    {
      organization_id: 9002,
      event_id: 102,
      w9_nonprofit_classification: false,
      drt_exemption_verified: 'not_tracked',
      nonprofit_exemption_note: '',
      opening_custodial_liability_cents: 0,
      proceeds_collected_cents: 508000,
      proceeds_refunded_cents: 12000,
      chargebacks_cents: 0,
      organizer_processing_deducted_cents: 0,
      other_adjustments_cents: 0,
      organizer_payouts_made_cents: 446400,
      payout_reversals_cents: 0,
      closing_custodial_liability_cents: 49600,
      closing_custodial_payables_cents: 49600,
      closing_organizer_deficits_cents: 0,
      reserve_held_cents: 49600,
      reserve_released_cents: 0,
      ending_reserve_balance_cents: 49600,
      unallocated_refunds_exception_cents: 0,
      reconciliation_exception_flag: false,
      non_custodial_settlement_bridge_cents: 0,
      backup_withholding_memo_cents: 0,
      fee_revenue_gross_cents: 61000,
      fee_refunds_cents: 1500,
      fee_revenue_net_cents: 59500,
      stripe_processing_costs_cents: 17900,
      bpt_base_fee_revenue_estimate_cents: 59500,
      estimated_bpt_rate_pct: ratePct,
      estimated_bpt_on_fee_revenue_estimate_cents: estimateBpt(59500, rateBps),
    },
  ]

  const sum = key => rows.reduce((total, row) => total + (row[key] || 0), 0)
  const nonprofitCount = rows.filter(row => row.w9_nonprofit_classification).length
  const totalBptBase = sum('bpt_base_fee_revenue_estimate_cents')
  const orgClosing = rows.reduce((map, row) => {
    map.set(row.organization_id, (map.get(row.organization_id) || 0) + row.closing_custodial_liability_cents)
    return map
  }, new Map())
  const closingPayables = [...orgClosing.values()].reduce((acc, v) => acc + Math.max(v, 0), 0)
  const closingDeficits = [...orgClosing.values()].reduce((acc, v) => acc + Math.max(-v, 0), 0)

  return {
    year,
    month,
    period,
    timezone: 'Pacific/Guam',
    currency: 'usd',
    bpt_rate_bps: rateBps,
    bpt_rate_pct: ratePct,
    bpt_rate_note: rateNote,
    note: 'Preparation aid only — not a filed return. Demo preview data; all figures and entities are fictional.',
    demo_marker: DEMO_CPA_EXPORT_SENTINEL,
    rows,
    totals: {
      organization_id: null,
      event_id: null,
      w9_nonprofit_classification: null,
      drt_exemption_verified: 'not_tracked',
      w9_nonprofit_row_count: nonprofitCount,
      nonprofit_exemption_note: `${nonprofitCount} W-9 nonprofit row(s); DRT exemption not tracked`,
      opening_custodial_liability_cents: sum('opening_custodial_liability_cents'),
      proceeds_collected_cents: sum('proceeds_collected_cents'),
      proceeds_refunded_cents: sum('proceeds_refunded_cents'),
      chargebacks_cents: sum('chargebacks_cents'),
      organizer_processing_deducted_cents: sum('organizer_processing_deducted_cents'),
      other_adjustments_cents: sum('other_adjustments_cents'),
      organizer_payouts_made_cents: sum('organizer_payouts_made_cents'),
      payout_reversals_cents: sum('payout_reversals_cents'),
      closing_custodial_liability_cents: sum('closing_custodial_liability_cents'),
      closing_custodial_payables_cents: closingPayables,
      closing_organizer_deficits_cents: closingDeficits,
      reserve_held_cents: sum('reserve_held_cents'),
      reserve_released_cents: sum('reserve_released_cents'),
      ending_reserve_balance_cents: sum('ending_reserve_balance_cents'),
      unallocated_refunds_exception_cents: sum('unallocated_refunds_exception_cents'),
      reconciliation_exception_count: 0,
      reconciliation_exception_flag: false,
      non_custodial_settlement_bridge_cents: sum('non_custodial_settlement_bridge_cents'),
      backup_withholding_memo_cents: sum('backup_withholding_memo_cents'),
      fee_revenue_gross_cents: sum('fee_revenue_gross_cents'),
      fee_refunds_cents: sum('fee_refunds_cents'),
      fee_revenue_net_cents: sum('fee_revenue_net_cents'),
      stripe_processing_costs_cents: sum('stripe_processing_costs_cents'),
      bpt_base_fee_revenue_estimate_cents: totalBptBase,
      estimated_bpt_rate_pct: ratePct,
      estimated_bpt_on_fee_revenue_estimate_cents: estimateBpt(totalBptBase, rateBps),
    },
  }
}

function buildDemoAnnualReport(year) {
  return {
    year,
    timezone: 'Pacific/Guam',
    currency: 'usd',
    note: "HåfaPass's gross receipts are its service fees; ticket proceeds belong to organizers (agent model). Confirm with your accountant.",
    demo_marker: DEMO_CPA_EXPORT_SENTINEL,
    organizers: [
      {
        organization_id: DEMO_ORG_ID,
        organization_name: `${DEMO_ORGANIZATION.name} (demo)`,
        tax_snapshot_status: 'W-9 snapshotted at payout',
        w9_on_file: true,
        current_w9_on_file: true,
        tax_snapshot_payout_id: 7001,
        tax_information: {
          legal_name: 'Isla Demo Sports League Inc. (demo)',
          tax_classification: 'nonprofit',
          masked_tin: '***-**-4321',
        },
        gross_ticket_proceeds_cents: 1204000,
        gross_add_on_proceeds_cents: 45000,
        gross_donation_proceeds_cents: 15000,
        gross_other_proceeds_cents: 0,
        gross_non_ticket_proceeds_cents: 60000,
        ticket_refunds_cents: 24000,
        non_ticket_refunds_cents: 0,
        unallocated_refunds_cents: 0,
        fee_refunds_cents: 2600,
        fees_collected_cents: 142300,
        reconciliation_adjustments_cents: -120400,
        net_paid_cents: 1080000,
      },
      {
        organization_id: 9002,
        organization_name: 'Coral Lantern Studio (demo)',
        tax_snapshot_status: 'W-9 snapshotted at payout',
        w9_on_file: true,
        current_w9_on_file: true,
        tax_snapshot_payout_id: 7002,
        tax_information: {
          legal_name: 'Coral Lantern Studio LLC (demo)',
          tax_classification: 'llc_c',
          masked_tin: '***-**-4329',
        },
        gross_ticket_proceeds_cents: 508000,
        gross_add_on_proceeds_cents: 0,
        gross_donation_proceeds_cents: 0,
        gross_other_proceeds_cents: 0,
        gross_non_ticket_proceeds_cents: 0,
        ticket_refunds_cents: 12000,
        non_ticket_refunds_cents: 0,
        unallocated_refunds_cents: 0,
        fee_refunds_cents: 1500,
        fees_collected_cents: 61000,
        reconciliation_adjustments_cents: -49600,
        net_paid_cents: 446400,
      },
    ],
    months: Array.from({ length: 12 }, (_, idx) => {
      const m = idx + 1
      if (m === 2) return { month: m, fees_collected_cents: 0, fees_refunded_cents: 0, gross_receipts_cents: 0, card_processing_costs_cents: 0 }
      const collected = m === 11 ? 203300 : 84500
      const refunded = m === 11 ? 4100 : 1200
      return { month: m, fees_collected_cents: collected, fees_refunded_cents: refunded, gross_receipts_cents: collected - refunded, card_processing_costs_cents: Math.round(collected * 0.29) }
    }),
  }
}

function buildCpaCsv(data) {
  const rowToCsv = (rowType, row) => csvLine([
    rowType,
    data.period,
    row.organization_id ?? '',
    row.event_id ?? '',
    row.w9_nonprofit_classification === true ? 'yes' : row.w9_nonprofit_classification === false ? 'no' : '',
    row.drt_exemption_verified || 'not_tracked',
    row.nonprofit_exemption_note || '',
    fmt(row.opening_custodial_liability_cents),
    fmt(row.proceeds_collected_cents),
    fmt(row.proceeds_refunded_cents),
    fmt(row.chargebacks_cents),
    fmt(row.organizer_processing_deducted_cents),
    fmt(row.other_adjustments_cents),
    fmt(row.organizer_payouts_made_cents),
    fmt(row.payout_reversals_cents),
    fmt(row.closing_custodial_liability_cents),
    fmt(row.closing_custodial_payables_cents),
    fmt(row.closing_organizer_deficits_cents),
    fmt(row.reserve_held_cents),
    fmt(row.reserve_released_cents),
    fmt(row.ending_reserve_balance_cents),
    fmt(row.unallocated_refunds_exception_cents),
    row.reconciliation_exception_flag ? 'yes' : 'no',
    fmt(row.non_custodial_settlement_bridge_cents),
    fmt(row.backup_withholding_memo_cents),
    fmt(row.fee_revenue_gross_cents),
    fmt(row.fee_refunds_cents),
    fmt(row.fee_revenue_net_cents),
    fmt(row.stripe_processing_costs_cents),
    fmt(row.bpt_base_fee_revenue_estimate_cents),
    row.estimated_bpt_rate_pct,
    fmt(row.estimated_bpt_on_fee_revenue_estimate_cents),
    'USD',
  ])
  return [
    csvLine(CSV_HEADER),
    ...data.rows.map(row => rowToCsv('event', row)),
    rowToCsv('total', data.totals),
  ].join('')
}

function buildBptCsv(data) {
  return [
    csvLine(BPT_HEADER),
    ...data.rows.map(row => csvLine([
      data.period, row.organization_id, row.event_id,
      fmt(row.fee_revenue_gross_cents), fmt(row.fee_refunds_cents), fmt(row.fee_revenue_net_cents),
      fmt(row.stripe_processing_costs_cents), fmt(row.proceeds_collected_cents), fmt(row.organizer_payouts_made_cents),
      'USD',
    ])),
  ].join('')
}

function csvResponse(text) {
  return { status: 200, data: new Blob([text], { type: 'text/csv;charset=utf-8' }) }
}

export async function handle({ method, path, params }) {
  if (method === 'get' && path === '/admin/tax_reports') {
    const year = Number(params.get('year')) || 2026
    return json(buildDemoAnnualReport(year))
  }

  if (method === 'get' && (path === '/admin/tax_reports/cpa_monthly' || path === '/admin/tax_reports/cpa_monthly_export' || path === '/admin/tax_reports/bpt_events_export')) {
    const year = Number(params.get('year')) || 2026
    const monthRaw = params.get('month') || '11'
    const month = Number(monthRaw)
    if (!Number.isInteger(month) || month < 1 || month > 12) {
      return unprocessable('Choose a month from 1 to 12')
    }
    const data = buildDemoCpaMonthly(year, month)
    if (path === '/admin/tax_reports/cpa_monthly') return json(data)
    if (path === '/admin/tax_reports/cpa_monthly_export') return csvResponse(buildCpaCsv(data))
    return csvResponse(buildBptCsv(data))
  }

  if (method === 'get' && path === '/admin/tax_reports/receipts_export') {
    const year = Number(params.get('year')) || 2026
    const report = buildDemoAnnualReport(year)
    const lines = [
      csvLine(['month', 'service_fees_collected', 'service_fees_refunded', 'gross_receipts', 'card_processing_costs', 'currency']),
      ...report.months.map(row => csvLine([
        `${year}-${String(row.month).padStart(2, '0')}`,
        fmt(row.fees_collected_cents), fmt(row.fees_refunded_cents),
        fmt(row.gross_receipts_cents), fmt(row.card_processing_costs_cents), 'USD',
      ])),
    ]
    return csvResponse(lines.join(''))
  }

  if (method === 'get' && path === '/admin/tax_reports/organizers_export') {
    const year = Number(params.get('year')) || 2026
    const report = buildDemoAnnualReport(year)
    const lines = [
      csvLine(['organization', 'legal_name', 'classification', 'masked_tin', 'net_paid', 'currency']),
      ...report.organizers.map(row => csvLine([
        row.organization_name, row.tax_information.legal_name, row.tax_information.tax_classification,
        row.tax_information.masked_tin, fmt(row.net_paid_cents), 'USD',
      ])),
    ]
    return csvResponse(lines.join(''))
  }

  return undefined
}

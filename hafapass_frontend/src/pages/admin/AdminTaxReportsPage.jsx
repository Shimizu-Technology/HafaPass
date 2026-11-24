import { useCallback, useEffect, useRef, useState } from 'react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../../hooks/usePlatformContext'
import { taxClassificationLabel } from '../../utils/taxInformation'
import { saveBlob } from '../../utils/download'

const guamCalendar = new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit' })
const monthLabels = Array.from({ length: 12 }, (_, index) =>
  new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', month: 'long' }).format(Date.UTC(2000, index, 1)),
)
const money = cents => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format((cents || 0) / 100)

function SummaryRow({ label, value, emphasis = false, hint = null }) {
  return <div className={`flex items-baseline justify-between gap-3 py-1.5 ${emphasis ? 'border-t border-neutral-200 pt-2.5 font-semibold text-neutral-950' : 'text-neutral-800'}`}>
    <dt className="min-w-0 [overflow-wrap:anywhere]">
      <span>{label}</span>
      {hint && <span className="block text-xs font-normal text-content-muted">{hint}</span>}
    </dt>
    <dd className="shrink-0 tabular-nums font-medium">{value}</dd>
  </div>
}

function CpaMonthlyPanel({ cpaMonthly, cpaLoading, cpaError, onRetry, year, month, busy, onExport }) {
  const expectedPeriod = `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}`
  const periodMatches = cpaMonthly?.period === expectedPeriod && Boolean(cpaMonthly?.totals)
  const totals = periodMatches ? cpaMonthly.totals : null
  const rows = periodMatches && Array.isArray(cpaMonthly?.rows) ? cpaMonthly.rows : []
  const periodLabel = `${monthLabels[Math.max(Number(month) - 1, 0)] || month} ${year}`
  const refundsAndDisputes = (totals?.proceeds_refunded_cents || 0) + (totals?.chargebacks_cents || 0)
  const cumulativeUnalloc = totals?.cumulative_unallocated_refunds_exception_cents ?? totals?.unallocated_refunds_exception_cents ?? 0
  const inMonthUnalloc = totals?.unallocated_refunds_exception_cents ?? 0
  const missingRevAudit = totals?.missing_reversal_audit_exception_cents ?? 0
  const rateUnsupported = cpaMonthly?.bpt_rate_pct === 'not_supported' || cpaMonthly?.bpt_rate_bps === null
  const priorPeriodRows = rows.filter(row => row.prior_period_note)

  return <section aria-labelledby="cpa-monthly-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6">
    <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
      <div className="min-w-0">
        <h2 id="cpa-monthly-heading" className="text-lg font-semibold text-neutral-900">Monthly CPA custodial &amp; BPT report · {periodLabel}</h2>
        <p className="mt-1 text-sm text-neutral-700">Recording-time period-stable monthly workpaper separating organizer proceeds held in custody (a liability) from HåfaPass service-fee revenue, with Guam BPT estimates and current-at-export W-9 nonprofit flags (DRT verification is external). Identifies organizations and events by ID only (no PII).</p>
      </div>
    </div>

    <div className="mt-4 flex flex-wrap items-end gap-3">
      <label className="block min-w-44 text-sm font-medium text-neutral-900">Guam calendar month
        <select className="input mt-1 min-h-11" value={month} disabled={busy} onChange={onExport.onMonthChange}>
          {monthLabels.map((label, index) => <option key={label} value={String(index + 1).padStart(2, '0')}>{label}</option>)}
        </select>
      </label>
      <button type="button" disabled={busy} className="btn-primary min-h-11" onClick={() => onExport.download('cpa_monthly_export')}>Export monthly CPA CSV</button>
      <button type="button" disabled={busy} className="btn-secondary min-h-11" onClick={() => onExport.download('bpt_events_export')}>Export monthly BPT detail CSV</button>
    </div>

    {cpaError && <p role="alert" className="mt-4 text-sm text-red-800">{cpaError} <button type="button" className="min-h-11 underline" onClick={onRetry}>Retry monthly CPA report</button></p>}
    {!cpaError && (!periodMatches || cpaLoading) && <p role="status" className="mt-4 text-sm text-content-muted">Loading monthly CPA summary for {periodLabel}…</p>}

    {totals && <>
      {totals.reconciliation_exception_flag && <div role="status" className="mt-4 space-y-1 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-950">
        <p className="font-medium">Reconciliation exception requires manual review</p>
        {totals.reconciliation_exception_note
          ? <p>{totals.reconciliation_exception_note}</p>
          : <>
            {cumulativeUnalloc > 0 && <p>{money(cumulativeUnalloc)} in cumulative unallocated legacy refunds ({money(inMonthUnalloc)} in month) requires manual review between organizer proceeds and fee refunds.</p>}
            {missingRevAudit > 0 && <p>{money(missingRevAudit)} in reversed payouts is missing append-only reversal audit evidence.</p>}
          </>}
      </div>}

      {priorPeriodRows.length > 0 && <div role="status" className="mt-3 rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-sm text-sky-950">
        <p className="font-medium">Prior-period movements recorded in {periodLabel} (earlier closed months remain unchanged)</p>
        <ul className="mt-1 list-disc pl-5 text-xs">
          {priorPeriodRows.map((row, idx) => <li key={`${row.organization_id}:${row.event_id ?? idx}`}>
            Org #{row.organization_id} · {row.event_id ? `Event #${row.event_id}` : 'Org adj.'}: {row.prior_period_note}
          </li>)}
        </ul>
      </div>}

      <div className="mt-5 grid grid-cols-1 gap-4 lg:grid-cols-2">
        <div className="rounded-xl border border-neutral-200 bg-neutral-50/70 p-4">
          <p className="text-xs font-semibold uppercase tracking-wide text-neutral-600">Balance sheet · not HåfaPass revenue</p>
          <h3 className="mt-1 text-base font-semibold text-neutral-900">Custodial liability (organizer proceeds)</h3>
          <dl className="mt-3 text-sm">
            <SummaryRow label="Opening custodial liability" value={money(totals.opening_custodial_liability_cents)} />
            <SummaryRow label="Proceeds collected" value={money(totals.proceeds_collected_cents)} />
            <SummaryRow label="Refunds & chargebacks" value={money(-refundsAndDisputes)} hint={`Refunds ${money(totals.proceeds_refunded_cents)} · Chargebacks ${money(totals.chargebacks_cents)}`} />
            {totals.organizer_processing_deducted_cents !== 0 && <SummaryRow label="Organizer-borne processing" value={money(-totals.organizer_processing_deducted_cents)} />}
            {totals.other_adjustments_cents !== 0 && <SummaryRow label="Other balance adjustments" value={money(totals.other_adjustments_cents)} />}
            <SummaryRow label="Organizer payouts made" value={money(-totals.organizer_payouts_made_cents)} hint={totals.backup_withholding_memo_cents > 0 ? `Includes ${money(totals.backup_withholding_memo_cents)} backup withholding memo` : null} />
            {totals.payout_reversals_cents !== 0 && <SummaryRow label="Payout reversals (restored to custody)" value={money(totals.payout_reversals_cents)} />}
            <SummaryRow label="Closing custodial payables (owed to organizers)" value={money(totals.closing_custodial_payables_cents)} hint="Offset within same organization only; never nets unrelated organizers" emphasis />
            <SummaryRow label="Organizer deficits / receivables (owed to HåfaPass)" value={money(totals.closing_organizer_deficits_cents)} />
            <SummaryRow label="Net custodial roll-forward (payables − deficits)" value={money(totals.closing_custodial_liability_cents)} />
            {totals.non_custodial_settlement_bridge_cents !== 0 && <SummaryRow label="Non-custodial settlement bridge (e.g. Clover)" value={money(totals.non_custodial_settlement_bridge_cents)} hint="In settlement statements, excluded from HåfaPass custody" />}
          </dl>
          <div className="mt-3 rounded-lg border border-neutral-200 bg-white px-3 py-2 text-xs text-neutral-700">
            <p className="font-medium text-neutral-900">Chargeback reserve sub-ledger (part of closing liability)</p>
            <p className="mt-1 tabular-nums">Held in month: {money(totals.reserve_held_cents)} · Released: {money(totals.reserve_released_cents)} · Ending reserve: <strong>{money(totals.ending_reserve_balance_cents)}</strong></p>
          </div>
        </div>

        <div className="rounded-xl border border-neutral-200 bg-neutral-50/70 p-4">
          <p className="text-xs font-semibold uppercase tracking-wide text-neutral-600">Income statement · Shimizu Technology LLC</p>
          <h3 className="mt-1 text-base font-semibold text-neutral-900">HåfaPass fee revenue &amp; Guam BPT estimate</h3>
          <dl className="mt-3 text-sm">
            <SummaryRow label="Fee revenue (gross)" value={money(totals.fee_revenue_gross_cents)} />
            <SummaryRow label="Fee refunds" value={money(-totals.fee_refunds_cents)} />
            <SummaryRow label="Fee revenue (net)" value={money(totals.fee_revenue_net_cents)} emphasis />
            <SummaryRow label="Stripe processing costs (informational)" value={money(totals.stripe_processing_costs_cents)} hint="Booked by recording time; does not reduce Guam BPT gross receipts" />
            <SummaryRow label="Estimated BPT base (net fees)" value={money(totals.bpt_base_fee_revenue_estimate_cents)} />
            <SummaryRow
              label={rateUnsupported ? 'Estimated Guam BPT (not supported pre-Apr 2018)' : `Estimated Guam BPT (${cpaMonthly.bpt_rate_pct}% estimate)`}
              value={rateUnsupported ? 'Not supported' : money(totals.estimated_bpt_on_fee_revenue_estimate_cents)}
              hint={rateUnsupported ? 'Confirm pre-April 2018 historical rate with CPA' : 'Working position estimate — confirm rate & any § 26203.2 relief with CPA'}
              emphasis
            />
          </dl>
          <p className="mt-3 text-xs text-content-muted">{cpaMonthly.bpt_rate_note}</p>
        </div>
      </div>

      <div className="mt-5">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-sm font-semibold text-neutral-900">Event breakdown (IDs only · no PII)</h3>
          {totals.w9_nonprofit_row_count > 0 && <span className="inline-flex items-center rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-900">{totals.w9_nonprofit_row_count} W-9 nonprofit row{totals.w9_nonprofit_row_count === 1 ? '' : 's'} (current at export) · DRT not tracked</span>}
        </div>
        {rows.length === 0 ? <p className="mt-2 text-sm text-content-muted">No live custodial or fee activity for {periodLabel}. Exporting CSV still provides the zeroed totals row for monthly filing records.</p>
          : <div className="mt-2 overflow-x-auto" tabIndex={0} role="region" aria-label="Monthly CPA event breakdown table">
            <table className="w-full text-left text-sm">
              <caption className="sr-only">Monthly custodial liability and HåfaPass fee revenue by organization ID and event ID for {periodLabel} in USD</caption>
              <thead>
                <tr className="border-b border-neutral-200 text-xs text-neutral-600">
                  {['Org / Event ID', 'W-9 (current) / DRT status', 'Opening liab.', 'Collected', 'Refunds', 'Chargebacks', 'Payouts', 'Reversals', 'Closing net', 'Ending reserve', 'Net fees', 'Est. BPT'].map(label => (
                    <th key={label} scope="col" className="whitespace-nowrap px-2 py-2 font-semibold">{label}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((row, idx) => <tr key={`${row.organization_id}:${row.event_id ?? `org-${idx}`}`} className="border-t border-neutral-200">
                  <th scope="row" className="whitespace-nowrap px-2 py-2 font-medium text-neutral-900">
                    Org #{row.organization_id} · {row.event_id ? `Event #${row.event_id}` : 'Org adj.'}
                    {row.prior_period_note && <span className="block text-xs font-normal text-sky-900">{row.prior_period_note}</span>}
                  </th>
                  <td className="whitespace-nowrap px-2 py-2">
                    {row.w9_nonprofit_classification
                      ? <span className="inline-flex rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900">W-9 nonprofit · DRT unverified</span>
                      : <span className="text-xs text-content-muted">Standard · DRT not tracked</span>}
                  </td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.opening_custodial_liability_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.proceeds_collected_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.proceeds_refunded_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.chargebacks_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.organizer_payouts_made_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.payout_reversals_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 font-medium tabular-nums">{money(row.closing_custodial_liability_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.ending_reserve_balance_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(row.fee_revenue_net_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{row.estimated_bpt_on_fee_revenue_estimate_cents == null ? '—' : money(row.estimated_bpt_on_fee_revenue_estimate_cents)}</td>
                </tr>)}
              </tbody>
              <tfoot>
                <tr className="border-t-2 border-neutral-300 bg-neutral-50 font-semibold text-neutral-950">
                  <th scope="row" className="whitespace-nowrap px-2 py-2">Totals</th>
                  <td className="whitespace-nowrap px-2 py-2 text-xs font-normal text-neutral-700">{totals.nonprofit_exemption_note}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.opening_custodial_liability_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.proceeds_collected_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.proceeds_refunded_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.chargebacks_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.organizer_payouts_made_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.payout_reversals_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.closing_custodial_liability_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.ending_reserve_balance_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{money(totals.fee_revenue_net_cents)}</td>
                  <td className="whitespace-nowrap px-2 py-2 tabular-nums">{totals.estimated_bpt_on_fee_revenue_estimate_cents == null ? '—' : money(totals.estimated_bpt_on_fee_revenue_estimate_cents)}</td>
                </tr>
              </tfoot>
            </table>
          </div>}
      </div>
    </>}
  </section>
}

function TaxReportsSession({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin/tax-reports')
  const today = guamCalendar.formatToParts(new Date())
  const currentYear = today.find(part => part.type === 'year').value
  const [year, setYear] = useState(currentYear)
  const [month, setMonth] = useState(() => today.find(part => part.type === 'month').value)
  const [report, setReport] = useState(null)
  const [error, setError] = useState(null)
  const [cpaMonthly, setCpaMonthly] = useState(null)
  const [cpaLoading, setCpaLoading] = useState(false)
  const [cpaError, setCpaError] = useState(null)
  const [busy, setBusy] = useState(false)
  const generation = useRef(0)
  const cpaGeneration = useRef(0)

  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    const epoch = ++generation.current
    setReport(null); setError(null); setCpaMonthly(null); setCpaError(null)
    try {
      const response = await apiClient.get('/admin/tax_reports', { ...request.config, params: { year } })
      if (request.current() && epoch === generation.current) setReport(response.data)
    } catch (e) {
      if (request.current() && epoch === generation.current && !request.handleError(e)) setError('Could not load tax reports. Please retry.')
    } finally { request.release() }
  }, [beginRequest, year])

  const loadCpaMonthly = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    const epoch = ++cpaGeneration.current
    const targetPeriod = `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}`
    setCpaMonthly(null); setCpaLoading(true); setCpaError(null)
    try {
      const response = await apiClient.get('/admin/tax_reports/cpa_monthly', { ...request.config, params: { year, month } })
      if (request.current() && epoch === cpaGeneration.current) {
        const data = response.data
        setCpaMonthly(data?.totals && data.period === targetPeriod ? data : null)
      }
    } catch (e) {
      if (request.current() && epoch === cpaGeneration.current && !request.handleError(e)) {
        setCpaMonthly(null)
        setCpaError('Could not load monthly CPA summary. Please retry.')
      }
    } finally {
      if (request.current() && epoch === cpaGeneration.current) setCpaLoading(false)
      request.release()
    }
  }, [beginRequest, year, month])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    if (report?.year && String(report.year) === String(year)) loadCpaMonthly()
  }, [report?.year, year, loadCpaMonthly])

  const action = async kind => {
    let purpose
    if (kind === 'preparation_export') {
      purpose = window.prompt('Enter the purpose for exporting full taxpayer identification numbers:')?.trim()
      if (!purpose || purpose.length < 10) { setError('Enter a purpose of at least 10 characters.'); return }
      if (!window.confirm('This CSV contains full taxpayer identification numbers. Export it for the stated purpose?')) return
    }
    const request = beginRequest()
    if (!request) return
    const epoch = generation.current
    setBusy(true); setError(null)
    try {
      const isSensitive = kind === 'preparation_export'
      const isMonthly = kind === 'bpt_events_export' || kind === 'cpa_monthly_export'
      const path = `/admin/tax_reports/${kind}`
      const response = isSensitive
        ? await apiClient.post(path, { year: report.year, include_full_tins: true, purpose }, { ...request.config, responseType: 'blob' })
        : await apiClient.get(path, { ...request.config, params: { year: report.year, ...(isMonthly ? { month } : {}) }, responseType: 'blob' })
      if (!request.current() || epoch !== generation.current) return
      const filename = kind === 'cpa_monthly_export'
        ? `hafapass-cpa-monthly-${report.year}-${month}.csv`
        : kind === 'bpt_events_export'
          ? `hafapass-bpt-events-${report.year}-${month}.csv`
          : `hafapass-${kind}-${report.year}${isSensitive ? '-SENSITIVE-FULL-TINS' : '-masked'}.csv`
      saveBlob(response.data, filename)
    } catch (e) {
      if (request.current() && epoch === generation.current && !request.handleError(e)) setError('The action failed. Please retry.')
    } finally { if (request.current()) setBusy(false); request.release() }
  }

  return <AdminLayout>
    <div className="space-y-6">
      <p className="text-sm text-neutral-700">Live-mode USD payments only. Calendar periods use Guam time. Cash retained by organizers and test payments are excluded. Reports help preparation; your accountant determines reporting and filing duties.</p>
      <label className="block max-w-xs text-sm font-medium">Calendar year<select value={year} disabled={busy} onChange={e => setYear(e.target.value)} className="input mt-1 min-h-11">{Array.from({ length: 12 }, (_, i) => Number(currentYear) + 1 - i).map(value => <option key={value}>{value}</option>)}</select></label>
      {error && <p role="alert" className="text-red-800">{error} <button type="button" className="min-h-11 underline" onClick={load}>Retry reports</button></p>}
      {!report && !error && <p role="status">Loading tax reports…</p>}
      {report && <>
        <CpaMonthlyPanel
          cpaMonthly={cpaMonthly}
          cpaLoading={cpaLoading}
          cpaError={cpaError}
          onRetry={loadCpaMonthly}
          year={report.year}
          month={month}
          busy={busy}
          onExport={{ onMonthChange: e => setMonth(e.target.value), download: action }}
        />

        <section aria-labelledby="bpt-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6">
          <h2 id="bpt-heading" className="text-lg font-semibold">Monthly HåfaPass gross receipts (Guam BPT)</h2>
          <p className="mt-2 text-sm text-neutral-700">{report.note}</p>
          <p className="mt-2 text-sm text-neutral-700">Actual card costs are shown separately against the collection month and may update when provider evidence arrives. They are not deducted from gross receipts.</p>
          <button type="button" disabled={busy} className="btn-secondary my-4 min-h-11" onClick={() => action('receipts_export')}>Export gross receipts CSV</button>
          <div className="overflow-x-auto" tabIndex={0} role="region" aria-label="Monthly gross receipts table"><table className="w-full text-left text-sm"><caption className="sr-only">Monthly service fees and card costs for {report.year} in USD</caption><thead><tr>{['Month', 'Fees collected', 'Fees refunded', 'Gross receipts', 'Card costs'].map(label => <th key={label} scope="col" className="whitespace-nowrap p-2">{label}</th>)}</tr></thead><tbody>{report.months.map(row => <tr key={row.month} className="border-t border-neutral-200"><th scope="row" className="p-2">{String(row.month).padStart(2, '0')}</th>{['fees_collected_cents', 'fees_refunded_cents', 'gross_receipts_cents', 'card_processing_costs_cents'].map(key => <td key={key} className="whitespace-nowrap p-2 tabular-nums">{money(row[key])}</td>)}</tr>)}</tbody></table></div>
        </section>

        <section aria-labelledby="annual-tax-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6">
          <h2 id="annual-tax-heading" className="text-lg font-semibold">Annual organizer payouts · {report.year}</h2>
          <p className="mt-2 text-sm text-neutral-700">Gross amounts are after discounts. Refund and fee components are shown separately. Each payout uses its W-9 at payout time; legacy payouts are flagged without a TIN. Activity is allocated among an organizer’s payout identities by paid amount. Adjustments bridge timing, reserves, processing costs and unpaid balances.</p>
          <div className="my-4 flex flex-wrap gap-3"><button type="button" disabled={busy} className="btn-secondary min-h-11" onClick={() => action('organizers_export')}>Export masked CSV</button><button type="button" disabled={busy} className="btn-secondary min-h-11" onClick={() => action('preparation_export')}>Export full TINs for 1099 preparation (audited)</button></div>
          <p className="mb-4 text-xs text-content-muted">Full-TIN files contain sensitive tax data. Store them securely and import TIN columns as text to preserve leading zeroes. TINs remain masked on screen.</p>
          {report.organizers.length === 0 && <p>No live financial activity for this year.</p>}
          <div className="space-y-4">{report.organizers.map((row, index) => <article key={`${row.organization_id}:${row.tax_snapshot_payout_id || index}`} className="rounded-xl border border-neutral-200 p-4">
            <h3 className="font-semibold [overflow-wrap:anywhere]">{row.organization_name}</h3>
            <p className="mt-1 text-sm text-content-muted">{row.tax_snapshot_status}</p>
            <dl className="mt-3 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
              {[
                ['Legal name', row.tax_information?.legal_name || 'Not provided'], ['Classification', taxClassificationLabel(row.tax_information?.tax_classification)],
                [row.tax_snapshot_status === 'No paid payout' ? 'Current W-9 on file' : 'W-9 at payout', row.w9_on_file ? 'Yes' : 'No'], ['TIN', row.tax_information?.masked_tin || 'Not provided'],
                ['Gross ticket proceeds', money(row.gross_ticket_proceeds_cents)], ['Gross add-ons', money(row.gross_add_on_proceeds_cents)],
                ['Gross donations', money(row.gross_donation_proceeds_cents)], ['Gross other sales', money(row.gross_other_proceeds_cents)],
                ['Ticket refunds', money(row.ticket_refunds_cents)], ['Other refunds', money(row.non_ticket_refunds_cents)],
                ['Unallocated refunds', money(row.unallocated_refunds_cents)],
                ['Fee refunds', money(row.fee_refunds_cents)], ['HåfaPass fees collected', money(row.fees_collected_cents)],
                ['Reconciliation adjustments', money(row.reconciliation_adjustments_cents)], ['Net paid out', money(row.net_paid_cents)],
              ].map(([label, value]) => <div key={label} className="[overflow-wrap:anywhere]"><dt className="text-content-muted">{label}</dt><dd className="font-medium tabular-nums">{value}</dd></div>)}
            </dl>
          </article>)}</div>
        </section>
      </>}
    </div>
  </AdminLayout>
}

export default function AdminTaxReportsPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin/tax-reports')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <TaxReportsSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} />
}

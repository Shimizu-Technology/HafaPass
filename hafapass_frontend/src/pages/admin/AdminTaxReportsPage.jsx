import { useCallback, useEffect, useRef, useState } from 'react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../../hooks/usePlatformContext'
import { taxClassificationLabel } from '../../utils/taxInformation'
import { saveBlob } from '../../utils/download'

const money = cents => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format((cents || 0) / 100)

function TaxReportsSession({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin/tax-reports')
  const [year, setYear] = useState(String(new Date().getFullYear()))
  const [report, setReport] = useState(null)
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)
  const generation = useRef(0)
  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    const epoch = ++generation.current
    setReport(null); setError(null)
    try {
      const response = await apiClient.get('/admin/tax_reports', { ...request.config, params: { year } })
      if (request.current() && epoch === generation.current) setReport(response.data)
    } catch (e) {
      if (request.current() && epoch === generation.current && !request.handleError(e)) setError('Could not load tax reports. Please retry.')
    } finally { request.release() }
  }, [beginRequest, year])
  useEffect(() => { load() }, [load])
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
      const path = `/admin/tax_reports/${kind}`
      const response = isSensitive
        ? await apiClient.post(path, { year: report.year, include_full_tins: true, purpose }, { ...request.config, ...(isSensitive ? { responseType: 'blob' } : {}) })
        : await apiClient.get(path, { ...request.config, params: { year: report.year }, responseType: 'blob' })
      if (!request.current() || epoch !== generation.current) return
      saveBlob(response.data, `hafapass-${kind}-${report.year}${isSensitive ? '-SENSITIVE-FULL-TINS' : '-masked'}.csv`)
    } catch (e) {
      if (request.current() && epoch === generation.current && !request.handleError(e)) setError('The action failed. Please retry.')
    } finally { if (request.current()) setBusy(false); request.release() }
  }
  return <AdminLayout>
    <div className="space-y-6">
      <p className="text-sm text-neutral-700">Live-mode USD payments only. Calendar periods use Guam time. Cash retained by organizers and test payments are excluded. Reports help preparation; your accountant determines reporting and filing duties.</p>
      <label className="block max-w-xs text-sm font-medium">Calendar year<select value={year} disabled={busy} onChange={e => setYear(e.target.value)} className="input mt-1">{Array.from({ length: 12 }, (_, i) => new Date().getFullYear() + 1 - i).map(value => <option key={value}>{value}</option>)}</select></label>
      {error && <p role="alert" className="text-red-800">{error} <button type="button" className="min-h-11 underline" onClick={load}>Retry reports</button></p>}
      {!report && !error && <p role="status">Loading tax reports…</p>}
      {report && <>
        <section aria-labelledby="annual-tax-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6">
          <h2 id="annual-tax-heading" className="text-lg font-semibold">Annual organizer payouts · {report.year}</h2>
          <p className="mt-2 text-sm text-neutral-700">Gross amounts are after discounts. Refund and fee components are shown separately. Each payout uses its W-9 at payout time; legacy payouts are flagged without a TIN. Activity is allocated among an organizer’s payout identities by paid amount. Adjustments bridge timing, reserves, processing costs and unpaid balances.</p>
          <div className="my-4 flex flex-wrap gap-3"><button disabled={busy} className="btn-secondary" onClick={() => action('organizers_export')}>Export masked CSV</button><button disabled={busy} className="btn-secondary" onClick={() => action('preparation_export')}>Export full TINs for 1099 preparation (audited)</button></div>
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
              ].map(([label, value]) => <div key={label} className="[overflow-wrap:anywhere]"><dt className="text-content-muted">{label}</dt><dd className="font-medium">{value}</dd></div>)}
            </dl>
          </article>)}</div>
        </section>
        <section aria-labelledby="bpt-heading" className="rounded-2xl border border-neutral-200 bg-white p-4 sm:p-6">
          <h2 id="bpt-heading" className="text-lg font-semibold">Monthly HåfaPass gross receipts (Guam BPT)</h2>
          <p className="mt-2 text-sm text-neutral-700">{report.note}</p>
          <p className="mt-2 text-sm text-neutral-700">Actual card costs are shown separately against the collection month and may update when provider evidence arrives. They are not deducted from gross receipts.</p>
          <button disabled={busy} className="btn-secondary my-4" onClick={() => action('receipts_export')}>Export gross receipts CSV</button>
          <div className="overflow-x-auto" tabIndex={0} role="region" aria-label="Monthly gross receipts table"><table className="w-full text-left text-sm"><caption className="sr-only">Monthly service fees and card costs for {report.year} in USD</caption><thead><tr>{['Month', 'Fees collected', 'Fees refunded', 'Gross receipts', 'Card costs'].map(label => <th key={label} scope="col" className="whitespace-nowrap p-2">{label}</th>)}</tr></thead><tbody>{report.months.map(row => <tr key={row.month} className="border-t border-neutral-200"><th scope="row" className="p-2">{String(row.month).padStart(2, '0')}</th>{['fees_collected_cents', 'fees_refunded_cents', 'gross_receipts_cents', 'card_processing_costs_cents'].map(key => <td key={key} className="whitespace-nowrap p-2">{money(row[key])}</td>)}</tr>)}</tbody></table></div>
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

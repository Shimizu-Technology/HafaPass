import { useCallback, useEffect, useState } from 'react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../../hooks/usePlatformContext'
import { saveBlob } from '../../utils/download'

const money = cents => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format((cents || 0) / 100)
const formOptions = [['review_required', 'CPA review needed'], ['1099-nec', '1099-NEC'], ['1099-misc', '1099-MISC'], ['1099-k', '1099-K'], ['none', 'None']]

function Controls({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin/tax-controls')
  const [year, setYear] = useState(String(new Date().getFullYear()))
  const [payees, setPayees] = useState([])
  const [reports, setReports] = useState([])
  const [unattributed, setUnattributed] = useState([])
  const [reason, setReason] = useState({})
  const [receiptDates, setReceiptDates] = useState({})
  const [validationRefs, setValidationRefs] = useState({})
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const request = beginRequest()
    if (!request) return
    try {
      const [matching, annual] = await Promise.all([
        apiClient.get('/admin/tin_matching', request.config),
        apiClient.get('/admin/annual_tax_reports', { ...request.config, params: { year } }),
      ])
      if (request.current()) { setPayees(matching.data.payees); setReports(annual.data.reports); setUnattributed(annual.data.unattributed_adjustments || []); setError('') }
    } catch (e) { if (request.current() && !request.handleError(e)) setError('Could not load tax controls. Retry.') }
    finally { request.release() }
  }, [beginRequest, year])
  useEffect(() => { load() }, [load])

  const run = async (task, success) => {
    const request = beginRequest()
    if (!request) return
    setBusy(true); setError(''); setNotice('')
    try {
      await task(request.config)
      if (request.current()) { setNotice(success); await load() }
    } catch (e) { if (request.current() && !request.handleError(e)) setError(e.response?.data?.error || 'Action failed. Retry.') }
    finally { if (request.current()) setBusy(false); request.release() }
  }

  const fullTinDownload = () => {
    const purpose = window.prompt('Enter the purpose for exporting full taxpayer identification numbers:')?.trim()
    if (!purpose || purpose.length < 10) { setError('Enter a purpose of at least 10 characters.'); return }
    if (!window.confirm('This CSV contains full taxpayer identification numbers. Export it for the stated purpose?')) return
    download('/admin/annual_tax_reports/export', { year, include_full_tins: true, purpose }, `annual-payees-${year}-SENSITIVE-FULL-TINS.csv`)
  }

  const matchingDownload = () => {
    const purpose = window.prompt('Enter the purpose for exporting full taxpayer identification numbers for IRS matching:')?.trim()
    if (!purpose || purpose.length < 10) { setError('Enter a purpose of at least 10 characters.'); return }
    if (!window.confirm('This IRS matching file contains full taxpayer identification numbers. Export it for the stated purpose?')) return
    download('/admin/tin_matching/export', { purpose, confirm_full_tins: true }, `tin-matching-${new Date().toISOString().slice(0, 10)}-SENSITIVE-FULL-TINS.txt`)
  }

  const download = (path, body, filename) => run(async config => {
    const response = await apiClient.post(path, body, { ...config, responseType: 'blob' })
    saveBlob(response.data, filename)
  }, 'Download ready. Store this file securely.')

  return <AdminLayout><div className="space-y-6">
    <header><h1 className="text-2xl font-semibold">Tax controls</h1><p className="mt-2 text-sm text-neutral-700">Prepare matching and annual data for CPA review. Tax decisions and filing remain with the CPA.</p></header>
    {error && <p role="alert" className="rounded-xl bg-red-50 p-3 text-red-800">{error} <button className="underline" onClick={load}>Retry</button></p>}
    {notice && <p role="status" className="rounded-xl bg-emerald-50 p-3 text-emerald-800">{notice}</p>}
    <section className="rounded-2xl border bg-white p-4 sm:p-6" aria-labelledby="matching-title">
      <h2 id="matching-title" className="text-lg font-semibold">TIN matching</h2>
      <p className="mt-1 text-sm text-neutral-700">Download an IRS e-Services bulk file for unverified payees. Upload the returned result file. TINs stay masked on this page.</p>
      <div className="mt-4 flex flex-wrap items-end gap-3">
        <button type="button" disabled={busy} className="btn-secondary" onClick={matchingDownload}>Export verification file</button>
        <label className="text-sm font-medium">IRS result file<input aria-label="IRS result file" type="file" accept=".txt,text/plain" disabled={busy} className="input mt-1" onChange={e => { const file = e.target.files?.[0]; if (file) { const data = new FormData(); data.append('file', file); run(config => apiClient.post('/admin/tin_matching/import', data, config), 'Matching results imported.') } e.target.value = '' }} /></label>
      </div>
      <div className="mt-5 space-y-3">{payees.map(({ organization_id: id, organization_name: name, tax_information: tax, under_withheld_cents: shortfall }) => <article key={id} className="rounded-xl border p-4">
        <h3 className="font-medium [overflow-wrap:anywhere]">{name}</h3>
        <p className="mt-1 text-sm">{tax.legal_name} · {tax.masked_tin} · TIN status: <strong>{tax.tin_match_status.replaceAll('_', ' ')}</strong></p>
        {tax.b_notice_stage && <p className="mt-1 text-sm">{tax.b_notice_stage} B-notice history; {tax.b_notice_sent_at ? `sent ${new Date(tax.b_notice_sent_at).toLocaleDateString()}` : "awaiting delivery"}; withholding due {tax.b_notice_response_due_on}</p>}
        {tax.irs_notice_received_on && <p className="mt-1 text-sm">IRS notice received {tax.irs_notice_received_on}; B-notice send deadline {tax.b_notice_send_due_on}{tax.b_notice_send_at_risk ? " — deadline at risk" : ""}</p>}
        <p className="mt-1 text-sm">Backup withholding: {tax.backup_withholding_required ? 'Required' : tax.backup_withholding_flag ? 'Flagged' : 'No active flag'}</p>
        {shortfall > 0 && <p className="mt-1 text-sm font-semibold text-amber-900">Under-withheld to collect from the next payout: {money(shortfall)}</p>}
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <label className="text-sm">Reason for flag change<input className="input mt-1" value={reason[id] || ''} onChange={e => setReason(prev => ({ ...prev, [id]: e.target.value }))} /></label>
          <button type="button" className="btn-secondary" disabled={busy || (reason[id] || '').trim().length < 10} onClick={() => run(config => apiClient.patch(`/admin/organizations/${id}/tax_information/withholding_flag`, { flagged: !tax.backup_withholding_flag, reason: reason[id] }, config), 'Withholding flag updated.')}>{tax.backup_withholding_flag ? 'Clear flag' : 'Flag for withholding'}</button>
        </div>
        {tax.tin_match_status === 'mismatch' && <div className="mt-3 flex flex-wrap gap-2">
          <label className="text-sm">IRS notice receipt date<input type="date" className="input mt-1" value={receiptDates[id] || ''} max={new Date().toISOString().slice(0, 10)} onChange={e => setReceiptDates(prev => ({ ...prev, [id]: e.target.value }))} /></label>
          <button type="button" className="btn-secondary" disabled={busy || !receiptDates[id]} onClick={() => run(config => apiClient.post(`/admin/organizations/${id}/tax_information/notice_received`, { received_on: receiptDates[id] }, config), 'IRS notice receipt recorded.')}>Record IRS notice receipt</button>
          {['first', 'second'].map(stage => <button key={stage} type="button" className="btn-secondary" disabled={busy || !tax.irs_notice_received_on || stage !== tax.next_b_notice_stage} onClick={() => download(`/admin/organizations/${id}/tax_information/b_notice_pdf`, { stage }, `b-notice-${stage}-${id}.pdf`)}>Download {stage} B-notice</button>)}
          <button type="button" className="btn-secondary" disabled={busy || !tax.next_b_notice_stage} onClick={() => run(config => apiClient.post(`/admin/organizations/${id}/tax_information/b_notice_sent`, { stage: tax.next_b_notice_stage, sent_on: new Date().toISOString().slice(0, 10) }, config), 'B-notice sent date recorded.')}>Record {tax.next_b_notice_stage || 'pending'} notice sent today</button>
        </div>}
        {tax.b_notice_stage === 'second' && !tax.irs_validation_recorded_on && <div className="mt-3 flex flex-wrap gap-2">
          <label className="text-sm">Validation document reference (optional)<input className="input mt-1" value={validationRefs[id] || ''} onChange={e => setValidationRefs(prev => ({ ...prev, [id]: e.target.value }))} /></label>
          <button type="button" className="btn-secondary" disabled={busy} onClick={() => run(config => apiClient.post(`/admin/organizations/${id}/tax_information/validate_second_notice`, { evidence_type: tax.tin_type === 'ssn' ? 'ssa_card' : 'irs_letter_147c', recorded_on: new Date().toISOString().slice(0, 10), document_reference: validationRefs[id] || '' }, config), 'IRS validation recorded.')}>Record {tax.tin_type === 'ssn' ? 'SSA card' : 'IRS Letter 147C'} validation</button>
        </div>}
      </article>)}</div>
    </section>
    <section className="rounded-2xl border bg-white p-4 sm:p-6" aria-labelledby="annual-title">
      <h2 id="annual-title" className="text-lg font-semibold">Annual payee review</h2>
      <p className="mt-1 text-sm text-neutral-700">Form and jurisdiction start as CPA review needed and IRS. Thresholds are configured per form and tax year. A withheld amount requires CPA review regardless of threshold.</p>
      <div className="mt-4 flex flex-wrap items-end gap-3"><label className="text-sm font-medium">Calendar year<select className="input mt-1" value={year} onChange={e => setYear(e.target.value)}>{Array.from({ length: 8 }, (_, i) => new Date().getFullYear() + 1 - i).map(y => <option key={y}>{y}</option>)}</select></label>
        <button type="button" disabled={busy} className="btn-secondary" onClick={() => download('/admin/annual_tax_reports/export', { year }, `annual-payees-${year}-masked.csv`)}>Export masked CPA CSV</button>
        <button type="button" disabled={busy} className="btn-secondary" onClick={fullTinDownload}>Export full TINs</button></div>
      <div className="mt-5 space-y-3">{reports.length === 0 && unattributed.length === 0 && <p className="text-sm text-neutral-700">No payout or refund adjustment activity for this year.</p>}{reports.map(row => <article key={`${row.organization_id}:${row.payee_key}`} className="rounded-xl border p-4">
        <h3 className="font-medium [overflow-wrap:anywhere]">{row.organization_name} · {row.masked_tin || 'TIN missing'}</h3>
        <p className="mt-1 text-sm">Gross paid {money(row.gross_paid_cents)} · Withheld {money(row.withheld_cents)} · Refund adjustments {money(row.refund_clawbacks_cents)} · {row.reporting_status.replaceAll('_', ' ')}</p>
        <div className="mt-3 grid gap-3 sm:grid-cols-2"><label className="text-sm">Form type<select className="input mt-1" value={row.form_type} disabled={busy} onChange={e => run(config => apiClient.patch(`/admin/annual_tax_reports/${row.organization_id}`, { year, payee_key: row.payee_key, form_type: e.target.value, jurisdiction: row.jurisdiction }, config), 'Annual classification saved.')}>{formOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
          <label className="text-sm">Filing jurisdiction<select className="input mt-1" value={row.jurisdiction} disabled={busy} onChange={e => run(config => apiClient.patch(`/admin/annual_tax_reports/${row.organization_id}`, { year, payee_key: row.payee_key, form_type: row.form_type, jurisdiction: e.target.value }, config), 'Jurisdiction saved.')}><option value="irs">IRS</option><option value="guam_drt">Guam DRT</option></select></label></div>
      </article>)}</div>
      {unattributed.map(item => <p key={item.organization_id} className="mt-3 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950"><strong>{item.organization_name}:</strong> {money(item.amount_cents)} of refund adjustment exceeds the amount paid for its sale line. Unattributed — CPA review required.</p>)}
    </section>
  </div></AdminLayout>
}

export default function AdminTaxControlsPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin/tax-controls')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <Controls key={`${identity.accountKey}:${visit.generation}`} identity={identity} />
}

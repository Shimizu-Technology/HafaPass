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
  const [reason, setReason] = useState({})
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
      if (request.current()) { setPayees(matching.data.payees); setReports(annual.data.reports); setError('') }
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
        <button type="button" disabled={busy} className="btn-secondary" onClick={() => download('/admin/tin_matching/export', {}, 'tin-matching.txt')}>Export verification file</button>
        <label className="text-sm font-medium">IRS result file<input aria-label="IRS result file" type="file" accept=".txt,text/plain" disabled={busy} className="input mt-1" onChange={e => { const file = e.target.files?.[0]; if (file) { const data = new FormData(); data.append('file', file); run(config => apiClient.post('/admin/tin_matching/import', data, config), 'Matching results imported.') } e.target.value = '' }} /></label>
      </div>
      <div className="mt-5 space-y-3">{payees.map(({ organization_id: id, organization_name: name, tax_information: tax }) => <article key={id} className="rounded-xl border p-4">
        <h3 className="font-medium [overflow-wrap:anywhere]">{name}</h3>
        <p className="mt-1 text-sm">{tax.legal_name} · {tax.masked_tin} · TIN status: <strong>{tax.tin_match_status.replaceAll('_', ' ')}</strong></p>
        {tax.b_notice_stage && <p className="mt-1 text-sm">{tax.b_notice_stage} B-notice sent {new Date(tax.b_notice_sent_at).toLocaleDateString()}; response due {tax.b_notice_response_due_on}</p>}
        <p className="mt-1 text-sm">Backup withholding: {tax.backup_withholding_required ? 'Required' : tax.backup_withholding_flag ? 'Flagged' : 'No active flag'}</p>
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <label className="text-sm">Reason for flag change<input className="input mt-1" value={reason[id] || ''} onChange={e => setReason(prev => ({ ...prev, [id]: e.target.value }))} /></label>
          <button type="button" className="btn-secondary" disabled={busy || (reason[id] || '').trim().length < 10} onClick={() => run(config => apiClient.patch(`/admin/organizations/${id}/tax_information/withholding_flag`, { flagged: !tax.backup_withholding_flag, reason: reason[id] }, config), 'Withholding flag updated.')}>{tax.backup_withholding_flag ? 'Clear flag' : 'Flag for withholding'}</button>
        </div>
        {tax.tin_match_status === 'mismatch' && <div className="mt-3 flex flex-wrap gap-2">
          {['first', 'second'].map(stage => <button key={stage} type="button" className="btn-secondary" disabled={busy || (stage === 'second' && tax.b_notice_stage !== 'first')} onClick={() => download(`/admin/organizations/${id}/tax_information/b_notice_pdf`, { stage }, `b-notice-${stage}-${id}.pdf`)}>Download {stage} B-notice</button>)}
          <button type="button" className="btn-secondary" disabled={busy} onClick={() => run(config => apiClient.post(`/admin/organizations/${id}/tax_information/b_notice_sent`, { stage: tax.b_notice_stage === 'first' ? 'second' : 'first', sent_on: new Date().toISOString().slice(0, 10) }, config), 'B-notice sent date recorded.')}>Record {tax.b_notice_stage === 'first' ? 'second' : 'first'} notice sent today</button>
        </div>}
      </article>)}</div>
    </section>
    <section className="rounded-2xl border bg-white p-4 sm:p-6" aria-labelledby="annual-title">
      <h2 id="annual-title" className="text-lg font-semibold">Annual payee review</h2>
      <p className="mt-1 text-sm text-neutral-700">Form and jurisdiction start as CPA review needed and IRS. Thresholds are site settings. A withheld amount requires CPA review regardless of threshold.</p>
      <div className="mt-4 flex flex-wrap items-end gap-3"><label className="text-sm font-medium">Calendar year<select className="input mt-1" value={year} onChange={e => setYear(e.target.value)}>{Array.from({ length: 8 }, (_, i) => new Date().getFullYear() + 1 - i).map(y => <option key={y}>{y}</option>)}</select></label>
        <button type="button" disabled={busy} className="btn-secondary" onClick={() => download('/admin/annual_tax_reports/export', { year }, `annual-payees-${year}.csv`)}>Export CPA preparation CSV</button></div>
      <div className="mt-5 space-y-3">{reports.length === 0 && <p className="text-sm text-neutral-700">No paid payouts for this year.</p>}{reports.map(row => <article key={`${row.organization_id}:${row.payee_key}`} className="rounded-xl border p-4">
        <h3 className="font-medium [overflow-wrap:anywhere]">{row.organization_name} · {row.masked_tin || 'TIN missing'}</h3>
        <p className="mt-1 text-sm">Gross paid {money(row.gross_paid_cents)} · Withheld {money(row.withheld_cents)} · Refund adjustments {money(row.refund_clawbacks_cents)} · {row.reporting_status.replaceAll('_', ' ')}</p>
        <div className="mt-3 grid gap-3 sm:grid-cols-2"><label className="text-sm">Form type<select className="input mt-1" value={row.form_type} disabled={busy} onChange={e => run(config => apiClient.patch(`/admin/annual_tax_reports/${row.organization_id}`, { year, payee_key: row.payee_key, form_type: e.target.value, jurisdiction: row.jurisdiction }, config), 'Annual classification saved.')}>{formOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
          <label className="text-sm">Filing jurisdiction<select className="input mt-1" value={row.jurisdiction} disabled={busy} onChange={e => run(config => apiClient.patch(`/admin/annual_tax_reports/${row.organization_id}`, { year, payee_key: row.payee_key, form_type: row.form_type, jurisdiction: e.target.value }, config), 'Jurisdiction saved.')}><option value="irs">IRS</option><option value="guam_drt">Guam DRT</option></select></label></div>
      </article>)}</div>
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

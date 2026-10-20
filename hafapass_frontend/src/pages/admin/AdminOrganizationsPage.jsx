import { useCallback, useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { Building2, Loader2, Plus } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import Dialog from '../../components/Dialog'
import OperationalSearch from '../../components/OperationalSearch'
import OperationalPagination from '../../components/OperationalPagination'
import { InvitationLinkPanel, InvitationStatusPill } from '../../components/team/TeamManager'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../../hooks/usePlatformContext'
import { adminLabel } from './adminLabels'
import { invitationUrl } from '../../utils/roles'

// "Create organization for someone": the organization, its organizer profile
// and an emailed Owner invitation in one step.
function CreateOrganizationDialog({ busy, error, created, onCancel, onCreate }) {
  const [name, setName] = useState('')
  const [ownerEmail, setOwnerEmail] = useState('')
  const [preVerified, setPreVerified] = useState(false)
  const submit = event => {
    event.preventDefault()
    if (!name.trim() || !ownerEmail.trim()) return
    onCreate({ name: name.trim(), owner_email: ownerEmail.trim(), pre_verified: preVerified })
  }
  return (
    <Dialog labelledBy="create-organization-title" onClose={onCancel} busy={busy} className="max-w-lg">
      <h2 id="create-organization-title" className="text-lg font-semibold text-neutral-900">{created ? 'Organization created' : 'Create an organization for someone'}</h2>
      {created ? (
        <>
          <p className="mt-2 text-sm text-neutral-700">We emailed an Owner invitation to <strong className="[overflow-wrap:anywhere]">{created.owner?.email}</strong>. They become the owner when they sign in with that email and accept. Until then you can manage the organization from its page.</p>
          {created.invitation_token && <InvitationLinkPanel url={invitationUrl(created.invitation_token)} email={created.owner?.email} />}
          <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button type="button" onClick={onCancel} className="btn-secondary">Close</button>
            <Link to={`/admin/organizations/${created.id}`} className="btn-primary">Open {created.name}</Link>
          </div>
        </>
      ) : (
        <form onSubmit={submit} className="mt-4 space-y-4">
          <label className="block text-sm font-medium text-neutral-900">
            Organization name
            <input required value={name} onChange={event => setName(event.target.value)} maxLength={200} className="input mt-1" placeholder="e.g. Ambros Events" disabled={busy} />
          </label>
          <label className="block text-sm font-medium text-neutral-900">
            Owner’s email
            <span className="block font-normal text-content-muted">They get an invitation to manage the team, payouts and all events.</span>
            <input required type="email" value={ownerEmail} onChange={event => setOwnerEmail(event.target.value)} className="input mt-1" placeholder="owner@example.com" autoComplete="off" disabled={busy} />
          </label>
          <label className="flex min-h-11 items-start gap-3 text-sm text-neutral-900">
            <input type="checkbox" checked={preVerified} onChange={event => setPreVerified(event.target.checked)} disabled={busy} className="mt-1 h-4 w-4 accent-brand-600" />
            <span>Mark as verified now<span className="block text-content-muted">Use when you already know this organizer. They still accept the organizer agreement themselves.</span></span>
          </label>
          {error && <p role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
          <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button type="button" onClick={onCancel} disabled={busy} className="btn-secondary">Cancel</button>
            <button type="submit" disabled={busy || !name.trim() || !ownerEmail.trim()} className="btn-primary">{busy ? 'Creating…' : 'Create and invite owner'}</button>
          </div>
        </form>
      )}
    </Dialog>
  )
}

function AdminOrganizationsSession({ identity }) {
  const { beginRequest } = usePlatformRequests(identity, '/admin/organizations')
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(1)
  const [state, setState] = useState({ status: 'loading', organizations: [], meta: null })
  const [dialog, setDialog] = useState(null)
  const loadGeneration = useRef(0)

  const load = useCallback(() => {
    const request = beginRequest()
    if (!request) return
    const generation = ++loadGeneration.current
    setState(current => ({ ...current, status: 'loading' }))
    apiClient.get('/admin/organizations', { ...request.config, params: { q: query || undefined, page } })
      .then(response => { if (request.current() && generation === loadGeneration.current) setState({ status: 'ready', organizations: response.data.organizations, meta: response.data.meta }) })
      .catch(error => { if (request.current() && !request.handleError(error) && generation === loadGeneration.current) setState(current => ({ ...current, status: 'error' })) })
      .finally(() => request.release())
  }, [beginRequest, query, page])
  useEffect(() => { load() }, [load])

  const create = async payload => {
    const request = beginRequest()
    if (!request) return
    setDialog(current => ({ ...current, busy: true, error: null }))
    try {
      const response = await apiClient.post('/admin/organizations', payload, request.config)
      if (!request.current()) return
      setDialog({ created: response.data })
      load()
    } catch (error) {
      if (request.handleError(error) || !request.current()) return
      setDialog(current => ({ ...current, busy: false, error: error.response?.data?.error || 'The organization could not be created.' }))
    } finally { request.release() }
  }

  return (
    <AdminLayout>
      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <p className="max-w-2xl text-sm text-content-muted">Every organization on HåfaPass. Open one to manage its team, or to work inside its dashboard as an admin.</p>
        <button type="button" onClick={() => setDialog({})} className="btn-primary shrink-0 gap-2"><Plus aria-hidden="true" className="h-4 w-4" />Create organization for someone</button>
      </div>
      <OperationalSearch label="Find an organization" hint="Search by name or link name." query={query} onSearch={value => { setQuery(value); setPage(1) }} busy={state.status === 'loading'} buttonLabel="Search organizations" />
      <div className="rounded-xl border border-neutral-200 bg-white" aria-busy={state.status === 'loading'}>
        {state.status === 'loading' && state.organizations.length === 0 && <div role="status" aria-label="Loading organizations" className="flex justify-center py-12"><Loader2 aria-hidden="true" className="h-6 w-6 animate-spin text-brand-700 motion-reduce:animate-none" /></div>}
        {state.status === 'error' && <div role="alert" className="p-5 text-red-700">Organizations could not be loaded. <button type="button" onClick={load} className="min-h-11 font-semibold underline">Try again</button></div>}
        {state.status !== 'error' && state.organizations.length > 0 && (
          <ul className="divide-y divide-neutral-100">
            {state.organizations.map(organization => (
              <li key={organization.id}>
                <Link to={`/admin/organizations/${organization.id}`} className="flex flex-col gap-2 p-4 transition-colors duration-150 [@media(hover:hover)]:hover:bg-neutral-50 sm:flex-row sm:items-center sm:justify-between">
                  <span className="flex min-w-0 items-start gap-3">
                    <Building2 aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-brand-600" />
                    <span className="min-w-0">
                      <span className="block font-semibold text-neutral-900 [overflow-wrap:anywhere]">{organization.name}</span>
                      <span className="block text-sm text-content-muted [overflow-wrap:anywhere]">Owner: {organization.owner?.email || 'none yet'}{organization.owner?.invitation_status && organization.owner.invitation_status !== 'accepted' ? ' (invited)' : ''}</span>
                    </span>
                  </span>
                  <span className="flex flex-wrap items-center gap-2 text-sm text-neutral-700 sm:justify-end">
                    <span>{organization.members_count} member{organization.members_count === 1 ? '' : 's'}</span>
                    {organization.pending_invitations_count > 0 && <InvitationStatusPill status="pending" />}
                    {organization.verification_status && <span className="rounded-full bg-neutral-100 px-2.5 py-1 text-xs font-semibold">{adminLabel(organization.verification_status)}</span>}
                    <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${organization.payout_ready ? 'bg-emerald-50 text-emerald-800' : 'bg-amber-50 text-amber-900'}`}>{organization.payout_ready ? 'Payouts ready' : 'Payouts not ready'}</span>
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
        {state.status === 'ready' && state.organizations.length === 0 && <p className="p-8 text-center text-sm text-content-muted">{query ? 'No organizations match that search.' : 'No organizations yet.'}</p>}
      </div>
      <OperationalPagination meta={state.meta} page={page} onPage={setPage} busy={state.status === 'loading'} label="Organization pages" />
      {dialog && <CreateOrganizationDialog busy={Boolean(dialog.busy)} error={dialog.error} created={dialog.created} onCancel={() => setDialog(null)} onCreate={create} />}
    </AdminLayout>
  )
}

export default function AdminOrganizationsPage() {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit('/admin/organizations')
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <AdminOrganizationsSession key={`${identity.accountKey}:${visit.generation}`} identity={identity} />
}

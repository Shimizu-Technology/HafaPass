import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { CheckCircle2, CircleAlert, Loader2 } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import apiClient from '../../api/client'
import NoAccessNotice from '../../components/NoAccessNotice'
import TeamManager from '../../components/team/TeamManager'
import PayoutMethodSection from './PayoutMethodSection'
import TaxInformationSection from './TaxInformationSection'
import { roleDescription, roleLabel } from '../../utils/roles'
import { Link } from 'react-router-dom'

function StatusPill({ ready, children }) {
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold ${ready ? 'bg-emerald-50 text-emerald-700' : 'bg-amber-50 text-amber-800'}`}>
      {ready ? <CheckCircle2 className="h-3.5 w-3.5" /> : <CircleAlert className="h-3.5 w-3.5" />}
      {children}
    </span>
  )
}

export default function SettingsPage() {
 const identity = useOrganizerIdentity()
 const visit = useOrganizerPageVisit('/dashboard/settings')
 if (!visit.active) return null
 if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
 return <SettingsPageSession key={`${identity.accountKey}:${identity.organizationId}:${visit.generation}`} identity={identity} />
}

function SettingsPageSession({ identity }) {
 const { current, beginRequest } = useOrganizerRequests(identity, '/dashboard/settings')
 const accessEpoch = useRef(0)
 const verifiedAccess = useRef(false)
 const requests = useRef(new Set())
 const [organization, setOrganization] = useState(null)
 const [accounts, setAccounts] = useState([])
 const [memberships, setMemberships] = useState([])
 const [loading, setLoading] = useState(true)
 const [busy, setBusy] = useState(false)
 const [error, setError] = useState(null)
 const [notice, setNotice] = useState(null)
 const [marketingNotice, setMarketingNotice] = useState(null)
 const [payoutError, setPayoutError] = useState(null)
 const [marketingAddress, setMarketingAddress] = useState('')
 const [marketingCertified, setMarketingCertified] = useState(false)
 const loadGeneration = useRef(0)
 const withdrawAccess = useCallback(message => {
  ++accessEpoch.current
  verifiedAccess.current = false
  requests.current.forEach(request => request.controller.abort())
  setOrganization(null); setAccounts([]); setMemberships([])
  setNotice(null); setMarketingNotice(null); setBusy(false); setLoading(false)
  setError(message)
 }, [])
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const verifying = method === 'get' && url === '/organizer/organization'
  if (!verifying && !verifiedAccess.current) throw new DOMException('Organization access is not verified', 'AbortError')
  const request = beginRequest()
  if (!request) throw new DOMException('Page context changed', 'AbortError')
  const epoch = accessEpoch.current
  requests.current.add(request)
  try {
   const response = method === 'get' || method === 'delete'
    ? await apiClient[method](url, { ...payload, ...request.config })
    : await apiClient[method](url, payload, { ...options, ...request.config })
   if (!request.current() || epoch !== accessEpoch.current) throw new DOMException('Page context changed', 'AbortError')
   return response
  } catch (requestError) {
   if (request.current() && epoch === accessEpoch.current && [401, 403].includes(requestError.response?.status)) {
    withdrawAccess(requestError.response.status === 401 ? 'Please sign in to verify organization access.'
     : 'Your organization access changed. Retry to verify your current role before managing this organization.')
   }
   throw requestError
  } finally { requests.current.delete(request); request.release() }
 }, [beginRequest, withdrawAccess])

  // Permissions come from the API; older responses without them fall back to
  // the owner role, which the server still enforces either way.
  const can = permission => Boolean(organization && verifiedAccess.current
    && (organization.permissions ? organization.permissions[permission] === true : organization.role === 'owner'))
  const canManageTeam = can('manage_members')
  const canManagePayouts = can('manage_payout_settings')
  const canManageOrganization = can('manage_organization')
  const canTransfer = can('manage_organization')

  const load = useCallback(async () => {
    const generation = ++loadGeneration.current
    if (!current()) return
    const epoch = ++accessEpoch.current
    requests.current.forEach(request => request.controller.abort())
    const canApply = () => current() && generation === loadGeneration.current && epoch === accessEpoch.current
    setLoading(true)
    setBusy(false)
    setError(null)
    setMarketingNotice(null)
    try {
      const organizationResponse = await requestApi('get', '/organizer/organization')
      if (!canApply()) return
      if (organizationResponse.data.id == null || (identity.organizationId != null && String(organizationResponse.data.id) !== String(identity.organizationId))) {
        withdrawAccess('The organization context could not be verified. Return to your dashboard and select it again.')
        return
      }
      const data = organizationResponse.data
      const allowed = permission => data.permissions ? data.permissions[permission] === true : data.role === 'owner'
      verifiedAccess.current = allowed('manage_members') || allowed('manage_payout_settings') || allowed('manage_organization')
      setOrganization(data)
      setMarketingAddress(data.marketing_mailing_address || '')
      setMarketingCertified(Boolean(data.marketing_address_ready))
      const [membersResponse, accountsResponse] = await Promise.all([
        allowed('manage_members') ? requestApi('get', '/organizer/memberships') : null,
        allowed('manage_payout_settings') ? requestApi('get', '/organizer/connected_accounts') : null,
      ])
      if (!canApply()) return
      setMemberships(Array.isArray(membersResponse?.data) ? membersResponse.data : [])
      setAccounts(Array.isArray(accountsResponse?.data) ? accountsResponse.data : [])
      if (!accountsResponse) setNotice(null)
    } catch (requestError) {
      if (!canApply()) return
      setError(requestError.response?.data?.error || 'Could not load organization settings.')
    } finally {
      if (canApply()) setLoading(false)
    }
  }, [requestApi, current, identity.organizationId, withdrawAccess])

  useEffect(() => { load() }, [load])

  const teamRequest = useCallback((method, url, payload) => requestApi(method, url, payload), [requestApi])

  const savePayout = async ({ provider, accountId, payout_details: details }) => {
    if (!current() || !canManagePayouts || busy) return false
    const epoch = accessEpoch.current
    const canApply = () => current() && epoch === accessEpoch.current
    setBusy(true)
    setPayoutError(null)
    setNotice(null)
    try {
      const response = accountId
        ? await requestApi('patch', `/organizer/connected_accounts/${accountId}`, { payout_details: details })
        : await requestApi('post', '/organizer/connected_accounts', { provider, ...(details ? { payout_details: details } : {}) })
      if (!canApply()) return false
      setAccounts(items => [...items.filter(account => account.provider !== response.data.provider), response.data])
      setNotice(response.data.next_action)
      return true
    } catch (requestError) {
      if (canApply()) setPayoutError(requestError.response?.data?.error || 'Could not save your payout method.')
      return false
    } finally {
      if (canApply()) setBusy(false)
    }
  }

  const saveMarketingAddress = async event => {
    event.preventDefault()
    if (!current() || !canManageOrganization || busy) return
    setBusy(true); setError(null); setMarketingNotice(null)
    try {
      const response = await requestApi('patch', '/organizer/organization', {
        organization: { marketing_mailing_address: marketingAddress.trim(), certified: marketingCertified },
      })
      setOrganization(response.data)
      setMarketingNotice('Marketing postal address saved. Campaigns and waitlist emails use this address until you change it.')
    } catch (requestError) {
      setError(requestError.response?.data?.errors?.join(', ') || requestError.response?.data?.error || 'Could not save the marketing postal address.')
    } finally { setBusy(false) }
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
  if (!organization && error) return (
    <WorkspacePage as="section" width="form" aria-labelledby="organization-recovery-heading">
      <PageHeader back={<BackLink />} title="Verify organization access" titleId="organization-recovery-heading" className="!mb-0" />
      <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
        <p>{error}</p>
        <button type="button" onClick={load} className="mt-3 min-h-11 font-semibold underline">Retry organization settings</button>
      </div>
    </WorkspacePage>
  )

  return (
    <WorkspacePage as="section" aria-label="Organization settings">
      <PageHeader
        back={<BackLink />}
        eyebrow="Organization"
        title={organization?.name}
        description={`Your team and how you get paid${organization?.timezone ? ` · ${organization.timezone}` : ''}.`}
        actions={<StatusPill ready={organization?.payout_ready}>{organization?.payout_ready ? 'Paid events ready' : 'Payout setup incomplete'}</StatusPill>}
        className="!mb-0"
      />

      {error && <div role="alert" className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700"><p>{error}</p><button type="button" onClick={load} className="min-h-11 font-semibold underline">Retry organization settings</button></div>}

      <div className="mt-6 rounded-xl border border-neutral-200 bg-white p-5 text-sm">
        <h2 className="font-semibold text-neutral-900">Your personal data</h2>
        <p className="mt-1 text-content-muted">Request a copy of your data or ask us to delete it.</p>
        <Link to="/account/settings" className="mt-3 inline-flex min-h-11 items-center font-semibold text-brand-700 underline">Open privacy requests</Link>
      </div>

      {!canManageTeam && !canManagePayouts && !canManageOrganization ? (
        <NoAccessNotice className="mt-8" title="Settings are for the organization owner"
          detail={`Your role: ${roleLabel(organization?.role) || 'HåfaPass admin'} — ${roleDescription(organization?.role) || 'no team or payout access here.'} Event managers assign door staff from each event’s Team page.`} />
      ) : (
        <div className="mt-8 space-y-8">
          {canManageOrganization && <section className="card p-5 sm:p-6" aria-labelledby="marketing-postal-heading">
            <h2 id="marketing-postal-heading" className="text-lg font-bold text-neutral-900">Marketing postal address</h2>
            {marketingNotice && <p role="status" className="mt-2 text-sm text-emerald-800">{marketingNotice}</p>}
            <p className="mt-1 text-sm text-neutral-700">Your organization's address appears in campaign emails. Campaigns pause until the owner certifies a current physical postal address.</p>
            <form onSubmit={saveMarketingAddress} className="mt-4 space-y-4">
              <label className="block text-sm font-medium text-neutral-700">Physical postal address
                <textarea required rows={3} maxLength={500} className="input mt-1" value={marketingAddress}
                  onChange={event => { setMarketingAddress(event.target.value); setMarketingCertified(false) }}
                  aria-describedby="marketing-postal-hint" />
              </label>
              <p id="marketing-postal-hint" className="text-sm text-neutral-600">Include a street or PO Box, locality, and ZIP code. This address is public in every campaign email.</p>
              <label className="flex min-h-11 items-start gap-3 text-sm text-neutral-700">
                <input type="checkbox" required checked={marketingCertified} onChange={event => setMarketingCertified(event.target.checked)} className="mt-1" />
                <span>I confirm this is a valid physical postal address for {organization.name}.</span>
              </label>
              <button type="submit" className="btn-primary" disabled={busy}>Save marketing address</button>
            </form>
          </section>}
          {canManageTeam && <TeamManager basePath="/organizer/memberships" request={teamRequest} canTransfer={canTransfer} heading="Organization team"
            memberships={memberships} onMembershipsChange={setMemberships} />}
          {canManagePayouts && <TaxInformationSection request={teamRequest}
            mailingAddress={accounts.find(account => account.provider === 'check')?.payout_details?.mailing_address || ''}
            onSaved={() => { setOrganization(value => ({ ...value, payout_ready: false })); setAccounts(items => items.map(account => ({ ...account, payout_ready: false }))) }} />}
          {canManagePayouts && <PayoutMethodSection organizationId={organization.id} accounts={accounts} busy={busy} onSave={savePayout} error={payoutError} notice={notice} />}
        </div>
      )}
    </WorkspacePage>
  )
}

import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { CheckCircle2, CircleAlert, Copy, Loader2, ShieldCheck, Trash2, UserPlus, Users, WalletCards } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import apiClient from '../../api/client'
import { supportMailto } from '../../utils/supportContact'

const TEAM_ROLES = ['manager', 'finance', 'marketer', 'box_office', 'scanner']

function label(value) {
  return value?.replaceAll('_', ' ').replace(/\b\w/g, character => character.toUpperCase())
}

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
 const verifiedOwner = useRef(false)
 const requests = useRef(new Set())
 const [organization, setOrganization] = useState(null)
 const [memberships, setMemberships] = useState([])
 const [accounts, setAccounts] = useState([])
 const [email, setEmail] = useState('')
 const [role, setRole] = useState('manager')
 const [invitationUrl, setInvitationUrl] = useState('')
 const [loading, setLoading] = useState(true)
 const [busy, setBusy] = useState(false)
 const [error, setError] = useState(null)
 const [notice, setNotice] = useState(null)
 const loadGeneration = useRef(0)
 const withdrawAccess = useCallback(message => {
  ++accessEpoch.current
  verifiedOwner.current = false
  requests.current.forEach(request => request.controller.abort())
  setOrganization(null); setMemberships([]); setAccounts([]); setInvitationUrl('')
  setEmail(''); setRole('manager'); setNotice(null); setBusy(false); setLoading(false)
  setError(message)
 }, [])
 const requestApi = useCallback(async (method, url, payload, options = {}) => {
  const verifying = method === 'get' && url === '/organizer/organization'
  if (!verifying && !verifiedOwner.current) throw new DOMException('Organization access is not verified', 'AbortError')
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

  const canManage = organization?.role === 'owner' && verifiedOwner.current

  const load = useCallback(async () => {
    const generation = ++loadGeneration.current
    if (!current()) return
    const epoch = ++accessEpoch.current
    requests.current.forEach(request => request.controller.abort())
    const canApply = () => current() && generation === loadGeneration.current && epoch === accessEpoch.current
    setLoading(true)
    setBusy(false)
    setError(null)
    try {
      const organizationResponse = await requestApi('get', '/organizer/organization')
      if (!canApply()) return
      if (organizationResponse.data.id == null || (identity.organizationId != null && String(organizationResponse.data.id) !== String(identity.organizationId))) {
        withdrawAccess('The organization context could not be verified. Return to your dashboard and select it again.')
        return
      }
      verifiedOwner.current = organizationResponse.data.role === 'owner'
      setOrganization(organizationResponse.data)
      if (organizationResponse.data.role === 'owner') {
        const [membersResponse, accountsResponse] = await Promise.all([
          requestApi('get', '/organizer/memberships'),
          requestApi('get', '/organizer/connected_accounts')
        ])
        if (!canApply()) return
        setMemberships(membersResponse.data)
        setAccounts(accountsResponse.data)
      } else { setMemberships([]); setAccounts([]); setInvitationUrl(''); setNotice(null) }
    } catch (requestError) {
      if (!canApply()) return
      setError(requestError.response?.data?.error || 'Could not load organization settings.')
    } finally {
      if (canApply()) setLoading(false)
    }
  }, [requestApi, current, identity.organizationId, withdrawAccess])

  useEffect(() => { load() }, [load])

  const invite = async event => {
    event.preventDefault()
    if (!current() || !canManage || busy) return
    const epoch = accessEpoch.current
    const canApply = () => current() && epoch === accessEpoch.current
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const response = await requestApi('post', '/organizer/memberships', { email, role })
      if (!canApply()) return
      const url = `${window.location.origin}/organization-invitations/accept?token=${encodeURIComponent(response.data.invitation_token)}`
      setInvitationUrl(url)
      setEmail('')
      setMemberships(current => [...current, response.data])
      setNotice('Invitation created. Copy the secure link and send it to the invited email address.')
    } catch (requestError) {
      if (!canApply()) return
      setError(requestError.response?.data?.error || requestError.response?.data?.errors?.[0] || 'Could not create invitation.')
    } finally {
      if (canApply()) setBusy(false)
    }
  }

  const changeRole = async (membership, nextRole) => {
    if (!current() || !canManage || busy) return
    const epoch = accessEpoch.current
    const canApply = () => current() && epoch === accessEpoch.current
    setBusy(true)
    setError(null)
    try {
      const response = await requestApi('patch', `/organizer/memberships/${membership.id}`, { role: nextRole })
      if (!canApply()) return
      setMemberships(current => current.map(item => item.id === membership.id ? response.data : item))
    } catch (requestError) {
      if (!canApply()) return
      setError(requestError.response?.data?.error || requestError.response?.data?.errors?.[0] || 'Could not update role.')
    } finally {
      if (canApply()) setBusy(false)
    }
  }

  const revoke = async membership => {
    if (!current() || !canManage || busy) return
    if (!window.confirm(`Revoke ${membership.email}'s access?`)) return
    const epoch = accessEpoch.current
    const canApply = () => current() && epoch === accessEpoch.current
    setBusy(true)
    setError(null)
    try {
      await requestApi('delete', `/organizer/memberships/${membership.id}`)
      if (!canApply()) return
      setMemberships(current => current.map(item => item.id === membership.id ? { ...item, status: 'revoked' } : item))
    } catch (requestError) {
      if (!canApply()) return
      setError(requestError.response?.data?.error || 'Could not revoke access.')
    } finally {
      if (canApply()) setBusy(false)
    }
  }

  const startOnboarding = async provider => {
    if (!current() || !canManage || busy) return
    const epoch = accessEpoch.current
    const canApply = () => current() && epoch === accessEpoch.current
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const response = await requestApi('post', '/organizer/connected_accounts', { provider })
      if (!canApply()) return
      setAccounts(current => [...current.filter(account => account.provider !== provider), response.data])
      setNotice(response.data.next_action)
    } catch (requestError) {
      if (!canApply()) return
      setError(requestError.response?.data?.error || 'Could not start payout onboarding.')
    } finally {
      if (canApply()) setBusy(false)
    }
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
        description={`Team access, event staffing, and payout readiness${organization?.timezone ? ` for ${organization.timezone}` : ''}.`}
        actions={<StatusPill ready={organization?.payout_ready}>{organization?.payout_ready ? 'Paid events ready' : 'Payout setup incomplete'}</StatusPill>}
        className="!mb-0"
      />

      {error && <div role="alert" className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700"><p>{error}</p><button type="button" onClick={load} className="min-h-11 font-semibold underline">Retry organization settings</button></div>}
      {notice && <div className="mt-6 rounded-xl border border-brand-200 bg-brand-50 p-4 text-sm text-brand-800">{notice}</div>}

      {!canManage ? (
        <section className="mt-8 rounded-2xl border border-neutral-200 bg-white p-6">
          <ShieldCheck className="h-6 w-6 text-brand-600" />
          <h2 className="mt-3 text-lg font-semibold text-neutral-900">Your role: {label(organization?.role)}</h2>
          <p className="mt-1 text-sm text-neutral-600">Only the organization owner can change team roles or payout destinations. Event managers can assign event staff from each event’s Team page.</p>
        </section>
      ) : (
        <>
          <section className="mt-8 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="team-heading">
            <div className="flex items-center gap-3"><Users className="h-5 w-5 text-brand-600" /><h2 id="team-heading" className="text-lg font-semibold text-neutral-900">Organization team</h2></div>
            <p className="mt-1 text-sm text-neutral-500">Give each person only the access they need. Scanner and box-office access still requires an event assignment.</p>

            <form onSubmit={invite} className="mt-5 grid gap-3 sm:grid-cols-[1fr_11rem_auto]">
              <input type="email" required value={email} onChange={event => setEmail(event.target.value)} className="input" placeholder="teammate@example.com" aria-label="Teammate email" />
              <select value={role} onChange={event => setRole(event.target.value)} className="input" aria-label="Team role">
                {TEAM_ROLES.map(item => <option key={item} value={item}>{label(item)}</option>)}
              </select>
              <button disabled={busy} className="btn-primary inline-flex items-center justify-center gap-2"><UserPlus className="h-4 w-4" /> Invite</button>
            </form>

            {invitationUrl && (
              <div className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-emerald-800">Secure invitation link</p>
                <div className="mt-2 flex gap-2">
                  <input readOnly value={invitationUrl} className="input min-w-0 text-xs" aria-label="Invitation link" />
                  <button type="button" onClick={() => navigator.clipboard.writeText(invitationUrl)} className="rounded-xl border border-emerald-300 bg-white px-3 text-emerald-800" aria-label="Copy invitation link"><Copy className="h-4 w-4" /></button>
                </div>
              </div>
            )}

            <div className="mt-6 divide-y divide-neutral-100">
              {memberships.map(membership => (
                <div key={membership.id} className="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p className="font-medium text-neutral-900">{membership.name || membership.email}</p>
                    <p className="text-sm text-neutral-500">{membership.email} · {label(membership.status)}</p>
                  </div>
                  {membership.role === 'owner' ? <StatusPill ready>Owner</StatusPill> : (
                    <div className="flex items-center gap-2">
                      <select aria-label={`Role for ${membership.email}`} disabled={busy || membership.status === 'revoked'} value={membership.role} onChange={event => changeRole(membership, event.target.value)} className="input min-h-11 !w-auto !py-2 text-sm">
                        {TEAM_ROLES.map(item => <option key={item} value={item}>{label(item)}</option>)}
                      </select>
                      <button disabled={busy || membership.status === 'revoked'} onClick={() => revoke(membership)} className="flex min-h-11 min-w-11 items-center justify-center rounded-lg p-2 text-red-600 hover:bg-red-50" aria-label={`Revoke ${membership.email}`}><Trash2 className="h-4 w-4" /></button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </section>

          <section className="mt-8 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="payout-heading">
            <div className="flex items-center gap-3"><WalletCards className="h-5 w-5 text-brand-600" /><h2 id="payout-heading" className="text-lg font-semibold text-neutral-900">Payments and payouts</h2></div>
            <p className="mt-2 text-sm text-neutral-700">Payout setup is assisted by the HåfaPass team. Starting a review records your setup status; it does not connect a bank, send documents, or enable payments.</p>
            <article className="mt-5 rounded-xl border border-brand-200 bg-brand-50 p-4" aria-labelledby="assisted-setup-heading">
              <h3 id="assisted-setup-heading" className="font-semibold text-brand-900">Assisted local bank setup</h3>
              <ol className="mt-3 list-decimal space-y-2 pl-5 text-sm text-neutral-700">
                <li><strong>You:</strong> start a bank review, then contact the HåfaPass team to arrange a secure document handoff.</li>
                <li><strong>HåfaPass team:</strong> confirm the banking and identity documents needed for your organization and review them with you. Do not email bank details or identity documents.</li>
                <li><strong>HåfaPass finance:</strong> confirm eligibility and payment/payout readiness before paid events can go live.</li>
              </ol>
              <p className="mt-3 text-sm text-neutral-700">A response time has not been published. Ask the team for the review timeline when you contact them.</p>
              {(() => {
                const account = accounts.find(item => item.provider === 'manual')
                return <div className="mt-4 space-y-3">
                  <p className="text-sm font-medium text-neutral-900">Review status: {account ? label(account.status) : 'Not started'}</p>
                  {account && <>
                    <StatusPill ready={account.payout_ready}>{account.payout_ready ? 'Payouts ready' : 'Review required before payouts'}</StatusPill>
                    {account.requirements_due?.length > 0 && <p className="text-sm text-amber-900">Still required: {account.requirements_due.map(label).join(', ')}.</p>}
                    <p className="text-sm text-neutral-700">{account.payout_ready ? 'Contact the HåfaPass team if your banking or identity details change.' : 'Next step: contact the HåfaPass team to confirm the remaining documents and review timeline.'}</p>
                  </>}
                  <div className="flex flex-wrap gap-3">
                    {!account && <button type="button" disabled={busy} onClick={() => startOnboarding('manual')} className="btn-teal">Start bank review</button>}
                    <a className="btn-secondary" href={supportMailto(`HåfaPass payout setup — organization ${organization.id}`)}>{account ? 'Continue with HåfaPass team' : 'Contact HåfaPass team'}</a>
                  </div>
                  <p className="text-xs text-neutral-600">The contact link opens your email app. Send the message there to contact the team; no message is sent by starting a review.</p>
                </div>
              })()}
            </article>
            <details className="mt-5 rounded-xl border border-neutral-200 p-4">
              <summary className="cursor-pointer font-semibold text-neutral-800">Other provider availability</summary>
              <div className="mt-4 space-y-4">
                {['paypal', 'stripe'].map(provider => {
                  const account = accounts.find(item => item.provider === provider)
                  return <article key={provider}>
                    <h3 className="font-semibold text-neutral-900">{provider === 'paypal' ? 'PayPal' : 'Stripe'}</h3>
                    <p className="mt-1 text-sm text-neutral-700">{provider === 'paypal' ? 'Requires HåfaPass marketplace approval and seller verification. Contact the team before choosing this path.' : 'Unavailable unless Stripe confirms Guam entity and bank eligibility in writing.'}</p>
                    {account && <>
                      <p className="mt-2 text-sm">Status: {label(account.status)} · {account.payout_ready ? 'Payouts ready' : 'Payouts not ready'}</p>
                      {account.requirements_due?.length > 0 && <p className="text-sm text-amber-900">Still required: {account.requirements_due.map(label).join(', ')}.</p>}
                      <a className="mt-2 inline-flex min-h-11 items-center text-sm font-semibold text-action-teal underline" href={supportMailto(`HåfaPass ${provider} setup — organization ${organization.id}`)}>Discuss {provider === 'paypal' ? 'PayPal' : 'Stripe'} setup with HåfaPass</a>
                    </>}
                  </article>
                })}
              </div>
            </details>
          </section>
        </>
      )}
    </WorkspacePage>
  )
}

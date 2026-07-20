import { CheckCircle2, CircleAlert, Copy, Loader2, ShieldCheck, Trash2, UserPlus, Users, WalletCards } from 'lucide-react'
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'

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

  const canManage = organization?.role === 'owner'

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const organizationResponse = await apiClient.get('/organizer/organization')
      setOrganization(organizationResponse.data)
      if (organizationResponse.data.role === 'owner') {
        const [membersResponse, accountsResponse] = await Promise.all([
          apiClient.get('/organizer/memberships'),
          apiClient.get('/organizer/connected_accounts')
        ])
        setMemberships(membersResponse.data)
        setAccounts(accountsResponse.data)
      }
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'Could not load organization settings.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { load() }, [load])

  const invite = async event => {
    event.preventDefault()
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const response = await apiClient.post('/organizer/memberships', { email, role })
      const url = `${window.location.origin}/organization-invitations/accept?token=${encodeURIComponent(response.data.invitation_token)}`
      setInvitationUrl(url)
      setEmail('')
      setMemberships(current => [...current, response.data])
      setNotice('Invitation created. Copy the secure link and send it to the invited email address.')
    } catch (requestError) {
      setError(requestError.response?.data?.error || requestError.response?.data?.errors?.[0] || 'Could not create invitation.')
    } finally {
      setBusy(false)
    }
  }

  const changeRole = async (membership, nextRole) => {
    setBusy(true)
    setError(null)
    try {
      const response = await apiClient.patch(`/organizer/memberships/${membership.id}`, { role: nextRole })
      setMemberships(current => current.map(item => item.id === membership.id ? response.data : item))
    } catch (requestError) {
      setError(requestError.response?.data?.error || requestError.response?.data?.errors?.[0] || 'Could not update role.')
    } finally {
      setBusy(false)
    }
  }

  const revoke = async membership => {
    if (!window.confirm(`Revoke ${membership.email}'s access?`)) return
    setBusy(true)
    setError(null)
    try {
      await apiClient.delete(`/organizer/memberships/${membership.id}`)
      setMemberships(current => current.map(item => item.id === membership.id ? { ...item, status: 'revoked' } : item))
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'Could not revoke access.')
    } finally {
      setBusy(false)
    }
  }

  const startOnboarding = async provider => {
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const response = await apiClient.post('/organizer/connected_accounts', { provider })
      setAccounts(current => [...current.filter(account => account.provider !== provider), response.data])
      setNotice(response.data.next_action)
    } catch (requestError) {
      setError(requestError.response?.data?.error || 'Could not start payout onboarding.')
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>

  return (
    <main className="mx-auto max-w-5xl px-4 py-8 sm:px-6">
      <Link to="/dashboard" className="text-sm font-medium text-brand-600 hover:text-brand-700">← Back to dashboard</Link>
      <div className="mt-5 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-sm font-semibold uppercase tracking-wider text-brand-600">Organization</p>
          <h1 className="mt-1 text-3xl font-bold text-neutral-950">{organization?.name}</h1>
          <p className="mt-1 text-sm text-neutral-500">Team access, event staffing, and payout readiness for {organization?.timezone}.</p>
        </div>
        <StatusPill ready={organization?.payout_ready}>{organization?.payout_ready ? 'Paid events ready' : 'Payout setup incomplete'}</StatusPill>
      </div>

      {error && <div className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error}</div>}
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
                      <select disabled={busy || membership.status === 'revoked'} value={membership.role} onChange={event => changeRole(membership, event.target.value)} className="input !w-auto !py-2 text-sm">
                        {TEAM_ROLES.map(item => <option key={item} value={item}>{label(item)}</option>)}
                      </select>
                      <button disabled={busy || membership.status === 'revoked'} onClick={() => revoke(membership)} className="rounded-lg p-2 text-red-600 hover:bg-red-50" aria-label={`Revoke ${membership.email}`}><Trash2 className="h-4 w-4" /></button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </section>

          <section className="mt-8 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="payout-heading">
            <div className="flex items-center gap-3"><WalletCards className="h-5 w-5 text-brand-600" /><h2 id="payout-heading" className="text-lg font-semibold text-neutral-900">Payments and payouts</h2></div>
            <p className="mt-1 text-sm text-neutral-500">A provider is not ready until HafaPass verifies payment acceptance, identity details, and payout capability. Starting onboarding never marks an account ready.</p>

            <div className="mt-5 grid gap-4 md:grid-cols-3">
              {['paypal', 'manual', 'stripe'].map(provider => {
                const account = accounts.find(item => item.provider === provider)
                return (
                  <article key={provider} className="rounded-xl border border-neutral-200 p-4">
                    <div className="flex items-center justify-between gap-2"><h3 className="font-semibold text-neutral-900">{provider === 'manual' ? 'Local bank / manual' : label(provider)}</h3>{account && <StatusPill ready={account.payout_ready}>{label(account.status)}</StatusPill>}</div>
                    <p className="mt-2 text-xs leading-5 text-neutral-500">
                      {provider === 'paypal' && 'Preferred automation path, pending HafaPass marketplace approval and seller verification.'}
                      {provider === 'manual' && 'Pilot fallback using verified local banking details and finance reconciliation.'}
                      {provider === 'stripe' && 'Blocked unless Stripe confirms Guam entity and bank eligibility in writing.'}
                    </p>
                    {account?.requirements_due?.length > 0 && <p className="mt-3 text-xs text-amber-700">Due: {account.requirements_due.map(label).join(', ')}</p>}
                    {!account && <button disabled={busy} onClick={() => startOnboarding(provider)} className="mt-4 w-full rounded-lg border border-brand-200 px-3 py-2 text-sm font-semibold text-brand-700 hover:bg-brand-50">Start review</button>}
                  </article>
                )
              })}
            </div>
          </section>
        </>
      )}
    </main>
  )
}

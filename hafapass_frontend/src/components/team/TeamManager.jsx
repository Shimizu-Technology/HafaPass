import { Copy, Crown, Mail, RotateCw, Trash2, UserPlus, Users } from 'lucide-react'
import { useCallback, useEffect, useRef, useState } from 'react'
import Dialog from '../Dialog'
import { RoleRadioGroup, RoleSelect } from './RoleChoice'
import { INVITATION_STATUS, TEAM_ROLES, emailDeliveryLabel, invitationUrl, roleLabel } from '../../utils/roles'

const toneClass = {
  success: 'bg-emerald-50 text-emerald-800',
  warning: 'bg-amber-50 text-amber-900',
  neutral: 'bg-neutral-100 text-neutral-700',
}

export function InvitationStatusPill({ status }) {
  const meta = INVITATION_STATUS[status] || { label: status, tone: 'neutral' }
  return <span className={`inline-flex shrink-0 items-center rounded-full px-2.5 py-1 text-xs font-semibold ${toneClass[meta.tone]}`}>{meta.label}</span>
}

// Older responses carry only `status`; derive the invitation state from it.
const statusOf = membership => membership.invitation_status
  || (membership.status === 'active' ? 'accepted' : membership.status === 'revoked' ? 'revoked' : 'pending')

const formatDate = value => value ? new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) : ''
const errorMessage = (error, fallback) => error?.response?.data?.error || error?.response?.data?.errors?.[0] || fallback

// A secure link that can be copied when email is unavailable.
export function InvitationLinkPanel({ url, email, onDismiss }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try { await navigator.clipboard.writeText(url); setCopied(true) } catch { setCopied(false) }
  }
  return (
    <div className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-4">
      <p className="text-sm font-semibold text-emerald-900">Invitation link{email ? ` for ${email}` : ''}</p>
      <p className="mt-1 text-sm text-emerald-900">Share it only with that person. It works only for someone signed in with that email.</p>
      <div className="mt-2 flex gap-2">
        <input readOnly value={url} onFocus={event => event.target.select()} className="input min-w-0 text-xs" aria-label="Invitation link" />
        <button type="button" onClick={copy} className="btn-secondary shrink-0 gap-2 !px-3 text-sm" aria-label="Copy invitation link"><Copy aria-hidden="true" className="h-4 w-4" />{copied ? 'Copied' : 'Copy'}</button>
      </div>
      {onDismiss && <button type="button" onClick={onDismiss} className="mt-2 min-h-11 text-sm font-semibold text-emerald-900 underline">Done</button>}
    </div>
  )
}

// Team list, invitations and ownership for one organization. The caller
// supplies the endpoint and a request function bound to its page context,
// so the organizer Settings page and the admin console share these rules.
// Pass `memberships` and `onMembershipsChange` when the caller loads the list
// itself (Settings loads it alongside its own access check); otherwise the
// list is loaded here.
export default function TeamManager({ basePath, request, canTransfer = false, heading = 'Team', description, inviteRoles = TEAM_ROLES, onChanged, memberships: controlled, onMembershipsChange }) {
  const [ownMemberships, setOwnMemberships] = useState([])
  const isControlled = Array.isArray(controlled)
  const memberships = isControlled ? controlled : ownMemberships
  const latest = useRef(memberships)
  latest.current = memberships
  const setMemberships = useCallback(update => {
    const next = typeof update === 'function' ? update(latest.current) : update
    latest.current = next
    if (isControlled) onMembershipsChange?.(next)
    else setOwnMemberships(next)
  }, [isControlled, onMembershipsChange])
  const [loadState, setLoadState] = useState(isControlled ? 'ready' : 'loading')
  const [email, setEmail] = useState('')
  const [role, setRole] = useState('manager')
  const [busy, setBusy] = useState(false)
  const busyRef = useRef(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  const [link, setLink] = useState(null)
  const [confirm, setConfirm] = useState(null)

  const load = useCallback(async () => {
    if (isControlled) return
    setLoadState('loading')
    try {
      const response = await request('get', basePath)
      setMemberships(Array.isArray(response.data) ? response.data : [])
      setLoadState('ready')
    } catch (requestError) {
      if (requestError?.name === 'AbortError') return
      setLoadState('error')
    }
  }, [basePath, request, isControlled, setMemberships])
  useEffect(() => { load() }, [load])

  const run = async (work, fallback) => {
    if (busyRef.current) return
    busyRef.current = true
    setBusy(true); setError(null); setNotice(null)
    try { await work(); onChanged?.() } catch (requestError) {
      if (requestError?.name !== 'AbortError') setError(errorMessage(requestError, fallback))
    } finally { busyRef.current = false; setBusy(false) }
  }
  const replace = updated => setMemberships(items => items.some(item => item.id === updated.id)
    ? items.map(item => item.id === updated.id ? updated : item) : [...items, updated])

  const invite = event => {
    event.preventDefault()
    const address = email.trim()
    if (!address) return
    run(async () => {
      const response = await request('post', basePath, { email: address, role })
      replace(response.data)
      setEmail('')
      setNotice(`Invitation sent to ${response.data.email} as ${roleLabel(response.data.role)}.`)
      setLink(invitationUrl(response.data) ? { url: invitationUrl(response.data), email: response.data.email } : null)
    }, 'Could not send the invitation.')
  }
  const resend = membership => run(async () => {
    const response = await request('post', `${basePath}/${membership.id}/resend`)
    replace(response.data)
    setNotice(`A new invitation was sent to ${membership.email}. Earlier links no longer work.`)
    setLink(invitationUrl(response.data) ? { url: invitationUrl(response.data), email: membership.email } : null)
  }, 'Could not resend the invitation.')
  const copyLink = membership => run(async () => {
    const response = await request('post', `${basePath}/${membership.id}/invitation_link`)
    setLink(invitationUrl(response.data) ? { url: invitationUrl(response.data), email: membership.email } : null)
  }, 'Could not get the invitation link.')
  const changeRole = (membership, nextRole) => run(async () => {
    const response = await request('patch', `${basePath}/${membership.id}`, { role: nextRole })
    replace(response.data)
    setNotice(`${membership.name || membership.email} is now ${roleLabel(nextRole)}.`)
  }, 'Could not change the role.')
  const confirmAction = () => {
    const action = confirm
    if (!action) return
    run(async () => {
      if (action.kind === 'remove') {
        await request('delete', `${basePath}/${action.membership.id}`)
        setMemberships(items => items.map(item => item.id === action.membership.id ? { ...item, status: 'revoked', invitation_status: 'revoked' } : item))
        setNotice(statusOf(action.membership) === 'accepted' ? `${action.membership.email} no longer has access.` : `The invitation for ${action.membership.email} was cancelled.`)
      } else {
        const response = await request('post', `${basePath}/${action.membership.id}/transfer_ownership`)
        setMemberships(Array.isArray(response.data) ? response.data : [])
        setNotice(`${action.membership.name || action.membership.email} is now the owner.`)
      }
      setConfirm(null)
    }, action.kind === 'remove' ? 'Could not remove access.' : 'Could not transfer ownership.')
  }

  const active = memberships.filter(item => statusOf(item) !== 'revoked')
  const removed = memberships.filter(item => statusOf(item) === 'revoked')

  return (
    <section className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="team-heading">
      <div className="flex items-center gap-3"><Users aria-hidden="true" className="h-5 w-5 text-brand-600" /><h2 id="team-heading" className="text-lg font-semibold text-neutral-900">{heading}</h2></div>
      <p className="mt-1 text-sm text-content-muted">{description || 'Give each person only the access they need. We email the invitation; they join by signing in with that email.'}</p>

      <form onSubmit={invite} className="mt-5 space-y-4">
        <label className="block text-sm font-medium text-neutral-900">
          Teammate email
          <input type="email" required value={email} onChange={event => setEmail(event.target.value)} className="input mt-1" placeholder="teammate@example.com" autoComplete="off" disabled={busy} />
        </label>
        <RoleRadioGroup legend="Role" roles={inviteRoles} value={role} onChange={setRole} disabled={busy} name="team-invite-role" />
        <button disabled={busy || !email.trim()} className="btn-primary w-full gap-2 sm:w-auto"><UserPlus aria-hidden="true" className="h-4 w-4" />{busy ? 'Sending…' : 'Invite'}</button>
      </form>

      {error && <p role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      {notice && <p role="status" className="mt-4 rounded-xl border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">{notice}</p>}
      {link && <InvitationLinkPanel url={link.url} email={link.email} onDismiss={() => setLink(null)} />}

      {loadState === 'loading' && <p role="status" className="mt-6 text-sm text-content-muted">Loading team…</p>}
      {loadState === 'error' && <div role="alert" className="mt-6 text-sm text-red-800">The team list could not be loaded. <button type="button" onClick={load} className="min-h-11 font-semibold underline">Try again</button></div>}
      {loadState === 'ready' && (
        <ul className="mt-6 divide-y divide-neutral-100" aria-label="Team members">
          {active.map(membership => {
            const isOwner = membership.role === 'owner'
            const pending = ['pending', 'expired'].includes(statusOf(membership))
            return (
              <li key={membership.id} className="flex flex-col gap-3 py-4 lg:flex-row lg:items-start lg:justify-between">
                <div className="min-w-0">
                  <p className="flex flex-wrap items-center gap-2 font-medium text-neutral-900"><span className="[overflow-wrap:anywhere]">{membership.name || membership.email}</span><InvitationStatusPill status={statusOf(membership)} /></p>
                  {membership.name && <p className="text-sm text-content-muted [overflow-wrap:anywhere]">{membership.email}</p>}
                  {membership.pending_events?.length > 0 && <p className="mt-1 text-sm text-neutral-700">Event access on joining: {membership.pending_events.map(item => `${item.title} (${roleLabel(item.role)})`).join(', ')}</p>}
                  {statusOf(membership) === 'pending' && <p className="mt-1 text-sm text-content-muted"><Mail aria-hidden="true" className="mr-1 inline h-3.5 w-3.5" />{emailDeliveryLabel(membership.email_delivery)} Link expires {formatDate(membership.invitation_expires_at)}.</p>}
                  {statusOf(membership) === 'expired' && <p className="mt-1 text-sm text-content-muted">The invitation link expired. Resend it to email a new one.</p>}
                </div>
                <div className="flex flex-wrap items-start gap-2 lg:justify-end">
                  {isOwner ? <span className="inline-flex min-h-11 items-center gap-1.5 rounded-lg bg-emerald-50 px-3 text-sm font-semibold text-emerald-800"><Crown aria-hidden="true" className="h-4 w-4" />Owner</span>
                    : <RoleSelect label={`Role for ${membership.email}`} roles={TEAM_ROLES} value={membership.role} disabled={busy} onChange={next => changeRole(membership, next)} className="w-full sm:w-56" />}
                  {pending && <button type="button" disabled={busy} onClick={() => resend(membership)} className="btn-secondary gap-2 !px-3 !py-2 text-sm"><RotateCw aria-hidden="true" className="h-4 w-4" />Resend</button>}
                  {statusOf(membership) === 'pending' && <button type="button" disabled={busy} onClick={() => copyLink(membership)} className="btn-secondary gap-2 !px-3 !py-2 text-sm"><Copy aria-hidden="true" className="h-4 w-4" />Copy link</button>}
                  {canTransfer && !isOwner && statusOf(membership) === 'accepted' && <button type="button" disabled={busy} onClick={() => setConfirm({ kind: 'transfer', membership })} className="btn-secondary gap-2 !px-3 !py-2 text-sm"><Crown aria-hidden="true" className="h-4 w-4" />Make owner</button>}
                  {!(isOwner && statusOf(membership) === 'accepted') && <button type="button" disabled={busy} onClick={() => setConfirm({ kind: 'remove', membership })} className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-red-700 [@media(hover:hover)]:hover:bg-red-50" aria-label={pending ? `Cancel invitation for ${membership.email}` : `Remove ${membership.email}`}><Trash2 aria-hidden="true" className="h-4 w-4" /></button>}
                </div>
              </li>
            )
          })}
          {active.length === 0 && <li className="py-6 text-center text-sm text-content-muted">No one on the team yet.</li>}
        </ul>
      )}
      {removed.length > 0 && (
        <details className="mt-2 text-sm text-content-muted">
          <summary className="min-h-11 cursor-pointer py-2 font-medium">Removed or cancelled ({removed.length})</summary>
          <ul className="space-y-1">{removed.map(item => <li key={item.id} className="[overflow-wrap:anywhere]">{item.email} · {roleLabel(item.role)}</li>)}</ul>
        </details>
      )}

      {confirm && (
        <Dialog labelledBy="team-confirm-title" onClose={() => setConfirm(null)} busy={busy} className="max-w-md">
          <h2 id="team-confirm-title" className="text-lg font-semibold text-neutral-900">
            {confirm.kind === 'transfer' ? `Make ${confirm.membership.name || confirm.membership.email} the owner?` : statusOf(confirm.membership) === 'accepted' ? `Remove ${confirm.membership.email}?` : 'Cancel this invitation?'}
          </h2>
          <p className="mt-2 text-sm text-neutral-700">
            {confirm.kind === 'transfer'
              ? 'They will manage the team, payouts and all events. The current owner becomes a Manager and can no longer move money. This is recorded in the audit log.'
              : statusOf(confirm.membership) === 'accepted' ? 'They lose access to this organization and every event they were assigned to.' : 'The invitation link stops working.'}
          </p>
          {error && <p role="alert" className="mt-3 text-sm text-red-800">{error}</p>}
          <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
            <button type="button" onClick={() => setConfirm(null)} disabled={busy} className="btn-secondary">Keep as is</button>
            <button type="button" onClick={confirmAction} disabled={busy} className={confirm.kind === 'transfer' ? 'btn-primary' : 'btn-danger'}>
              {busy ? 'Saving…' : confirm.kind === 'transfer' ? 'Transfer ownership' : statusOf(confirm.membership) === 'accepted' ? 'Remove access' : 'Cancel invitation'}
            </button>
          </div>
        </Dialog>
      )}
    </section>
  )
}

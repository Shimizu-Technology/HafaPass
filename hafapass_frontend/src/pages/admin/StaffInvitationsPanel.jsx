import { useCallback, useEffect, useRef, useState } from 'react'
import { RotateCw, ShieldPlus, Trash2 } from 'lucide-react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'
import { RoleRadioGroup } from '../../components/team/RoleChoice'
import { InvitationLinkPanel, InvitationStatusPill } from '../../components/team/TeamManager'
import { emailDeliveryLabel, roleLabel } from '../../utils/roles'

const STAFF_ROLES = ['support', 'admin']
const STATUS = { pending: 'pending', accepted: 'accepted', expired: 'expired', revoked: 'revoked' }

// Invite HåfaPass staff by email. The role is applied only once the person
// signs in with that verified email.
export default function StaffInvitationsPanel({ beginRequest }) {
  // Closed until an admin asks for it, so the user list loads on its own.
  const [open, setOpen] = useState(false)
  const [invitations, setInvitations] = useState([])
  const [status, setStatus] = useState('loading')
  const [email, setEmail] = useState('')
  const [role, setRole] = useState('support')
  const [busy, setBusy] = useState(false)
  const busyRef = useRef(false)
  const [error, setError] = useState(null)
  const [notice, setNotice] = useState(null)
  const [link, setLink] = useState(null)

  const load = useCallback(() => {
    const request = beginRequest()
    if (!request) return
    apiClient.get('/admin/platform_invitations', request.config)
      .then(response => { if (request.current()) { setInvitations(response.data.invitations || []); setStatus('ready') } })
      .catch(requestError => { if (request.current() && !request.handleError(requestError)) setStatus('error') })
      .finally(() => request.release())
  }, [beginRequest])
  useEffect(() => { if (open) load() }, [load, open])

  const run = async (send, onDone, fallback) => {
    if (busyRef.current) return
    const request = beginRequest()
    if (!request) return
    busyRef.current = true
    setBusy(true); setError(null); setNotice(null)
    try {
      const response = await send(request.config)
      if (request.current()) onDone(response.data)
    } catch (requestError) {
      if (!request.handleError(requestError) && request.current()) setError(requestError.response?.data?.error || fallback)
    } finally { request.release(); busyRef.current = false; setBusy(false) }
  }
  const upsert = invitation => setInvitations(items => [invitation, ...items.filter(item => item.id !== invitation.id)])

  const invite = event => {
    event.preventDefault()
    if (!email.trim()) return
    run(config => apiClient.post('/admin/platform_invitations', { email: email.trim(), role }, config), invitation => {
      upsert(invitation); setEmail('')
      setNotice(`Invitation sent to ${invitation.email} as ${roleLabel(invitation.role)}. Their access starts when they sign in with that email.`)
      if (invitation.accept_url) setLink({ url: invitation.accept_url, email: invitation.email })
    }, 'The invitation could not be sent.')
  }
  const resend = invitation => run(config => apiClient.post(`/admin/platform_invitations/${invitation.id}/resend`, {}, config), updated => {
    upsert(updated); setNotice(`A new invitation was sent to ${updated.email}.`)
    if (updated.accept_url) setLink({ url: updated.accept_url, email: updated.email })
  }, 'The invitation could not be resent.')
  const revoke = invitation => run(config => apiClient.delete(`/admin/platform_invitations/${invitation.id}`, config), updated => {
    upsert(updated); setNotice(`The invitation for ${updated.email} was cancelled.`)
  }, 'The invitation could not be cancelled.')

  const waiting = invitations.filter(item => ['pending', 'expired'].includes(item.status))
  const recent = invitations.filter(item => !['pending', 'expired'].includes(item.status)).slice(0, 5)
  return (
    <section className="mb-6 rounded-xl border border-neutral-200 bg-white p-5" aria-labelledby="staff-invite-heading">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 id="staff-invite-heading" className="flex items-center gap-2 font-semibold text-neutral-900"><ShieldPlus aria-hidden="true" className="h-5 w-5 text-brand-600" />HåfaPass staff</h2>
          <p className="mt-1 text-sm text-content-muted">Invite Admins or Support by email. For organizer teams, use <Link to="/admin/organizations" className="font-semibold text-action-teal underline">Organizations</Link> — organizer access comes from organization membership, not a platform role.</p>
        </div>
        <button type="button" aria-expanded={open} aria-controls="staff-invite-body" onClick={() => setOpen(value => !value)} className="btn-secondary shrink-0">{open ? 'Close' : 'Invite staff'}</button>
      </div>
      {open && <div id="staff-invite-body">
      <form onSubmit={invite} className="mt-4 space-y-4">
        <label className="block text-sm font-medium text-neutral-900">
          Email
          <input type="email" required value={email} onChange={event => setEmail(event.target.value)} disabled={busy} className="input mt-1" placeholder="name@example.com" autoComplete="off" />
        </label>
        <RoleRadioGroup legend="Role" roles={STAFF_ROLES} value={role} onChange={setRole} disabled={busy} name="staff-invite-role" />
        {role === 'admin' && <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Admins have full platform access, including money and settings.</p>}
        <button disabled={busy || !email.trim()} className="btn-primary w-full sm:w-auto">{busy ? 'Sending…' : 'Send invitation'}</button>
      </form>
      {error && <p role="alert" className="mt-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p>}
      {notice && <p role="status" className="mt-4 rounded-lg border border-brand-200 bg-brand-50 p-3 text-sm text-brand-900">{notice}</p>}
      {link && <InvitationLinkPanel url={link.url} email={link.email} onDismiss={() => setLink(null)} />}
      {status === 'loading' && <p role="status" className="mt-4 text-sm text-content-muted">Loading staff invitations…</p>}
      {status === 'ready' && invitations.length === 0 && <p className="mt-4 text-sm text-content-muted">No staff invitations yet.</p>}
      {status === 'error' && <p role="alert" className="mt-4 text-sm text-red-800">Staff invitations could not be loaded. <button type="button" onClick={load} className="min-h-11 font-semibold underline">Try again</button></p>}
      {waiting.length > 0 && (
        <ul className="mt-5 divide-y divide-neutral-100 border-t border-neutral-100" aria-label="Open staff invitations">
          {waiting.map(invitation => (
            <li key={invitation.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0">
                <p className="flex flex-wrap items-center gap-2 text-sm font-medium text-neutral-900"><span className="[overflow-wrap:anywhere]">{invitation.email}</span><span className="text-content-muted">· {roleLabel(invitation.role)}</span><InvitationStatusPill status={STATUS[invitation.status]} /></p>
                <p className="text-xs text-content-muted">{invitation.status === 'expired' ? 'The link expired. Resend to email a new one.' : emailDeliveryLabel(invitation.email_delivery)}</p>
              </div>
              <div className="flex gap-2">
                <button type="button" disabled={busy} onClick={() => resend(invitation)} className="btn-secondary gap-2 !px-3 !py-2 text-sm"><RotateCw aria-hidden="true" className="h-4 w-4" />Resend</button>
                {invitation.accept_url && <button type="button" disabled={busy} onClick={() => setLink({ url: invitation.accept_url, email: invitation.email })} className="btn-secondary !px-3 !py-2 text-sm">Copy link</button>}
                <button type="button" disabled={busy} onClick={() => revoke(invitation)} aria-label={`Cancel invitation for ${invitation.email}`} className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-red-700 [@media(hover:hover)]:hover:bg-red-50"><Trash2 aria-hidden="true" className="h-4 w-4" /></button>
              </div>
            </li>
          ))}
        </ul>
      )}
      {recent.length > 0 && (
        <details className="mt-3 text-sm text-content-muted">
          <summary className="min-h-11 cursor-pointer py-2 font-medium">Recently accepted or cancelled</summary>
          <ul className="space-y-1">{recent.map(item => <li key={item.id} className="[overflow-wrap:anywhere]">{item.email} · {roleLabel(item.role)} · {item.status === 'accepted' ? 'Accepted' : 'Cancelled'}</li>)}</ul>
        </details>
      )}
      </div>}
    </section>
  )
}

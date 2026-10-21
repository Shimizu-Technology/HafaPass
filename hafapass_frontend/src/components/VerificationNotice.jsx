import { useState } from 'react'
import { Clock3 } from 'lucide-react'
import apiClient from '../api/client'
import SupportLink from './SupportLink'

const formatTime = value => {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  return date.toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' })
}

// Where HåfaPass verification of the organizer stands. Ticket sales start once
// HåfaPass verifies the organization; the owner requests it with the same
// endpoint as the dashboard's organizer readiness checks. `profile` is the
// GET /organizer_profile payload. `showSummary={false}` drops the "Waiting…"
// sentence when the surrounding text already says it, and `inline` drops the
// notice box when it sits inside another one.
export default function VerificationNotice({ profile, beginRequest, onUpdated, showSummary = true, inline = false, className = '' }) {
  const [updated, setUpdated] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const current = updated || profile
  const status = current?.verification_status
  if (!status || status === 'verified') return null

  const owner = current.organization?.role === 'owner'
  const requestVerification = async () => {
    if (busy) return
    const request = beginRequest?.()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post('/organizer_profile/submit_verification', {}, request.config)
      if (!request.current()) return
      setUpdated({ ...current, verification_requested_at: new Date().toISOString(), ...response.data, verification_status: response.data?.verification_status || 'pending' })
      onUpdated?.(response.data)
    } catch (failure) {
      if (!request.current()) return
      setError(failure.response?.data?.error || failure.response?.data?.errors?.join(' ') || 'The request was not sent. Check your connection and try again.')
    } finally {
      request.release()
      if (request.current()) setBusy(false)
    }
  }

  const notes = current.verification_notes
  const note = notes && <p className="mt-1 whitespace-pre-wrap [overflow-wrap:anywhere]">{notes}</p>
  let body
  if (status === 'pending') {
    const requestedAt = formatTime(current.verification_requested_at)
    body = <p className="flex items-start gap-2"><Clock3 aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />
      <span>Verification requested{requestedAt ? ` ${requestedAt}` : ''}. HåfaPass will review it soon.</span></p>
  } else if (status === 'suspended') {
    body = <>
      <p className="font-semibold">HåfaPass paused sales for your organization.</p>
      {note}
      <SupportLink subject="HåfaPass organizer verification" className="btn-secondary mt-3 min-h-11 text-sm">Contact HåfaPass</SupportLink>
    </>
  } else {
    body = <>
      {showSummary && <p>Waiting for HåfaPass to verify your organization before tickets go on sale.</p>}
      {status === 'rejected' && <>{<p className={showSummary ? 'mt-1' : ''}>HåfaPass could not verify your organization yet.</p>}{note}</>}
      {owner
        ? <button type="button" disabled={busy} onClick={requestVerification} className={`btn-secondary min-h-11 text-sm ${showSummary || status === 'rejected' ? 'mt-3' : ''}`}>
          {busy ? 'Sending…' : 'Request verification'}
        </button>
        : <p className={showSummary || status === 'rejected' ? 'mt-1' : ''}>Ask the organization owner to request verification.</p>}
    </>
  }
  return <div className={`${inline ? '' : 'rounded-xl border border-amber-200 bg-amber-50 p-3 '}text-sm text-amber-950 ${className}`}>
    {body}
    {error && <p role="alert" className="mt-2 text-red-800">{error}</p>}
  </div>
}

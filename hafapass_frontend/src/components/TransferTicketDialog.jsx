import { useRef, useState } from 'react'
import Dialog from './Dialog'

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

// One send flow for every place a holder can transfer a ticket. `onSend`
// performs the request and rejects with the API error so the form keeps the
// typed address for a retry.
export default function TransferTicketDialog({ ticketLabel, onSend, onClose }) {
  const [email, setEmail] = useState('')
  const [name, setName] = useState('')
  const [error, setError] = useState(null)
  const [sending, setSending] = useState(false)
  const [sentTo, setSentTo] = useState(null)
  const emailRef = useRef(null)

  async function submit(event) {
    event.preventDefault()
    if (sending) return
    const recipient = email.trim()
    if (!EMAIL_PATTERN.test(recipient)) { setError('Enter the recipient’s email address.'); emailRef.current?.focus(); return }
    setSending(true)
    setError(null)
    try {
      await onSend({ recipient_email: recipient, recipient_name: name.trim() || undefined })
      setSentTo(recipient)
    } catch (err) {
      setError(err.response?.data?.error || 'We could not send this transfer. Check your connection and try again.')
      // The address is the only field the server rejects; return focus to it
      // once the inputs are enabled again.
      setTimeout(() => emailRef.current?.focus(), 0)
    } finally {
      setSending(false)
    }
  }

  if (sentTo) {
    // A separate Dialog instance (key) so focus moves into the confirmation
    // and the focus trap restarts instead of falling back to the page.
    return <Dialog key="sent" labelledBy="transfer-ticket-title" onClose={onClose} className="max-w-md">
      <h2 id="transfer-ticket-title" className="text-lg font-semibold text-neutral-900">Transfer sent</h2>
      <p className="mt-2 text-sm text-neutral-600">We emailed <strong className="break-all text-neutral-900">{sentTo}</strong> a link to accept {ticketLabel}. Your ticket keeps working until they accept. After that, your QR code stops working and theirs is the one to scan.</p>
      <div className="mt-6 flex justify-end"><button type="button" className="btn-primary min-h-11 px-5" onClick={onClose}>Done</button></div>
    </Dialog>
  }

  return <Dialog key="form" labelledBy="transfer-ticket-title" onClose={onClose} busy={sending} className="max-w-md">
    <form onSubmit={submit} noValidate>
      <h2 id="transfer-ticket-title" className="text-lg font-semibold text-neutral-900">Transfer {ticketLabel}</h2>
      <p className="mt-1 text-sm text-neutral-600">The recipient signs in with this email to accept. Transfers close when the event starts.</p>
      <label htmlFor="transfer-recipient-email" className="mt-5 block text-sm font-medium text-neutral-700">Recipient email</label>
      <input ref={emailRef} id="transfer-recipient-email" type="email" inputMode="email" autoComplete="email" className={`input mt-1 ${error ? 'input-error' : ''}`} value={email} onChange={event => { setEmail(event.target.value); setError(null) }} aria-invalid={Boolean(error)} aria-describedby={error ? 'transfer-ticket-error' : undefined} disabled={sending} required />
      <label htmlFor="transfer-recipient-name" className="mt-4 block text-sm font-medium text-neutral-700">Recipient name <span className="font-normal text-neutral-500">(optional)</span></label>
      <input id="transfer-recipient-name" type="text" autoComplete="name" className="input mt-1" value={name} onChange={event => setName(event.target.value)} disabled={sending} maxLength={120} />
      {error && <p id="transfer-ticket-error" role="alert" className="mt-3 text-sm text-red-700">{error}</p>}
      <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button type="button" className="btn-secondary min-h-11 px-5" onClick={onClose} disabled={sending}>Cancel</button>
        <button type="submit" className="btn-primary min-h-11 px-5" disabled={sending}>{sending ? 'Sending…' : 'Send transfer'}</button>
      </div>
    </form>
  </Dialog>
}

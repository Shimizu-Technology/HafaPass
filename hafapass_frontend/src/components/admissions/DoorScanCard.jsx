import { CheckCircle2, LogOut } from 'lucide-react'

export default function DoorScanCard({ ticket, verifying = false, preview = false, exitMode = false, badge = null, titleId, onConfirm, onCancel, busy = false }) {
  const base = 'flex w-full flex-col items-center gap-4 text-center [overflow-wrap:anywhere]'
  const action = 'flex min-h-14 w-full items-center justify-center rounded-xl px-4 py-3 text-base font-bold'
  const focus = 'focus-visible:outline focus-visible:outline-4 focus-visible:outline-offset-4 focus-visible:outline-white'
  const confirmClasses = `${action} bg-amber-300 text-neutral-950 ${focus}`
  const cancelClasses = `${action} border-2 border-white text-white ${focus}`
  const confirmText = busy ? 'Checking ticket…' : 'Confirm & Admit'
  const cancelText = 'Do Not Admit / Cancel'
  const AlertBanner = preview ? 'p' : 'h2'
  const surface = verifying ? 'bg-neutral-950 text-white' : exitMode ? 'bg-sky-800 text-white' : 'bg-emerald-800 text-white'
  const pillSurface = verifying ? 'bg-white text-neutral-950' : exitMode ? 'bg-sky-950 text-white' : 'bg-emerald-950 text-white'
  const fieldsSurface = verifying ? 'bg-white/10' : exitMode ? 'bg-sky-950/80' : 'bg-emerald-950/80'

  return (
    <div className={`${base} ${preview ? 'px-4 py-5' : 'mx-auto max-w-xl px-5 py-6 sm:px-8'} ${surface}`}>
      {verifying ? (
        <AlertBanner id={titleId} className={`w-full rounded-xl bg-amber-300 px-4 py-3 font-black text-neutral-950 ${preview ? 'text-lg' : 'text-2xl sm:text-4xl'}`}>
          {ticket?.door_alert_label || 'VERIFY AT DOOR'}
        </AlertBanner>
      ) : exitMode ? (
        <p className={`flex items-center gap-2 font-display font-bold ${preview ? 'text-xl' : 'text-3xl sm:text-5xl'}`}>
          <LogOut aria-hidden="true" className={preview ? 'h-6 w-6' : 'h-9 w-9'} /> Exited
        </p>
      ) : (
        <p className={`flex items-center gap-2 font-display font-bold ${preview ? 'text-xl' : 'text-3xl sm:text-5xl'}`}>
          <CheckCircle2 aria-hidden="true" className={preview ? 'h-6 w-6' : 'h-9 w-9'} /> {badge || 'Admitted'}
        </p>
      )}
      {(ticket?.ticket_type_name || ticket?.ticket_type) && (
        <p className={`max-w-full rounded-full px-4 py-2 font-bold ${pillSurface} ${preview ? 'text-base' : 'text-xl sm:text-2xl'}`}>
          {ticket.ticket_type_name || ticket.ticket_type}
        </p>
      )}
      {ticket?.attendee_name && (
        <p className={`font-display font-bold ${preview ? 'text-2xl' : 'text-3xl sm:text-5xl'}`}>
          {verifying && 'For: '}{ticket.attendee_name}
        </p>
      )}
      {ticket?.seat && ticket.ticket_type_name && <p className="text-base font-semibold">{ticket.seat}</p>}
      {ticket?.door_fields?.length > 0 && (
        <dl className={`w-full space-y-2 rounded-xl px-4 py-3 ${fieldsSurface}`}>
          {ticket.door_fields.map(({ label, value }, index) => (
            <div key={index} className={preview ? 'text-base' : 'text-lg sm:text-xl'}>
              <dt className="inline">{label}: </dt>
              <dd className="inline font-bold">{value}</dd>
            </div>
          ))}
        </dl>
      )}
      {ticket?.buyer_name && <p className="text-base">Bought by {ticket.buyer_name}</p>}
      {ticket?.door_instructions && <p className="whitespace-pre-line text-base font-semibold sm:text-lg">{ticket.door_instructions}</p>}
      {verifying && (
        <div className="grid w-full gap-3">
          {preview ? <><span className={confirmClasses}>{confirmText}</span><span className={cancelClasses}>{cancelText}</span></> : (
            <>
              <button type="button" onClick={onConfirm} aria-disabled={busy} className={confirmClasses}>{confirmText}</button>
              <button type="button" onClick={onCancel} aria-disabled={busy} className={cancelClasses}>{cancelText}</button>
            </>
          )}
        </div>
      )}
    </div>
  )
}

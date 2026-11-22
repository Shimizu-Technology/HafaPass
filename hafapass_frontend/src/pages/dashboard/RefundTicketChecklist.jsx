import { formatEventTime } from '../../utils/eventTime'
import { formatDollars, pluralize } from '../../utils/eventToolFormat'

const ticketStatus = (ticket, timeZone) => {
 if (ticket.checked_in) {
  const time = formatEventTime(ticket.checked_in_at, timeZone, { includeZone: false })
  return time ? `Used at ${time} — cannot cancel` : 'Used — cannot cancel'
 }
 return ticket.unavailable_reason || 'Active'
}

export default function RefundTicketChecklist({ options, selectedIds, onToggle, timeZone, disabled }) {
 return (
  <fieldset className="space-y-2" disabled={disabled}>
   <legend className="mb-2 font-semibold text-neutral-900">Choose tickets</legend>
   {options.tickets.map(ticket => (
    <label key={ticket.id} className={`flex min-h-12 items-start gap-3 rounded-lg border p-3 ${ticket.selectable ? 'cursor-pointer border-neutral-500' : 'border-neutral-300 bg-neutral-50'}`}>
     <input type="checkbox" className="mt-1 h-5 w-5 shrink-0 accent-brand-700 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      checked={selectedIds.includes(ticket.id)} disabled={!ticket.selectable} onChange={() => onToggle(ticket.id)} />
     <span className="flex min-w-0 flex-1 flex-wrap items-start justify-between gap-x-3 gap-y-2">
      <span className="min-w-0 break-words text-neutral-900">
       <span className="font-semibold">{ticket.ticket_type_name}</span>
       {ticket.attendee_name && <> · {ticket.attendee_name}</>}
       {ticket.is_pass_parent && <> · {pluralize(ticket.included_nights_count, 'night')}</>}
       {ticket.code && <span className="block break-all text-neutral-700">{ticket.code}</span>}
      </span>
      <span className="flex flex-wrap items-baseline gap-2">
       <span className="font-semibold text-neutral-900">{formatDollars(ticket.refundable_cents)}</span>
       <span className={`rounded-md px-2 py-0.5 font-medium ${ticket.selectable ? 'bg-green-50 text-green-900' : 'bg-neutral-200 text-neutral-900'}`}>
        {ticketStatus(ticket, timeZone)}
       </span>
      </span>
     </span>
    </label>
   ))}
   {!options.tickets.length && <p className="text-neutral-700">There are no tickets on this order.</p>}
  </fieldset>
 )
}

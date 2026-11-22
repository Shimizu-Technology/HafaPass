import { useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { ArrowRight, Calendar, ChevronDown, Download, MapPin, Sparkles, Ticket } from 'lucide-react'
import { DEFAULT_EVENT_TIME_ZONE, formatEventDate, formatEventTime, formatEventTimeRange } from '../utils/eventTime'
import { childTicketHref, getChildNightStatus, selectSpotlightNight } from '../utils/passTicket'

export default function PassTicketCard({
  ticket,
  event: fallbackEvent,
  orderId,
  now,
  showSummaryBanner = false,
  actions = null,
}) {
  const [expanded, setExpanded] = useState(false)
  const scheduleId = useId()
  const currentTime = now || new Date()

  const parentEvent = ticket.event || fallbackEvent
  const childTickets = ticket.child_tickets || []
  const nightsCount = ticket.pass_nights_count ?? childTickets.length
  const { kind, ticket: spotlight, ordered } = selectSpotlightNight(childTickets, currentTime)
  const spotlightStatus = spotlight ? getChildNightStatus(spotlight, currentTime) : null
  const spotlightHref = spotlight ? childTicketHref(spotlight, orderId) : null

  const spotlightHeading = kind === 'tonight'
    ? "Tonight's Ticket"
    : kind === 'next'
      ? 'Next Included Night'
      : 'Latest Included Night'

  return (
    <article
      className="rounded-2xl border border-neutral-200 bg-white shadow-soft overflow-hidden tabular-nums"
      aria-label={`${ticket.ticket_type?.name || 'Multi-Night Pass'} pass card`}
    >
      {showSummaryBanner && (
        <div role="status" className="border-b border-brand-200 bg-brand-50 px-4 py-3 text-sm text-brand-950 sm:px-5">
          This is your Multi-Night Pass summary. Open an individual night&apos;s ticket below to scan at the door.
        </div>
      )}

      {/* Pass Header */}
      <div className="border-b border-neutral-100 px-4 py-4 sm:px-5">
        <div className="flex flex-wrap items-center gap-2">
          <span className="inline-flex items-center gap-1.5 rounded-full border border-brand-200 bg-brand-50 px-2.5 py-0.5 text-xs font-semibold text-brand-900">
            <Sparkles aria-hidden="true" className="h-3.5 w-3.5" />
            Multi-Night Pass · {nightsCount} {nightsCount === 1 ? 'night' : 'nights'}
          </span>
          {ticket.status === 'cancelled' && (
            <span className="inline-flex items-center rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-semibold text-red-800">
              Cancelled
            </span>
          )}
          {ticket.admission_block_reason && ticket.status !== 'cancelled' && (
            <span className="inline-flex items-center rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-semibold text-amber-900">
              {ticket.admission_block_reason.toLowerCase().includes('refund') ? 'Refund Pending' : 'Access Paused'}
            </span>
          )}
        </div>

        <div className="mt-2 min-w-0">
          {parentEvent?.title && (
            <h2 className="font-display text-xl font-bold leading-snug text-neutral-950 [overflow-wrap:anywhere]">
              {parentEvent.slug ? (
                <Link to={`/events/${parentEvent.slug}`} className="hover:text-brand-800 hover:underline">
                  {parentEvent.title}
                </Link>
              ) : parentEvent.title}
            </h2>
          )}
          <p className="mt-0.5 text-sm font-semibold text-brand-800 [overflow-wrap:anywhere]">
            {ticket.ticket_type?.name || 'Multi-Night Pass'}
          </p>
          {ticket.attendee_name && (
            <p className="mt-0.5 text-xs text-neutral-600 [overflow-wrap:anywhere]">{ticket.attendee_name}</p>
          )}
        </div>

        {ticket.admission_block_reason && (
          <p className="mt-2 rounded-xl bg-amber-50 px-3 py-2 text-xs text-amber-950">
            {ticket.admission_block_reason}
          </p>
        )}
      </div>

      {/* Tonight's Ticket / Next Night Spotlight */}
      {spotlight ? (
        <div className="bg-surface px-4 py-4 sm:px-5">
          <div className="rounded-xl border border-brand-200/80 bg-white p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="text-xs font-semibold uppercase tracking-wide text-brand-800">
                {spotlightHeading}
              </p>
              {spotlightStatus && (
                <span className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold ${spotlightStatus.className}`}>
                  {spotlightStatus.label}
                </span>
              )}
            </div>

            <p className="mt-1.5 text-base font-bold text-neutral-950 [overflow-wrap:anywhere]">
              {spotlight.event?.title}
            </p>

            <div className="mt-2 space-y-1 text-sm text-neutral-600">
              {spotlight.event?.starts_at && (
                <p className="flex items-start gap-2">
                  <Calendar aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
                  <span className="min-w-0 [overflow-wrap:anywhere]">
                    {formatEventDate(spotlight.event.starts_at, spotlight.event.timezone || DEFAULT_EVENT_TIME_ZONE, { weekday: 'short' })}
                    {' · '}
                    {formatEventTimeRange(spotlight.event.starts_at, spotlight.event.ends_at, spotlight.event.timezone || DEFAULT_EVENT_TIME_ZONE)}
                  </span>
                </p>
              )}
              {spotlight.event?.venue_name && (
                <p className="flex items-start gap-2">
                  <MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-brand-700" />
                  <span className="min-w-0 [overflow-wrap:anywhere]">{spotlight.event.venue_name}</span>
                </p>
              )}
            </div>

            {spotlight.admission_block_reason && (
              <p className="mt-2 text-xs text-amber-900">{spotlight.admission_block_reason}</p>
            )}

            <div className="mt-4 flex flex-wrap items-center gap-2">
              {spotlightHref ? (
                <Link
                  to={spotlightHref}
                  className="btn-primary min-h-11 w-full justify-center gap-2 text-sm sm:w-auto"
                >
                  <Ticket aria-hidden="true" className="h-4 w-4 shrink-0" />
                  Open Door QR / Ticket
                  <ArrowRight aria-hidden="true" className="h-4 w-4 shrink-0" />
                </Link>
              ) : (
                <p className="text-xs text-neutral-600">
                  This night&apos;s ticket link is unavailable (cancelled, transferred, or pending review). Check your confirmation email or contact the organizer.
                </p>
              )}

              {spotlight.pdf_url && (
                <a
                  href={spotlight.pdf_url}
                  className="btn-secondary min-h-11 gap-1.5 text-xs"
                >
                  <Download aria-hidden="true" className="h-3.5 w-3.5" />
                  PDF
                </a>
              )}
              {spotlight.apple_wallet_url && (
                <a href={spotlight.apple_wallet_url} className="btn-secondary min-h-11 text-xs">
                  Apple Wallet
                </a>
              )}
              {spotlight.google_wallet_url && (
                <a href={spotlight.google_wallet_url} className="btn-secondary min-h-11 text-xs">
                  Google Wallet
                </a>
              )}
            </div>
          </div>
        </div>
      ) : (
        <div className="bg-surface px-4 py-4 text-sm text-neutral-600 sm:px-5">
          {ticket.status === 'cancelled' || ticket.refund_pending || (ticket.admission_block_reason || '').toLowerCase().includes('refund')
            ? 'This pass has been cancelled and its included nights are no longer valid.'
            : 'Included night tickets will appear here once issued.'}
        </div>
      )}

      {/* Expandable Night Schedule */}
      {ordered.length > 0 && (
        <div className="border-t border-neutral-100 px-4 py-2 sm:px-5">
          <button
            type="button"
            aria-expanded={expanded}
            aria-controls={scheduleId}
            onClick={() => setExpanded(prev => !prev)}
            className="flex min-h-11 w-full items-center justify-between gap-2 text-left text-sm font-semibold text-neutral-800 hover:text-brand-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus rounded-lg"
          >
            <span>All included nights ({ordered.length})</span>
            <ChevronDown
              aria-hidden="true"
              className={`h-4 w-4 shrink-0 text-neutral-500 transition-transform ${expanded ? 'rotate-180' : ''}`}
            />
          </button>

          {expanded && (
            <ul id={scheduleId} className="mt-2 divide-y divide-neutral-100 border-t border-neutral-100 pb-2">
              {ordered.map(child => {
                const status = getChildNightStatus(child, currentTime)
                const tz = child.event?.timezone || DEFAULT_EVENT_TIME_ZONE
                const href = childTicketHref(child, orderId)
                const canOpen = Boolean(href) && (child.status === 'issued' || child.status === 'checked_in')
                return (
                  <li key={child.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="text-sm font-semibold text-neutral-900 [overflow-wrap:anywhere]">
                          {child.event?.title}
                        </p>
                        <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${status.className}`}>
                          {status.label}
                        </span>
                      </div>
                      {child.event?.starts_at && (
                        <p className="mt-0.5 text-xs text-neutral-600">
                          {formatEventDate(child.event.starts_at, tz, { weekday: 'short' })} · {formatEventTime(child.event.starts_at, tz)}
                        </p>
                      )}
                      {child.admission_block_reason && (
                        <p className="mt-0.5 text-xs text-amber-800">{child.admission_block_reason}</p>
                      )}
                    </div>
                    {canOpen && (
                      <Link
                        to={href}
                        aria-label={`View Ticket for ${child.event?.title || `night #${child.id}`}`}
                        className="inline-flex min-h-11 shrink-0 items-center gap-1 rounded-lg px-2.5 text-sm font-semibold text-brand-800 hover:bg-brand-50"
                      >
                        View Ticket
                        <ArrowRight aria-hidden="true" className="h-3.5 w-3.5" />
                      </Link>
                    )}
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      )}

      {actions && (
        <div className="border-t border-neutral-100 bg-neutral-50 px-4 py-3 sm:px-5">
          {actions}
        </div>
      )}
    </article>
  )
}

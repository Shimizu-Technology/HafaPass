import { Link } from 'react-router-dom'
import { formatEventDate } from '../utils/eventTime'

export default function EventAccessNotice({ event, message = 'Your event access does not include editing.' }) {
  return <section className="mx-auto max-w-2xl px-4 py-8">
    <h1 className="text-2xl font-bold text-neutral-900">{event?.title || 'Event access'}</h1>
    <p className="mt-3 text-neutral-600" role="status">{message}</p>
    {event?.starts_at && <p className="mt-3 text-neutral-600">{formatEventDate(event.starts_at, event.timezone)} {event.venue_name && `· ${event.venue_name}`}</p>}
    <div className="mt-6 flex flex-wrap gap-3">
      {event?.permissions?.scan && <Link className="btn-primary" to={`/dashboard/scanner?event=${event.id}`}>Scan tickets for this event</Link>}
      {event?.permissions?.box_office && <Link className="btn-secondary" to={`/dashboard/events/${event.id}/box-office`}>Open box office</Link>}
      {event?.permissions?.view_finance && <Link className="btn-secondary" to={`/dashboard/events/${event.id}/analytics`}>View finances</Link>}
      <Link className="btn-secondary" to="/dashboard">Back to dashboard</Link>
    </div>
  </section>
}

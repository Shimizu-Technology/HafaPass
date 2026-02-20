import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { Calendar, MapPin, Clock, AlertTriangle, Loader2 } from 'lucide-react'
import { motion } from 'framer-motion'
import api from '../api/client'
import QRCode from '../components/QRCode'

export default function TicketPage() {
  const { qrCode } = useParams()
  const [ticket, setTicket] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    async function fetchTicket() {
      try {
        setLoading(true)
        setError(null)
        const response = await api.get(`/tickets/${qrCode}`)
        setTicket(response.data)
      } catch (err) {
        if (err.response?.status === 404) {
          setError('Ticket not found.')
        } else {
          setError('Failed to load ticket. Please try again.')
        }
      } finally {
        setLoading(false)
      }
    }
    fetchTicket()
  }, [qrCode])

  if (loading) {
    return (
      <div className="flex justify-center items-center min-h-[60vh]">
        <Loader2 className="w-10 h-10 text-brand-500 animate-spin" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-md mx-auto px-4 py-12 text-center">
        <div className="card p-8">
          <AlertTriangle className="w-12 h-12 text-red-400 mx-auto mb-3" />
          <p className="text-red-700 font-medium mb-4">{error}</p>
          <Link to="/events" className="btn-primary text-sm">
            Browse Events
          </Link>
        </div>
      </div>
    )
  }

  const { event, ticket_type } = ticket

  const formatDate = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleDateString('en-US', {
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
    })
  }

  const formatTime = (dateStr) => {
    const date = new Date(dateStr)
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
    })
  }

  const statusConfig = {
    issued: { label: 'Valid', bg: 'bg-emerald-50', text: 'text-emerald-700', border: 'border-emerald-200', dot: 'bg-emerald-500' },
    checked_in: { label: 'Used', bg: 'bg-neutral-100', text: 'text-neutral-600', border: 'border-neutral-200', dot: 'bg-neutral-400' },
    cancelled: { label: 'Cancelled', bg: 'bg-red-50', text: 'text-red-700', border: 'border-red-200', dot: 'bg-red-500' },
    transferred: { label: 'Transferred', bg: 'bg-amber-50', text: 'text-amber-700', border: 'border-amber-200', dot: 'bg-amber-500' },
  }

  const status = statusConfig[ticket.status] || statusConfig.issued

  return (
    <div className="min-h-[60vh] flex items-center justify-center px-3 sm:px-4 py-8">
      <motion.div
        className="w-full max-w-[360px] sm:max-w-sm"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
      >
        <div className="card overflow-hidden shadow-lg">
          {/* Status Badge */}
          <div className={`px-4 py-2.5 ${status.bg} ${status.border} border-b text-center`}>
            <span className={`inline-flex items-center gap-2 text-sm font-semibold ${status.text}`}>
              <span className={`w-2 h-2 rounded-full ${status.dot} ${ticket.status === 'issued' ? 'animate-pulse' : ''}`} />
              {status.label}
            </span>
            {ticket.status === 'checked_in' && ticket.checked_in_at && (
              <span className={`block text-xs ${status.text} opacity-75 mt-0.5`}>
                Checked in at {formatTime(ticket.checked_in_at)}
              </span>
            )}
          </div>

          {/* QR Code Section */}
          <div className="px-4 sm:px-6 pt-6 pb-4 flex flex-col items-center">
            <div className="bg-white p-3 rounded-xl border border-neutral-100 shadow-sm">
              <QRCode value={ticket.qr_code} size={220} />
            </div>
            <p className="mt-2 text-[10px] sm:text-xs text-neutral-400 font-mono break-all text-center">{ticket.qr_code}</p>
          </div>

          {/* Ticket-style divider */}
          <div className="relative px-6">
            <div className="absolute left-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-neutral-50 rounded-r-full" />
            <div className="absolute right-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-neutral-50 rounded-l-full" />
            <div className="border-t border-dashed border-neutral-200" />
          </div>

          {/* Event Details */}
          <div className="px-4 sm:px-6 py-5 space-y-3">
            <div>
              <h2 className="text-lg font-bold text-neutral-900">{event.title}</h2>
              <p className="text-sm text-accent-600 font-semibold">{ticket_type.name}</p>
            </div>

            <div className="space-y-2.5">
              <div className="flex items-start gap-2.5">
                <Calendar className="w-4 h-4 text-neutral-400 mt-0.5 flex-shrink-0" />
                <div>
                  <p className="text-sm text-neutral-700">{formatDate(event.starts_at)}</p>
                  <p className="text-xs text-neutral-500">
                    {formatTime(event.starts_at)}
                    {event.ends_at && ` \u2013 ${formatTime(event.ends_at)}`}
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-2.5">
                <MapPin className="w-4 h-4 text-neutral-400 mt-0.5 flex-shrink-0" />
                <div>
                  <p className="text-sm text-neutral-700">{event.venue_name}</p>
                  {event.venue_address && (
                    <p className="text-xs text-neutral-500">{event.venue_address}</p>
                  )}
                </div>
              </div>

              {event.doors_open_at && (
                <div className="flex items-center gap-2.5">
                  <Clock className="w-4 h-4 text-neutral-400 flex-shrink-0" />
                  <p className="text-xs text-neutral-500">Doors open at {formatTime(event.doors_open_at)}</p>
                </div>
              )}
            </div>

            {/* Attendee Info */}
            {ticket.attendee_name && (
              <div className="pt-3 border-t border-neutral-100">
                <p className="text-xs text-neutral-400 uppercase tracking-wider font-medium">Attendee</p>
                <p className="text-sm font-semibold text-neutral-800 mt-0.5">{ticket.attendee_name}</p>
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="px-4 sm:px-6 py-3 bg-neutral-50 text-center border-t border-neutral-100">
            <p className="text-xs text-neutral-400">Present this QR code at the door</p>
          </div>
        </div>
      </motion.div>
    </div>
  )
}

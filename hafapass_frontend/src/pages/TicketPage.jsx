import { useState, useEffect } from 'react'
import { useParams, Link } from 'react-router-dom'
import { Calendar, MapPin, Clock, AlertTriangle, Loader2, Download, Share2, Smartphone, ChevronDown, ChevronUp } from 'lucide-react'
import { motion, AnimatePresence } from 'framer-motion'
import api from '../api/client'
import QRCode from '../components/QRCode'

function AddToHomeScreenInstructions() {
  const [expanded, setExpanded] = useState(false)
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
  const isAndroid = /Android/.test(navigator.userAgent)

  if (!isIOS && !isAndroid) return null

  return (
    <div className="mt-4">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-2 text-sm text-neutral-500 hover:text-neutral-700 transition-colors mx-auto"
      >
        <Smartphone className="w-4 h-4" />
        <span>Add to Home Screen</span>
        {expanded ? <ChevronUp className="w-3.5 h-3.5" /> : <ChevronDown className="w-3.5 h-3.5" />}
      </button>
      <AnimatePresence>
        {expanded && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            exit={{ opacity: 0, height: 0 }}
            className="overflow-hidden"
          >
            <div className="mt-3 p-3 bg-neutral-50 rounded-xl text-xs text-neutral-600 space-y-1.5">
              {isIOS ? (
                <>
                  <p className="font-medium text-neutral-700">iOS Instructions:</p>
                  <p>1. Tap the Share button in Safari</p>
                  <p>2. Scroll down and tap "Add to Home Screen"</p>
                  <p>3. Tap "Add" to confirm</p>
                </>
              ) : (
                <>
                  <p className="font-medium text-neutral-700">Android Instructions:</p>
                  <p>1. Tap the menu (three dots) in Chrome</p>
                  <p>2. Tap "Add to Home screen"</p>
                  <p>3. Tap "Add" to confirm</p>
                </>
              )}
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  )
}

function WalletButton({ label, icon }) {
  return (
    <div className="relative group">
      <button
        disabled
        className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-neutral-100 text-neutral-400 text-sm font-medium cursor-not-allowed"
      >
        {icon}
        <span>{label}</span>
      </button>
      <div className="absolute -top-8 left-1/2 -translate-x-1/2 bg-neutral-800 text-white text-xs px-2.5 py-1 rounded-lg opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none whitespace-nowrap">
        Coming Soon
      </div>
    </div>
  )
}

// Apple Wallet icon (SVG)
function AppleWalletIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="5" width="18" height="14" rx="2" />
      <line x1="3" y1="10" x2="21" y2="10" />
    </svg>
  )
}

// Google Wallet icon (SVG)
function GoogleWalletIcon() {
  return (
    <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 12V7a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h7" />
      <circle cx="18" cy="18" r="3" />
      <path d="M18 15v6" />
      <path d="M15 18h6" />
    </svg>
  )
}

export default function TicketPage() {
  const { qrCode } = useParams()
  const [ticket, setTicket] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [downloading, setDownloading] = useState(false)

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

  async function handleDownload() {
    try {
      setDownloading(true)
      const response = await api.get(`/tickets/${qrCode}/download`, {
        responseType: 'blob',
      })
      const url = window.URL.createObjectURL(new Blob([response.data]))
      const link = document.createElement('a')
      link.href = url
      link.setAttribute('download', `hafapass-ticket-${qrCode.slice(0, 8)}.pdf`)
      document.body.appendChild(link)
      link.click()
      link.remove()
      window.URL.revokeObjectURL(url)
    } catch {
      // Silently fail — user can retry
    } finally {
      setDownloading(false)
    }
  }

  async function handleShare() {
    if (navigator.share) {
      try {
        await navigator.share({
          title: ticket?.event?.title || 'My Ticket',
          text: `Check out my ticket for ${ticket?.event?.title}`,
          url: window.location.href,
        })
      } catch {
        // User cancelled
      }
    }
  }

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
    <div className="min-h-screen bg-gradient-to-b from-neutral-950 via-neutral-900 to-neutral-950 flex items-center justify-center px-3 sm:px-4 py-8">
      <motion.div
        className="w-full max-w-[380px] sm:max-w-sm"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
      >
        {/* Main Ticket Card */}
        <div className="bg-white rounded-2xl overflow-hidden shadow-2xl shadow-black/30">
          {/* Cover image banner */}
          {event.cover_image_url && (
            <div className="h-32 sm:h-36 overflow-hidden relative">
              <img
                src={event.cover_image_url}
                alt={event.title}
                className="w-full h-full object-cover"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black/40 to-transparent" />
            </div>
          )}

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
          <motion.div
            className="px-4 sm:px-6 pt-6 pb-4 flex flex-col items-center"
            initial={{ scale: 0.9, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            transition={{ duration: 0.4, delay: 0.2 }}
          >
            <div className="bg-white p-3 rounded-xl border border-neutral-100 shadow-sm">
              <QRCode value={ticket.qr_code} size={220} />
            </div>
            <p className="mt-2 text-[10px] sm:text-xs text-neutral-400 font-mono break-all text-center select-all">
              {ticket.qr_code}
            </p>
          </motion.div>

          {/* Ticket-style divider */}
          <div className="relative px-6">
            <div className="absolute left-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-neutral-950 rounded-r-full" />
            <div className="absolute right-0 top-1/2 -translate-y-1/2 w-4 h-8 bg-neutral-950 rounded-l-full" />
            <div className="border-t border-dashed border-neutral-200" />
          </div>

          {/* Event Details */}
          <div className="px-4 sm:px-6 py-5 space-y-3">
            <div>
              <h2 className="font-display text-lg font-bold text-neutral-900">{event.title}</h2>
              <p className="text-sm text-accent-600 font-semibold font-sans">{ticket_type.name}</p>
            </div>

            <div className="space-y-2.5">
              <div className="flex items-start gap-2.5">
                <Calendar className="w-4 h-4 text-neutral-400 mt-0.5 flex-shrink-0" />
                <div>
                  <p className="text-sm text-neutral-700 font-sans">{formatDate(event.starts_at)}</p>
                  <p className="text-xs text-neutral-500 font-sans">
                    {formatTime(event.starts_at)}
                    {event.ends_at && ` \u2013 ${formatTime(event.ends_at)}`}
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-2.5">
                <MapPin className="w-4 h-4 text-neutral-400 mt-0.5 flex-shrink-0" />
                <div>
                  <p className="text-sm text-neutral-700 font-sans">{event.venue_name}</p>
                  {event.venue_address && (
                    <p className="text-xs text-neutral-500 font-sans">{event.venue_address}</p>
                  )}
                </div>
              </div>

              {event.doors_open_at && (
                <div className="flex items-center gap-2.5">
                  <Clock className="w-4 h-4 text-neutral-400 flex-shrink-0" />
                  <p className="text-xs text-neutral-500 font-sans">Doors open at {formatTime(event.doors_open_at)}</p>
                </div>
              )}
            </div>

            {/* Attendee Info */}
            {ticket.attendee_name && (
              <div className="pt-3 border-t border-neutral-100">
                <p className="text-xs text-neutral-400 uppercase tracking-wider font-medium font-sans">Attendee</p>
                <p className="text-sm font-semibold text-neutral-800 mt-0.5 font-sans">{ticket.attendee_name}</p>
              </div>
            )}
          </div>

          {/* Action Buttons */}
          <div className="px-4 sm:px-6 pb-5 space-y-2.5">
            {/* Download PDF */}
            <button
              onClick={handleDownload}
              disabled={downloading}
              className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-brand-500 hover:bg-brand-600 text-white text-sm font-semibold transition-colors disabled:opacity-60"
            >
              {downloading ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <Download className="w-4 h-4" />
              )}
              <span>{downloading ? 'Generating...' : 'Download PDF'}</span>
            </button>

            {/* Share */}
            {typeof navigator !== 'undefined' && navigator.share && (
              <button
                onClick={handleShare}
                className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-neutral-100 hover:bg-neutral-200 text-neutral-700 text-sm font-medium transition-colors"
              >
                <Share2 className="w-4 h-4" />
                <span>Share Ticket</span>
              </button>
            )}

            {/* Wallet Buttons (Coming Soon) */}
            <div className="grid grid-cols-2 gap-2">
              <WalletButton label="Apple Wallet" icon={<AppleWalletIcon />} />
              <WalletButton label="Google Wallet" icon={<GoogleWalletIcon />} />
            </div>
          </div>

          {/* Footer */}
          <div className="px-4 sm:px-6 py-3 bg-neutral-50 text-center border-t border-neutral-100">
            <p className="text-xs text-neutral-400 font-sans">Present this QR code at the door</p>
          </div>
        </div>

        {/* Add to Home Screen */}
        <AddToHomeScreenInstructions />
      </motion.div>
    </div>
  )
}

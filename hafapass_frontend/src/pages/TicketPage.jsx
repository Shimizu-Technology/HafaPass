import { useState, useEffect } from 'react'
import { useLocation, useParams, Link } from 'react-router-dom'
import { Calendar, MapPin, Clock, AlertTriangle, Loader2, Download, Share2, Smartphone, ChevronDown, ChevronUp } from 'lucide-react'
import { motion, AnimatePresence } from 'framer-motion'
import api from '../api/client'
import QRCode from '../components/QRCode'
import { formatEventDate, formatEventTime } from '../utils/eventTime'
import { orderAccessHeaders } from '../utils/orderAccess'

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

function WalletButton({ label, icon, onClick, disabled, loading }) {
  return (
      <button onClick={onClick} disabled={disabled || loading}
        className="w-full flex items-center justify-center gap-2 px-4 py-2.5 rounded-xl bg-neutral-900 hover:bg-neutral-800 text-white text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50">
        {icon}
        <span>{loading ? 'Opening…' : label}</span>
      </button>
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
  const { credential } = useParams()
  const location = useLocation()
  const orderId = new URLSearchParams(location.search).get('order')
  const [ticket, setTicket] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [downloading, setDownloading] = useState(false)
  const [walletLoading, setWalletLoading] = useState(null)
  const [walletError, setWalletError] = useState(null)

  useEffect(() => {
    async function fetchTicket() {
      try {
        setLoading(true)
        setError(null)
        const response = await api.get(`/tickets/${encodeURIComponent(credential)}`, {
          headers: orderAccessHeaders(orderId),
        })
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
  }, [credential, orderId])

  async function handleDownload() {
    try {
      setDownloading(true)
      const response = await api.get(`/tickets/${encodeURIComponent(credential)}/download`, {
        headers: orderAccessHeaders(orderId),
        responseType: 'blob',
      })
      const url = window.URL.createObjectURL(new Blob([response.data]))
      const link = document.createElement('a')
      link.href = url
      link.setAttribute('download', `hafapass-ticket-${ticket.id}.pdf`)
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

  async function handleWallet(kind) {
    setWalletLoading(kind)
    setWalletError(null)
    try {
      if (kind === 'apple') {
        const response = await api.get(`/tickets/${encodeURIComponent(credential)}/wallet/apple`, {
          headers: orderAccessHeaders(orderId), responseType: 'blob',
        })
        const url = window.URL.createObjectURL(response.data)
        const link = document.createElement('a')
        link.href = url
        link.download = `hafapass-ticket-${ticket.id}.pkpass`
        link.click()
        window.URL.revokeObjectURL(url)
      } else {
        const response = await api.get(`/tickets/${encodeURIComponent(credential)}/wallet/google`, {
          params: { response: 'json' }, headers: orderAccessHeaders(orderId),
        })
        window.location.assign(response.data.url)
      }
    } catch (err) {
      setWalletError(err.response?.data?.error || `${kind === 'apple' ? 'Apple' : 'Google'} Wallet is unavailable.`)
    } finally {
      setWalletLoading(null)
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

  const formatDate = (dateStr) => formatEventDate(dateStr, event?.timezone, { weekday: 'long', month: 'long' })
  const formatTime = (dateStr) => formatEventTime(dateStr, event?.timezone)

  const statusConfig = {
    issued: { label: 'Valid', bg: 'bg-emerald-50', text: 'text-emerald-700', border: 'border-emerald-200', dot: 'bg-emerald-500' },
    checked_in: { label: 'Used', bg: 'bg-neutral-100', text: 'text-neutral-600', border: 'border-neutral-200', dot: 'bg-neutral-400' },
    cancelled: { label: 'Cancelled', bg: 'bg-red-50', text: 'text-red-700', border: 'border-red-200', dot: 'bg-red-500' },
    transferred: { label: 'Transferred', bg: 'bg-amber-50', text: 'text-amber-700', border: 'border-amber-200', dot: 'bg-amber-500' },
  }

  const status = statusConfig[ticket.status] || statusConfig.issued
  const showCredential = ticket.admission_allowed && Boolean(ticket.scan_credential)

  return (
    <div className="min-h-screen bg-gradient-to-b from-neutral-950 via-neutral-900 to-neutral-950 flex items-center justify-center px-3 sm:px-4 py-8">
      <motion.div
        className="w-full max-w-[380px] sm:max-w-sm"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
      >
        {['postponed', 'cancelled'].includes(event.status) && (
          <div className="mb-4 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
            <strong className="capitalize">Event {event.status}.</strong> Keep this ticket and watch your email for organizer updates.
          </div>
        )}
        {!ticket.admission_allowed && !['postponed', 'cancelled'].includes(event.status) && (
          <div className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-sm text-red-900">
            <strong>Ticket unavailable.</strong> {ticket.admission_block_reason || 'This ticket is not currently valid for entry.'}
          </div>
        )}
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
          {showCredential ? <motion.div
            className="px-4 sm:px-6 pt-6 pb-4 flex flex-col items-center"
            initial={{ scale: 0.9, opacity: 0 }}
            animate={{ scale: 1, opacity: 1 }}
            transition={{ duration: 0.4, delay: 0.2 }}
          >
            <div className="bg-white p-3 rounded-xl border border-neutral-100 shadow-sm">
              <QRCode value={ticket.scan_credential} size={220} />
            </div>
            <p className="mt-2 text-[10px] sm:text-xs text-neutral-400 font-mono break-all text-center select-all">
              Ticket HP-T{ticket.id}
            </p>
          </motion.div> : (
            <div className="px-6 py-8 text-center">
              <AlertTriangle className="mx-auto mb-2 h-8 w-8 text-neutral-400" />
              <p className="text-sm font-medium text-neutral-700">Entry code unavailable</p>
              <p className="mt-1 text-xs text-neutral-500">Open this ticket from your secure order confirmation or signed-in account.</p>
            </div>
          )}

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
              {ticket.seat && <p className="mt-1 text-sm font-semibold text-brand-700">{ticket.seat.display_label}</p>}
              {ticket.seat?.obstructed_view && <p className="mt-1 text-xs text-amber-700">Obstructed view{ticket.seat.view_note ? `: ${ticket.seat.view_note}` : ''}</p>}
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

          </div>

          {/* Action Buttons */}
          <div className="px-4 sm:px-6 pb-5 space-y-2.5">
            {/* Download PDF */}
            <button
              onClick={handleDownload}
              disabled={downloading || !showCredential}
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

            {walletError && <p className="text-center text-xs text-red-600">{walletError}</p>}
            {(ticket.wallet_availability?.apple || ticket.wallet_availability?.google) && (
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                {ticket.wallet_availability.apple && (
                  <WalletButton label="Apple Wallet" icon={<AppleWalletIcon />} disabled={!showCredential}
                    loading={walletLoading === 'apple'} onClick={() => handleWallet('apple')} />
                )}
                {ticket.wallet_availability.google && (
                  <WalletButton label="Google Wallet" icon={<GoogleWalletIcon />} disabled={!showCredential}
                    loading={walletLoading === 'google'} onClick={() => handleWallet('google')} />
                )}
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="px-4 sm:px-6 py-3 bg-neutral-50 text-center border-t border-neutral-100">
            <p className="text-xs text-neutral-400 font-sans">
              {showCredential ? 'Present this QR code at the door' : 'This ticket has no active entry code'}
            </p>
          </div>
        </div>

        {/* Add to Home Screen */}
        <AddToHomeScreenInstructions />
      </motion.div>
    </div>
  )
}

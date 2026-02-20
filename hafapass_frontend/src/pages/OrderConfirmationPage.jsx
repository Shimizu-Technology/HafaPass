import { useState, useEffect } from 'react'
import { useParams, useLocation, Link } from 'react-router-dom'
import { CheckCircle, ChevronRight, Loader2, PartyPopper } from 'lucide-react'
import { motion } from 'framer-motion'
import apiClient from '../api/client'

// Simple confetti particles
function ConfettiParticles() {
  const colors = ['#14b8a6', '#f97316', '#eab308', '#8b5cf6', '#ec4899', '#06b6d4']
  const particles = Array.from({ length: 40 }, (_, i) => ({
    id: i,
    x: Math.random() * 100,
    delay: Math.random() * 0.8,
    duration: 1.5 + Math.random() * 1.5,
    color: colors[i % colors.length],
    size: 4 + Math.random() * 6,
    rotation: Math.random() * 360,
  }))

  return (
    <div className="fixed inset-0 pointer-events-none z-50 overflow-hidden">
      {particles.map(p => (
        <motion.div
          key={p.id}
          className="absolute rounded-sm"
          style={{
            left: `${p.x}%`,
            top: -10,
            width: p.size,
            height: p.size,
            backgroundColor: p.color,
          }}
          initial={{ y: -20, opacity: 1, rotate: 0 }}
          animate={{ y: '100vh', opacity: 0, rotate: p.rotation + 360 }}
          transition={{ duration: p.duration, delay: p.delay, ease: 'easeIn' }}
        />
      ))}
    </div>
  )
}

export default function OrderConfirmationPage() {
  const { id } = useParams()
  const location = useLocation()

  const [order, setOrder] = useState(location.state?.order || null)
  const [event, setEvent] = useState(location.state?.event || null)
  const [loading, setLoading] = useState(!location.state?.order)
  const [error, setError] = useState(null)
  const [showConfetti, setShowConfetti] = useState(true)

  useEffect(() => {
    const timer = setTimeout(() => setShowConfetti(false), 4000)
    return () => clearTimeout(timer)
  }, [])

  useEffect(() => {
    if (!order || String(order.id) !== String(id)) {
      setLoading(true)
      setError(null)
      apiClient.get(`/me/orders/${id}`)
        .then(res => {
          setOrder(res.data)
          setEvent(res.data.event)
          setLoading(false)
        })
        .catch(() => {
          setError('Unable to load order details. Please check your email for confirmation.')
          setLoading(false)
        })
    }
  }, [id])

  const formatPrice = (cents) => {
    if (cents === 0) return 'Free'
    return `$${(cents / 100).toFixed(2)}`
  }

  const formatDate = (dateStr) => {
    if (!dateStr) return ''
    return new Date(dateStr).toLocaleDateString('en-US', {
      weekday: 'short', month: 'short', day: 'numeric', year: 'numeric',
    })
  }

  const formatTime = (dateStr) => {
    if (!dateStr) return ''
    return new Date(dateStr).toLocaleTimeString('en-US', {
      hour: 'numeric', minute: '2-digit',
    })
  }

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-2xl mx-auto px-4 py-16">
        <div className="card p-8 text-center">
          <p className="text-red-600 mb-4">{error}</p>
          <Link to="/events" className="btn-primary">Browse Events</Link>
        </div>
      </div>
    )
  }

  if (!order) return null

  return (
    <div className="bg-neutral-50 min-h-screen">
      {showConfetti && <ConfettiParticles />}

      <div className="max-w-2xl mx-auto px-4 sm:px-6 py-8">
        {/* Success header */}
        <motion.div
          className="text-center mb-8"
          initial={{ opacity: 0, scale: 0.9 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
        >
          <motion.div
            className="inline-flex items-center justify-center w-20 h-20 bg-emerald-100 rounded-full mb-4"
            initial={{ scale: 0 }}
            animate={{ scale: 1 }}
            transition={{ duration: 0.4, delay: 0.2, type: 'spring', stiffness: 200 }}
          >
            <CheckCircle className="w-10 h-10 text-emerald-600" />
          </motion.div>
          <h1 className="text-2xl sm:text-3xl font-bold text-neutral-900 mb-2">
            You're all set! 🎉
          </h1>
          <p className="text-neutral-500">
            A confirmation has been sent to <span className="font-medium text-neutral-700">{order.buyer_email}</span>
          </p>
        </motion.div>

        {/* View Tickets CTA — prominent */}
        {order.tickets && order.tickets.length > 0 && (
          <motion.div
            className="mb-6"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.1 }}
          >
            <Link
              to={`/tickets/${order.tickets[0].qr_code}`}
              className="block w-full btn-primary text-center text-lg !py-4 !rounded-2xl"
            >
              View Your Tickets
            </Link>
          </motion.div>
        )}

        {/* Order summary card */}
        <motion.div
          className="card p-6 mb-6"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.15 }}
        >
          <h2 className="text-base font-semibold text-neutral-900 mb-4">Order Summary</h2>

          {/* Event info */}
          {event && (
            <div className="mb-4 pb-4 border-b border-neutral-100">
              <p className="text-neutral-900 font-medium">{event.title}</p>
              {event.starts_at && (
                <p className="text-sm text-neutral-500 mt-1">
                  {formatDate(event.starts_at)} &middot; {formatTime(event.starts_at)}
                </p>
              )}
              {event.venue_name && (
                <p className="text-sm text-neutral-500">{event.venue_name}</p>
              )}
            </div>
          )}

          {/* Buyer info */}
          <div className="mb-4 pb-4 border-b border-neutral-100 space-y-1">
            <div className="flex justify-between text-sm">
              <span className="text-neutral-500">Name</span>
              <span className="text-neutral-900">{order.buyer_name}</span>
            </div>
            {order.buyer_phone && (
              <div className="flex justify-between text-sm">
                <span className="text-neutral-500">Phone</span>
                <span className="text-neutral-900">{order.buyer_phone}</span>
              </div>
            )}
          </div>

          {/* Total paid */}
          <div className="flex justify-between items-center">
            <span className="text-neutral-900 font-bold">Total Paid</span>
            <span className="text-neutral-900 font-bold text-lg">{formatPrice(order.total_cents)}</span>
          </div>
        </motion.div>

        {/* Tickets list */}
        <motion.div
          className="card p-6 mb-6"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.3 }}
        >
          <h2 className="text-base font-semibold text-neutral-900 mb-4">
            Your Tickets ({order.tickets?.length || 0})
          </h2>

          <div className="space-y-3">
            {order.tickets?.map(ticket => (
              <Link
                key={ticket.id}
                to={`/tickets/${ticket.qr_code}`}
                className="flex items-center justify-between p-3 bg-neutral-50 rounded-xl hover:bg-neutral-100 transition-colors group"
              >
                <div>
                  <p className="text-neutral-900 font-medium text-sm">{ticket.ticket_type?.name}</p>
                  <p className="text-xs text-neutral-500">{ticket.attendee_name}</p>
                </div>
                <span className="inline-flex items-center text-brand-500 group-hover:text-brand-600 text-sm font-medium transition-colors">
                  View
                  <ChevronRight className="w-4 h-4 ml-0.5 transition-transform group-hover:translate-x-0.5" />
                </span>
              </Link>
            ))}
          </div>
        </motion.div>

        {/* Browse more events button */}
        <motion.div
          className="text-center"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.45 }}
        >
          <Link to="/events" className="text-brand-500 hover:text-brand-600 font-medium transition-colors">
            Browse More Events
          </Link>
        </motion.div>
      </div>
    </div>
  )
}

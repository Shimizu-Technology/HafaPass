import { useTranslation } from 'react-i18next'
import { useState, useEffect, useLayoutEffect, useRef, version as reactVersion } from 'react'
import { useParams, useNavigate, useSearchParams, useMatch, useLocation, Link } from 'react-router-dom'
import { Calendar, Clock, MapPin, Users, ArrowLeft, Share2, Loader2, CalendarPlus, Check, Heart, Bell, UserPlus, Navigation, ChevronRight } from 'lucide-react'
import { motion, useReducedMotion } from 'framer-motion'
import apiClient from '../api/client'
import WhosGoing from '../components/WhosGoing'
import TicketTypesSection from '../components/TicketTypesSection'
import SeatSelector from '../components/SeatSelector'
import WaitlistForm from '../components/WaitlistForm'
import SEO from '../components/SEO'
import MachineTranslationNotice from '../components/MachineTranslationNotice'
import useTranslatedContent from '../hooks/useTranslatedContent'
import useContentLanguage from '../hooks/useContentLanguage'
import NotFound from '../components/NotFound'
import { FadeUp } from '../components/ui/ScrollReveal'
import { formatEventDate, formatEventTime, formatEventTimeRange } from '../utils/eventTime'
import { PUBLIC_WEB_URL } from '../utils/site'
import { eventBrowseReturn } from '../utils/browseReturn'
import { formatTicketPrice, lowestPurchasablePrice, purchasableAllInPrices } from '../utils/ticketPricing'
import { AllInPriceNote, SellerLine } from '../components/PriceDisclosure'
import { captureQueryAttribution, trackFunnel } from '../utils/marketplaceAttribution'

// React 18 does not know `inert` and only renders it from a string (''), while React 19
// treats it as a boolean and drops ''. Emit the value each version needs.
const INERT_VALUE = Number(reactVersion.split('.')[0]) >= 19 ? true : ''

// Phones see the ticket panel once near the top; this bar keeps the purchase one tap
// away while the hero button and the panel are out of view. It also stays hidden once
// the visitor reaches (or scrolls past) the end of the event content, so it never
// covers the footer.
function MobileBuyBar({ priceLabel, targets, endMarker }) {
  const { t } = useTranslation()
  const reducedMotion = useReducedMotion()
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    const end = endMarker.current
    const elements = [...targets.map(target => target.current), end].filter(Boolean)
    if (!elements.length || typeof IntersectionObserver === 'undefined') return undefined
    const blocking = new Map()
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => blocking.set(entry.target,
        entry.isIntersecting || (entry.target === end && entry.boundingClientRect.top < 0)))
      setVisible(elements.every(element => blocking.get(element) === false))
    })
    elements.forEach(element => observer.observe(element))
    return () => observer.disconnect()
  }, [targets, endMarker])

  const openTickets = event => {
    const panel = document.getElementById('tickets')
    if (!panel) return
    event.preventDefault()
    panel.scrollIntoView({ behavior: reducedMotion ? 'auto' : 'smooth', block: 'start' })
    panel.focus({ preventScroll: true })
  }

  return (
    <div
      data-testid="mobile-buy-bar"
      data-visible={visible}
      aria-hidden={!visible}
      inert={visible ? undefined : INERT_VALUE}
      className={`fixed inset-x-0 bottom-0 z-40 border-t border-neutral-200 bg-white/95 px-4 pt-3 pb-[calc(0.75rem+env(safe-area-inset-bottom,0px))] shadow-float backdrop-blur transition-[transform,opacity] duration-200 ease-out-strong lg:hidden ${visible ? 'translate-y-0 opacity-100' : 'pointer-events-none translate-y-full opacity-0'}`}
    >
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-4">
        <p className="min-w-0 truncate text-base font-semibold text-neutral-900">{priceLabel}</p>
        <a href="#tickets" onClick={openTickets} className="btn-primary shrink-0 !px-5 !py-2.5">{t('buyer.EventDetail.getTickets')}<ChevronRight aria-hidden="true" className="ml-1 h-4 w-4" />
        </a>
      </div>
    </div>
  )
}

// When an old event link resolves, the event already loaded is handed to the
// page mounted at the current link so the swap needs no second request or
// spinner. Module scope (not history state) keeps a reload from reusing it.
let resolvedEventHandoff = null

export default function EventDetailPage() {
  const { slug } = useParams()
  const [params] = useSearchParams()
  // Public pages can reuse their outlet when reduced motion is enabled.
  // Event inventory and offer selections belong to this specific route/context.
  return <EventDetailContent key={JSON.stringify([slug, params.get('preview') === 'true',
    params.get('live_money_proof') === 'true', params.get('waitlist_offer')])} />
}

function EventDetailContent() {
  const { t } = useTranslation()
  const translation = useRef(t)
  translation.current = t
  const { slug } = useParams()
  const reducedMotion = useReducedMotion()
  const navigate = useNavigate()
  const location = useLocation()
  const browseFrom = eventBrowseReturn(location.state?.browseFrom)
  const match = useMatch('/events/:slug')
  const liveRoute = useRef(null)
  const mounted = useRef(false)
  liveRoute.current = { slug: match?.params.slug }
  useLayoutEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])
  const [searchParams] = useSearchParams()
  const isPreview = searchParams.get('preview') === 'true'
  const isLiveMoneyProof = searchParams.get('live_money_proof') === 'true'
  const handedOffEvent = useRef(resolvedEventHandoff?.slug === slug ? resolvedEventHandoff.event : null)
  const liveLocation = useRef(location)
  liveLocation.current = location
  const viewTracked = useRef(false)
  const [event, setEvent] = useState(handedOffEvent.current)
  const [loading, setLoading] = useState(!handedOffEvent.current)
  const [error, setError] = useState(null)
  const [loadAttempt, setLoadAttempt] = useState(0)
  const [copied, setCopied] = useState(false)
  const [waitlistOffer, setWaitlistOffer] = useState(null)
  const heroTicketsLink = useRef(null)
  const ticketPanel = useRef(null)
  const pageEnd = useRef(null)
  const [buyBarTargets] = useState(() => [heroTicketsLink, ticketPanel])
  const waitlistOfferToken = searchParams.get('waitlist_offer')
  const content = useTranslatedContent(event)
  const contentLanguage = useContentLanguage()
  const loadedLanguage = useRef(contentLanguage)

  useEffect(() => {
    let active = true
    const current = () => active && liveRoute.current.slug === slug
    if (!current()) return undefined
    captureQueryAttribution(window.location.search)
    const initialEvent = handedOffEvent.current
    if (initialEvent && loadAttempt === 0) {
      resolvedEventHandoff = null
      if (!viewTracked.current) trackFunnel(apiClient, initialEvent.id, 'event_view')
      viewTracked.current = true
      return () => { active = false }
    }
    setLoading(true)
    setEvent(null)
    setError(null)
    const url = isLiveMoneyProof ? `/events/${slug}?live_money_proof=true` :
      (isPreview ? `/events/${slug}?preview=true` : `/events/${slug}`)
    apiClient.get(url)
      .then(res => {
        if (!current()) return
        if (res.data.redirected_from === slug && res.data.slug && res.data.slug !== slug) {
          // An old link: show the event at its current address.
          const { search, hash, state } = liveLocation.current
          resolvedEventHandoff = { slug: res.data.slug, event: res.data }
          navigate(`/events/${encodeURIComponent(res.data.slug)}${search}${hash}`, { replace: true, state })
          return
        }
        if (res.data.slug !== slug) throw new Error('Event response does not match its route')
        setEvent(res.data)
        trackFunnel(apiClient, res.data.id, 'event_view')
        setLoading(false)
      })
      .catch(error => { if (current()) {
        setError(error.response?.status === 404
          ? { message: translation.current('buyer.EventDetail.eventNotFound'), retryable: false }
          : { message: translation.current('buyer.EventDetail.thisEventCouldntLoadPleaseTryAgain'), retryable: true })
        setLoading(false)
      } })
    return () => { active = false }
  }, [slug, isPreview, isLiveMoneyProof, loadAttempt, navigate])

  // Switching language reloads the event text quietly, keeping the page (and any
  // ticket selection) in place; the first load already used the current language.
  useEffect(() => {
    if (loadedLanguage.current === contentLanguage) return undefined
    loadedLanguage.current = contentLanguage
    if (!event) return undefined
    let active = true
    const url = isLiveMoneyProof ? `/events/${slug}?live_money_proof=true` :
      (isPreview ? `/events/${slug}?preview=true` : `/events/${slug}`)
    apiClient.get(url)
      .then(res => { if (active && liveRoute.current.slug === slug && res.data.slug === slug) setEvent(res.data) })
      .catch(() => { /* Keep the text already shown; the next navigation retries. */ })
    return () => { active = false }
  }, [contentLanguage, event, slug, isPreview, isLiveMoneyProof])

  useEffect(() => {
    if (!waitlistOfferToken) return undefined
    let active = true
    apiClient.get(`/waitlist_offers/${encodeURIComponent(waitlistOfferToken)}`)
      .then(res => { if (active && liveRoute.current.slug === slug) setWaitlistOffer(res.data) })
      .catch(() => { if (active && liveRoute.current.slug === slug) setWaitlistOffer({ error: translation.current('buyer.EventDetail.offerUnavailable') }) })
    return () => { active = false }
  }, [waitlistOfferToken, slug])

  const handleCheckout = (lineItems) => {
    if (!mounted.current || liveRoute.current.slug !== slug || event?.slug !== slug) return
    const offer = waitlistOfferToken && waitlistOffer && !waitlistOffer.error ? waitlistOffer : null
    navigate(`/checkout/${slug}`, { state: { event, lineItems, waitlistOfferToken, waitlistOffer: offer, liveMoneyProof: isLiveMoneyProof, browseFrom } })
  }

  const handleSeatCheckout = ({ lineItems, seatHoldToken, seatHoldExpiresAt, seats }) => {
    if (!mounted.current || liveRoute.current.slug !== slug || event?.slug !== slug) return
    navigate(`/checkout/${slug}`, {
      state: { event, lineItems, seatHoldToken, seatHoldExpiresAt, selectedSeats: seats, browseFrom },
    })
  }

  const marketplaceAction = async (kind) => {
    try {
      if (kind === 'favorite') {
        if (event.favorited) await apiClient.delete(`/me/event_favorites/${event.id}`)
        else await apiClient.post('/me/event_favorites', { event_id: event.id })
        setEvent(current => ({ ...current, favorited: !current.favorited }))
      } else if (kind === 'follow') {
        if (event.organizer.followed) await apiClient.delete(`/me/organizer_follows/${event.organizer.id}`)
        else await apiClient.post('/me/organizer_follows', { organization_id: event.organizer.id })
        setEvent(current => ({ ...current, organizer: { ...current.organizer, followed: !current.organizer.followed } }))
      } else if (kind === 'reminder') {
        if (event.reminder) await apiClient.delete(`/me/event_reminders/${event.id}`)
        else await apiClient.post('/me/event_reminders', { event_id: event.id })
        setEvent(current => ({ ...current, reminder: current.reminder ? null : true }))
      }
    } catch (error) {
      if (error.response?.status === 401) navigate('/sign-in')
    }
  }

  const ageLabels = { all_ages: t('buyer.EventDetail.allAges'), eighteen_plus: '18+', twenty_one_plus: '21+' }

  const buildGoogleCalendarUrl = (evt) => {
    const toGCalDate = (d) => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '')
    const start = toGCalDate(evt.starts_at)
    const end = evt.ends_at ? toGCalDate(evt.ends_at) : toGCalDate(new Date(new Date(evt.starts_at).getTime() + 2 * 3600000))
    const params = new URLSearchParams({
      action: 'TEMPLATE',
      text: evt.title,
      dates: `${start}/${end}`,
      details: evt.description || '',
      location: [evt.venue_name, evt.venue_address].filter(Boolean).join(', '),
    })
    return `https://calendar.google.com/calendar/render?${params.toString()}`
  }

  const handleShare = async () => {
    let url = window.location.href
    try {
      const response = await apiClient.post('/me/event_referrals', { event_id: event.id })
      url = response.data.url
    } catch {
      // Guests still get the canonical event URL; signed-in fans get measurable referral links.
    }
    if (navigator.share) {
      try {
        await navigator.share({ title: event.title, text: event.short_description || event.description?.slice(0, 120), url })
      } catch {
        // Share cancellation is user-driven; no visible error needed.
      }
    } else {
      await navigator.clipboard.writeText(url)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    }
  }

  const buildMapsUrl = (evt) => {
    const q = encodeURIComponent([evt.venue_name, evt.venue_address].filter(Boolean).join(', '))
    return `https://www.google.com/maps/search/?api=1&query=${q}`
  }

  if (loading) return <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 text-brand-500 animate-spin" /></div>
  if (error && !error.retryable) return <NotFound kind="event" backTo={browseFrom} />
  if (error) return (
    <div className="max-w-2xl mx-auto px-4 py-16 text-center">
      <p role="alert" className="text-neutral-700 text-lg mb-4">{error.message}</p>
      {error.retryable && <button type="button" className="btn-primary mb-4" onClick={() => setLoadAttempt(attempt => attempt + 1)}>{t('buyer.EventDetail.retryEvent')}</button>}
      <Link to={browseFrom} className="btn-primary">{t('buyer.EventDetail.browseEvents')}</Link>
    </div>
  )
  if (!event) return null

  const truncatedDescription = (event.short_description || event.description || '').slice(0, 160)
  const eventUrl = `${PUBLIC_WEB_URL}/events/${event.slug}`
  const lowestPrice = lowestPurchasablePrice(event.ticket_types || [])
  const onSale = event.purchasable === true && (event.assigned_seating || lowestPrice !== null)
  const buyBarPrice = lowestPrice === 0 ? t('buyer.EventDetail.free') : lowestPrice !== null ? t('buyer.EventDetail.from', { value1: formatTicketPrice(lowestPrice) }) : t('buyer.EventDetail.ticketsAvailable')

  // Build JSON-LD structured data for the event
  const ticketTypes = event.ticket_types || []
  // Offers carry all-in prices (ticket + mandatory buyer fee), like every other display.
  const prices = purchasableAllInPrices(ticketTypes).map(price => price / 100)
  const eventJsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: event.title,
    startDate: event.starts_at,
    ...(event.ends_at && { endDate: event.ends_at }),
    description: truncatedDescription,
    ...(event.cover_image_url && { image: event.cover_image_url }),
    url: eventUrl,
    ...(event.venue_name && {
      location: {
        '@type': 'Place',
        name: event.venue_name,
        ...(event.venue_address && { address: event.venue_address }),
      },
    }),
    ...(prices.length > 0 && {
      offers: {
        '@type': 'AggregateOffer',
        lowPrice: Math.min(...prices).toFixed(2),
        highPrice: Math.max(...prices).toFixed(2),
        priceCurrency: 'USD',
        availability: event.purchasable ? 'https://schema.org/InStock' : 'https://schema.org/SoldOut',
        url: eventUrl,
      },
    }),
    ...(event.organizer?.business_name && {
      organizer: {
        '@type': 'Organization',
        name: event.organizer.business_name,
      },
    }),
  }

  return (
    <div>
      <SEO
        title={event.title}
        description={truncatedDescription}
        image={event.cover_image_url || undefined}
        url={eventUrl}
        jsonLd={eventJsonLd}
        noIndex={isLiveMoneyProof}
      />
      {/* Hero Section — full-width cover image with dark overlay */}
      <div className={`relative w-full overflow-hidden bg-neutral-950 ${event.cover_image_url ? 'min-h-[340px] sm:min-h-[400px]' : 'min-h-[260px]'}`}>
        {event.cover_image_url ? (
          <img
            src={event.cover_image_url}
            alt={event.title}
            className="absolute inset-0 w-full h-full object-cover"
          />
        ) : (
          <div className="absolute inset-0 bg-gradient-to-br from-brand-900 to-neutral-950" />
        )}
        {/* Dark gradient overlay */}
        <div className="absolute inset-0 bg-gradient-to-t from-neutral-950 via-neutral-950/60 to-neutral-950/30" />

        {/* Content overlaid on hero */}
        <div className="relative flex min-h-[inherit] flex-col justify-end pt-16 sm:pt-24">
          <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 pb-8 sm:pb-10 w-full">
            {/* Back link */}
            <Link to={browseFrom} className="mb-6 flex min-h-11 w-fit items-center gap-1.5 text-sm font-medium text-neutral-200 transition-colors hover:text-white">
              <ArrowLeft aria-hidden="true" className="w-4 h-4" />{t('buyer.EventDetail.allEvents')}</Link>

            {event.category && event.category !== 'other' && (
              <span className="block text-xs font-medium text-brand-400 uppercase tracking-wider mb-2">
                {t(`buyer.categories.${event.category}`, { defaultValue: event.category_label || event.category })}
              </span>
            )}
            <h1 className="font-display text-3xl sm:text-4xl lg:text-5xl font-bold tracking-tight text-white mb-3 break-words">{content.title}</h1>
            {content.notice && <MachineTranslationNotice {...content.notice} tone="dark" className="mb-3" />}

            {/* Date & Venue on hero */}
            <div className="flex flex-wrap items-center gap-4 text-neutral-200 text-sm">
              {event.starts_at && (
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <Calendar className="w-4 h-4 text-brand-400" />
                  <span>{formatEventDate(event.starts_at, event.timezone, { weekday: 'long', month: 'long' })}</span>
                  <span className="text-neutral-500">·</span>
                  <span className="min-w-0 [overflow-wrap:anywhere]">{formatEventTimeRange(event.starts_at, event.ends_at, event.timezone)}</span>
                </div>
              )}
              {event.venue_name && (
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <MapPin className="w-4 h-4 text-brand-400" />
                  <span>{event.venue_name}</span>
                </div>
              )}
            </div>
            <a ref={heroTicketsLink} href="#tickets" className="btn-primary mt-5 min-h-11 lg:hidden">{t('buyer.EventDetail.chooseTickets')}</a>
          </div>
        </div>
      </div>

      {/* Gradient transition */}
      <div className="h-px bg-gradient-to-r from-transparent via-brand-500/20 to-transparent" />

      {/* Light content area */}
      <div className="bg-white">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
            {/* Sidebar - Tickets */}
            <motion.div
              ref={ticketPanel}
              id="tickets"
              tabIndex={-1}
              className="order-1 min-w-0 scroll-mt-24 rounded-2xl focus:outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-focus lg:order-2 lg:col-span-1"
              initial={false}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: reducedMotion ? 0 : 0.3 }}
            >
              <div className="lg:sticky lg:top-24">
                {waitlistOffer && !waitlistOffer.error && (
                  <div className="mb-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-5">
                    <p className="text-sm font-semibold text-emerald-900">{t('buyer.EventDetail.yourTicketsAreReserved')}</p>
                    <p className="mt-1 text-sm text-emerald-800">{t('buyer.EventDetail.reservedUntil', { quantity: waitlistOffer.quantity, ticket: waitlistOffer.ticket_type_name, time: formatEventTime(waitlistOffer.expires_at, event.timezone) })}</p>
                    {Number.isSafeInteger(waitlistOffer.all_in_price_cents) && waitlistOffer.all_in_price_cents > 0 && (
                      <p className="mt-1 text-sm font-semibold text-emerald-900">{t('buyer.EventDetail.eachFeesIncluded', { price: formatTicketPrice(waitlistOffer.all_in_price_cents) })}</p>
                    )}
                    <button className="btn-primary mt-4 w-full" onClick={() => handleCheckout([{ ticket_type_id: waitlistOffer.ticket_type_id, quantity: waitlistOffer.quantity }])}>{t('buyer.EventDetail.claimWaitlistOffer')}</button>
                  </div>
                )}
                {waitlistOffer?.error && <div className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{waitlistOffer.error}</div>}
                <div className="card p-3 sm:p-5">
                  {event.assigned_seating ? (
                    <SeatSelector event={event} onReserved={handleSeatCheckout} />
                  ) : event.ticket_types && event.ticket_types.length > 0 ? (
                    <TicketTypesSection ticketTypes={event.ticket_types} onCheckout={handleCheckout} showOriginal={content.showingOriginal} showTranslationNotice={!content.notice} />
                  ) : (
                    <p className="text-neutral-500 text-center py-4">{t('buyer.EventDetail.noTicketsAvailable')}</p>
                  )}
                  <div className="mt-4 space-y-1 border-t border-neutral-100 pt-3">
                    <AllInPriceNote ticketTypes={event.ticket_types || []} includesProcessing={event.service_fee_includes_processing === true}
                      platform={event.seller?.ticketing_service} />
                    <SellerLine seller={event.seller} />
                  </div>
                </div>
                {/* Waitlist form when all ticket types are sold out */}
                {event.ticket_types?.length > 0 &&
                  event.status === 'published' &&
                  event.ticket_types.every(tt => (tt.quantity_remaining ?? (tt.quantity_available - tt.quantity_sold)) <= 0) && (
                  <div className="mt-4">
                    <WaitlistForm event={event} ticketTypes={event.ticket_types} showOriginal={content.showingOriginal} />
                  </div>
                )}
              </div>
            </motion.div>

            {/* Main content */}
            <motion.div
              className="order-2 min-w-0 lg:order-1 lg:col-span-2"
              initial={false}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: reducedMotion ? 0 : 0.3 }}
            >
              {/* Action buttons */}
              <div className="flex flex-wrap items-center gap-2 mb-6">
                {event.starts_at && (
                  <a
                    href={buildGoogleCalendarUrl(event)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl border border-neutral-200 text-neutral-600 hover:text-brand-600 hover:border-brand-300 transition-colors text-sm font-medium"
                  >
                    <CalendarPlus className="w-4 h-4" />{t('buyer.EventDetail.addToCalendar')}</a>
                )}
                <button
                  onClick={handleShare}
                  className="inline-flex items-center gap-2 px-4 py-2.5 rounded-xl border border-neutral-200 text-neutral-600 hover:text-neutral-700 hover:border-neutral-300 transition-colors text-sm font-medium"
                >
                  {copied ? <Check className="w-4 h-4 text-emerald-500" /> : <Share2 className="w-4 h-4" />}
                  {copied ? t('buyer.EventDetail.copied') : t('buyer.EventDetail.share')}
                </button>
                <button onClick={() => marketplaceAction('favorite')} aria-pressed={event.favorited} className="inline-flex items-center gap-2 rounded-xl border border-neutral-200 px-4 py-2.5 text-sm font-medium text-neutral-600 hover:border-brand-300">
                  <Heart className={`h-4 w-4 ${event.favorited ? 'fill-accent-700 text-accent-700' : ''}`} />{event.favorited ? t('buyer.EventDetail.saved') : t('buyer.EventDetail.save')}
                </button>
                <button onClick={() => marketplaceAction('reminder')} aria-pressed={Boolean(event.reminder)} className="inline-flex items-center gap-2 rounded-xl border border-neutral-200 px-4 py-2.5 text-sm font-medium text-neutral-600 hover:border-brand-300">
                  <Bell className={`h-4 w-4 ${event.reminder ? 'fill-brand-500 text-brand-700' : ''}`} />{event.reminder ? t('buyer.EventDetail.reminderSet') : t('buyer.EventDetail.remindMe')}
                </button>
              </div>

              {/* Badges */}
              <div className="flex flex-wrap gap-2 mb-6">
                {event.age_restriction && event.age_restriction !== 'all_ages' && (
                  <span className="inline-flex items-center gap-1.5 text-xs font-medium bg-neutral-100 text-neutral-700 px-3 py-1.5 rounded-full">
                    <Users className="w-3 h-3" />
                    {ageLabels[event.age_restriction] || event.age_restriction}
                  </span>
                )}
                {event.doors_open_at && (
                  <span className="inline-flex items-center gap-1.5 text-xs font-medium bg-neutral-100 text-neutral-700 px-3 py-1.5 rounded-full">
                    <Clock className="w-3 h-3" />{t('buyer.EventDetail.doorsAt', { time: formatEventTime(event.doors_open_at, event.timezone) })}
                  </span>
                )}
              </div>

              {/* Who's Going */}
              <WhosGoing
                attendeeCount={event.attendee_count}
                attendeesPreview={event.attendees_preview}
                showAttendees={event.show_attendees}
              />

              {/* Description */}
              {content.description && (
                <FadeUp><div className="prose prose-neutral max-w-none mb-8">
                  <h2 className="text-lg font-semibold text-neutral-900 mb-3">{t('buyer.EventDetail.about')}</h2>
                  <p className="text-neutral-600 leading-relaxed whitespace-pre-wrap">{content.description}</p>
                </div></FadeUp>
              )}

              {event.organizer && <FadeUp><div className="mb-8 rounded-2xl border border-neutral-200 p-5"><p className="text-xs font-semibold uppercase tracking-wider text-neutral-600">{t('buyer.EventDetail.organizer')}</p><div className="mt-2 flex flex-wrap items-center justify-between gap-4"><div><Link to={`/organizers/${event.organizer.slug}`} className="text-lg font-bold text-neutral-900 hover:text-brand-600">{event.organizer.business_name}</Link>{event.organizer.verified && <span className="ml-2 text-xs font-semibold text-emerald-700">{t('buyer.EventDetail.verified')}</span>}</div><button onClick={() => marketplaceAction('follow')} aria-pressed={event.organizer.followed} className="btn-secondary inline-flex items-center gap-2"><UserPlus className="h-4 w-4" />{event.organizer.followed ? t('buyer.EventDetail.following') : t('buyer.EventDetail.follow')}</button></div></div></FadeUp>}

              {/* Venue Location Section */}
              {event.venue_address && (
                <FadeUp delay={0.1}><section aria-labelledby="event-location-heading" className="mb-8">
                  <h2 id="event-location-heading" className="text-lg font-semibold text-neutral-900 mb-3">{t('buyer.EventDetail.location')}</h2>
                  <div className="flex flex-col gap-4 rounded-2xl border border-neutral-200 p-4 sm:flex-row sm:items-center sm:p-5">
                    <div className="flex min-w-0 flex-1 items-start gap-3">
                      <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700">
                        <MapPin aria-hidden="true" className="h-5 w-5" />
                      </span>
                      <div className="min-w-0">
                        {event.venue_name && (event.venue?.slug
                          ? <Link to={`/venues/${event.venue.slug}`} className="font-semibold text-neutral-900 break-words hover:text-brand-700 hover:underline">{event.venue_name}</Link>
                          : <p className="font-semibold text-neutral-900 break-words">{event.venue_name}</p>)}
                        <p className="mt-0.5 text-sm text-neutral-600 [overflow-wrap:anywhere]">{event.venue_address}</p>
                      </div>
                    </div>
                    <a
                      href={buildMapsUrl(event)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="btn-secondary shrink-0 gap-2 !px-4 !py-2.5 text-sm"
                    >
                      <Navigation aria-hidden="true" className="h-4 w-4" />{t('buyer.EventDetail.directions')}<span className="sr-only">{t('buyer.EventDetail.opensGoogleMapsInANewTab')}</span>
                    </a>
                  </div>
                </section></FadeUp>
              )}
            </motion.div>


          </div>
        </div>
      </div>
      {onSale && <>
        {/* Room for the buy bar so the last content never sits underneath it. */}
        <div aria-hidden="true" className="h-[calc(5.5rem+env(safe-area-inset-bottom,0px))] bg-white lg:hidden" />
        <div ref={pageEnd} aria-hidden="true" className="h-px" />
        <MobileBuyBar priceLabel={buyBarPrice} targets={buyBarTargets} endMarker={pageEnd} />
      </>}
    </div>
  )
}

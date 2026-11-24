import { allInPriceNoteKey } from '../utils/priceDisclosure'
import { useTranslation } from 'react-i18next'
import { useState, useEffect, useLayoutEffect, useRef, version as reactVersion } from 'react'
import { useParams, useNavigate, useSearchParams, useLocation, Link } from 'react-router-dom'
import { Calendar, Clock, MapPin, Users, ArrowLeft, Share2, CalendarPlus, Check, Heart, Bell, UserPlus, Navigation, ChevronRight, AlertTriangle, BadgeCheck } from 'lucide-react'
import apiClient from '../api/client'
import usePricingScheduleRefresh from '../hooks/usePricingScheduleRefresh'
import { isTimeoutError, slowConnectionMessage } from '../api/errors'
import WhosGoing from '../components/WhosGoing'
import TicketTypesSection from '../components/TicketTypesSection'
import SeatSelector from '../components/SeatSelector'
import WaitlistForm from '../components/WaitlistForm'
import SEO from '../components/SEO'
import RouteLoading from '../components/RouteLoading'
import EventDescription from '../components/EventDescription'
import EventPageSections from '../components/EventPageSections'
import { normalizePageCustomization, approvedImageUrl } from '../utils/eventPageDesign'
import { accentStyle, focalPosition } from '../utils/eventPageDesign'
import MachineTranslationNotice from '../components/MachineTranslationNotice'
import useTranslatedContent from '../hooks/useTranslatedContent'
import useContentLanguage from '../hooks/useContentLanguage'
import NotFound from '../components/NotFound'
import { FadeUp } from '../components/ui/ScrollReveal'
import ChipRow from '../components/ui/ChipRow'
import { formatEventDate, formatEventTime, formatEventTimeRange } from '../utils/eventTime'
import { PUBLIC_WEB_URL } from '../utils/site'
import { eventBrowseReturn } from '../utils/browseReturn'
import { formatTicketPrice, priceSummary, purchasableAllInPrices } from '../utils/ticketPricing'
import { AllInPriceNote, SellerLine } from '../components/PriceDisclosure'
import { getPrimaryAction, selectionAction } from '../utils/eventPrimaryAction'
import { getServerNow } from '../utils/serverClock'
import { captureQueryAttribution, trackFunnel } from '../utils/marketplaceAttribution'

// React 18 does not know `inert` and only renders it from a string (''), while React 19
// treats it as a boolean and drops ''. Emit the value each version needs.
const INERT_VALUE = Number(reactVersion.split('.')[0]) >= 19 ? true : ''

// Phones see the ticket panel once near the top; this bar keeps the purchase one tap
// away while the hero button and the panel are out of view. It also stays hidden once
// the visitor reaches (or scrolls past) the end of the event content, so it never
// covers the footer.
function MobileBuyBar({ priceLabel, targets, endMarker, label, onAction, actionTarget }) {
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
        <a href={`#${actionTarget || 'tickets'}`} onClick={onAction} className="btn-primary event-buy shrink-0 !px-5 !py-2.5">{label}<ChevronRight aria-hidden="true" className="ml-1 h-4 w-4" />
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
  const location = useLocation()
  // Public pages can reuse their outlet when reduced motion is enabled.
  // Event inventory and offer selections belong to this specific route/context.
  return <EventDetailContent key={JSON.stringify([slug, location.pathname.endsWith('/preview'), location.hash,
    params.get('preview'), params.get('preview_token'), params.get('live_money_proof'), params.get('waitlist_offer')])} />
}

function EventDetailContent() {
  const { t } = useTranslation()
  const translation = useRef(t)
  translation.current = t
  const { slug } = useParams()
  const navigate = useNavigate()
  const location = useLocation()
  const browseFrom = eventBrowseReturn(location.state?.browseFrom)
  const liveRoute = useRef(null)
  const mounted = useRef(false)
  liveRoute.current = { slug }
  useLayoutEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])
  const [searchParams] = useSearchParams()
  const isPreview = searchParams.get('preview') === 'true'
  const legacyPreviewToken = searchParams.get('preview_token')
  const tokenRoute = location.pathname.endsWith('/preview')
  const previewToken = tokenRoute ? new URLSearchParams(location.hash.slice(1)).get('t') : null
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
  const [shareFallback, setShareFallback] = useState('')
  const [actionNotice, setActionNotice] = useState('')
  const [selection, setSelection] = useState({ lineItems: [], count: 0, totalCents: 0 })
  const [descriptionExpanded, setDescriptionExpanded] = useState(false)
  const resumedAction = useRef(false)
  const [waitlistOffer, setWaitlistOffer] = useState(null)
  useEffect(() => {
    if (!legacyPreviewToken) return
    const remaining = new URLSearchParams(location.search)
    remaining.delete('preview_token')
    navigate(`/events/${encodeURIComponent(slug)}/preview${remaining.size ? `?${remaining}` : ''}#t=${encodeURIComponent(legacyPreviewToken)}`, { replace: true })
  }, [legacyPreviewToken, location.search, navigate, slug])
  const heroTicketsLink = useRef(null)
  const ticketPanel = useRef(null)
  const pageEnd = useRef(null)
  const [buyBarTargets] = useState(() => [heroTicketsLink, ticketPanel])
  const waitlistOfferToken = searchParams.get('waitlist_offer')
  const content = useTranslatedContent(event)
  useLayoutEffect(() => {
    const panel = ticketPanel.current
    const inner = panel?.firstElementChild
    if (!inner) return undefined
    let frame = 0
    const measure = () => {
      frame = 0
      // Fit on first paint as well as after the panel sticks below the header.
      inner.style.setProperty('--ticket-panel-space', `${Math.max(112, panel.getBoundingClientRect().top + 16)}px`)
    }
    const schedule = () => { if (!frame) frame = requestAnimationFrame(measure) }
    measure()
    window.addEventListener('resize', schedule)
    window.addEventListener('scroll', schedule, { passive: true })
    return () => {
      cancelAnimationFrame(frame)
      window.removeEventListener('resize', schedule)
      window.removeEventListener('scroll', schedule)
    }
  }, [event, loading])

  const contentLanguage = useContentLanguage()
  const loadedLanguage = useRef(contentLanguage)

  useEffect(() => {
    let active = true
    const current = () => active && liveRoute.current.slug === slug
    if (!current() || legacyPreviewToken) return undefined
    if (!previewToken) captureQueryAttribution(window.location.search)
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
    const url = tokenRoute ? `/events/${slug}/private_preview` : isLiveMoneyProof ? `/events/${slug}?live_money_proof=true` :
      (isPreview ? `/events/${slug}?preview=true` : `/events/${slug}`)
    const request = tokenRoute ? apiClient.get(url, { headers: { 'X-Preview-Token': previewToken || '' } }) : apiClient.get(url)
    request
      .then(res => {
        if (!current()) return
        if (res.data.redirect_to) {
          navigate(`/events/${encodeURIComponent(res.data.redirect_to)}`, { replace: true })
          return
        }
        if (res.data.redirected_from === slug && res.data.slug && res.data.slug !== slug) {
          // An old link: show the event at its current address.
          const { search, hash, state } = liveLocation.current
          resolvedEventHandoff = { slug: res.data.slug, event: res.data }
          navigate(`/events/${encodeURIComponent(res.data.slug)}${tokenRoute ? '/preview' : ''}${search}${hash}`, { replace: true, state })
          return
        }
        if (res.data.slug !== slug) throw new Error('Event response does not match its route')
        setEvent(res.data)
        if (!res.data.private_preview) trackFunnel(apiClient, res.data.id, 'event_view')
        setLoading(false)
      })
      .catch(error => { if (current()) {
        setError(error.response?.status === 404
          ? { message: translation.current('buyer.EventDetail.eventNotFound'), retryable: false }
          : { message: isTimeoutError(error) ? slowConnectionMessage() : translation.current('buyer.EventDetail.thisEventCouldntLoadPleaseTryAgain'), retryable: true })
        setLoading(false)
      } })
    return () => { active = false }
  }, [slug, isPreview, previewToken, tokenRoute, legacyPreviewToken, isLiveMoneyProof, loadAttempt, navigate])

  usePricingScheduleRefresh(event, tokenRoute || isPreview ? null
    : `/events/${slug}${isLiveMoneyProof ? '?live_money_proof=true' : ''}`, setEvent)

  // Switching language reloads the event text quietly, keeping the page (and any
  // ticket selection) in place; the first load already used the current language.
  useEffect(() => {
    if (loadedLanguage.current === contentLanguage) return undefined
    loadedLanguage.current = contentLanguage
    if (!event) return undefined
    let active = true
    const url = tokenRoute ? `/events/${slug}/private_preview` : isLiveMoneyProof ? `/events/${slug}?live_money_proof=true` :
      (isPreview ? `/events/${slug}?preview=true` : `/events/${slug}`)
    const request = tokenRoute ? apiClient.get(url, { headers: { 'X-Preview-Token': previewToken || '' } }) : apiClient.get(url)
    request
      .then(res => { if (active && liveRoute.current.slug === slug && res.data.slug === slug) setEvent(res.data) })
      .catch(() => { /* Keep the text already shown; the next navigation retries. */ })
    return () => { active = false }
  }, [contentLanguage, event, slug, isPreview, previewToken, tokenRoute, isLiveMoneyProof])

  useEffect(() => {
    if (!waitlistOfferToken) return undefined
    let active = true
    apiClient.get(`/waitlist_offers/${encodeURIComponent(waitlistOfferToken)}`)
      .then(res => { if (active && liveRoute.current.slug === slug) setWaitlistOffer(res.data) })
      .catch(error => {
        if (!active || liveRoute.current.slug !== slug) return
        const withdrawn = error.response?.status === 410 && error.response?.data?.code === 'offer_withdrawn' && error.response?.data?.event_slug === slug
        setWaitlistOffer({ error: withdrawn
          ? "This ticket offer was withdrawn — you're still on the waitlist and we'll email you if tickets become available"
          : translation.current('buyer.EventDetail.offerUnavailable') })
      })
    return () => { active = false }
  }, [waitlistOfferToken, slug])

  const handleCheckout = (lineItems) => {
    if (event?.private_preview) return
    if (!mounted.current || liveRoute.current.slug !== slug || event?.slug !== slug) return
    const offer = waitlistOfferToken && waitlistOffer && !waitlistOffer.error ? waitlistOffer : null
    navigate(`/checkout/${slug}`, { state: { event, lineItems, waitlistOfferToken, waitlistOffer: offer, liveMoneyProof: isLiveMoneyProof, browseFrom } })
  }

  const handleSeatCheckout = ({ lineItems, seatHoldToken, seatHoldExpiresAt, seats }) => {
    if (event?.private_preview) return
    if (!mounted.current || liveRoute.current.slug !== slug || event?.slug !== slug) return
    navigate(`/checkout/${slug}`, {
      state: { event, lineItems, seatHoldToken, seatHoldExpiresAt, selectedSeats: seats, browseFrom },
    })
  }

  const marketplaceAction = async (kind, ensureOn = false) => {
    if (!event || event.private_preview) return
    const enabled = kind === 'favorite' ? event.favorited : kind === 'follow' ? event.organizer?.followed : event.reminder
    if (ensureOn && enabled) return
    const update = () => setEvent(current => kind === 'follow'
      ? { ...current, organizer: { ...current.organizer, followed: !enabled } }
      : { ...current, [kind === 'favorite' ? 'favorited' : 'reminder']: !enabled })
    if (import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1') {
      update()
      setActionNotice('Saved for this demo visit. Sign-in and email notifications are off in this preview.')
      return
    }
    try {
      const collection = kind === 'favorite' ? 'event_favorites' : kind === 'follow' ? 'organizer_follows' : 'event_reminders'
      const id = kind === 'follow' ? event.organizer.id : event.id
      if (enabled) await apiClient.delete(`/me/${collection}/${id}`)
      else await apiClient.post(`/me/${collection}`, kind === 'follow' ? { organization_id: id } : { event_id: id })
      if (mounted.current) update()
      setActionNotice(t('eventActions.actionSaved'))
    } catch (error) {
      if (error.response?.status === 401) {
        const params = new URLSearchParams(location.search)
        params.set('marketplace_action', kind)
        const returnTo = `${location.pathname}?${params}${location.hash}`
        navigate(`/sign-in?returnTo=${encodeURIComponent(returnTo)}`)
      } else setActionNotice(t('eventActions.actionFailed'))
    }
  }

  const marketplaceActionRef = useRef(marketplaceAction)
  marketplaceActionRef.current = marketplaceAction

  // The return URL carries an idempotent intent, consumed once after the event
  // loads. Only this event's action is resumed; ordinary visits never mutate it.
  useEffect(() => {
    const kind = searchParams.get('marketplace_action')
    if (!event || loading || resumedAction.current || !['favorite', 'follow', 'reminder'].includes(kind)) return
    resumedAction.current = true
    const params = new URLSearchParams(location.search)
    params.delete('marketplace_action')
    navigate(`${location.pathname}${params.size ? `?${params}` : ''}${location.hash}`, { replace: true, state: location.state })
    void marketplaceActionRef.current(kind, true)
    // The intent is consumed once, after this route's event is ready.
  }, [event, loading, searchParams, location, navigate])

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
        const summary = priceSummary(event.ticket_types || [])
        const priceText = !summary ? '' : summary.kind === 'free' ? `${t('events.free')}. ` : `${t('buyer.EventDetail.from', { value1: formatTicketPrice(summary.cents) })}. ${t(allInPriceNoteKey(event.ticket_types, event.service_fee_includes_processing === true), { platform: 'HåfaPass' })} `
        await navigator.share({ title: event.title, text: `${priceText}${event.short_description || event.description?.slice(0, 120) || ''}`, url })
      } catch {
        // Share cancellation is user-driven; no visible error needed.
      }
    } else {
      try {
        await navigator.clipboard.writeText(url)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      } catch { setShareFallback(url) }
    }
  }

  const buildMapsUrl = (evt) => {
    const q = encodeURIComponent([evt.venue_name, evt.venue_address].filter(Boolean).join(', '))
    return `https://www.google.com/maps/search/?api=1&query=${q}`
  }

  if (loading) return <RouteLoading />
  if (error && !error.retryable) return <div className="route-loading"><NotFound kind="event" backTo={browseFrom} /></div>
  if (error) return (
    <div className="max-w-2xl mx-auto px-4 py-16 text-center">
      <p role="alert" className="text-neutral-700 text-lg mb-4">{error.message}</p>
      {error.retryable && <button type="button" className="btn-primary mb-4" onClick={() => setLoadAttempt(attempt => attempt + 1)}>{t('buyer.EventDetail.retryEvent')}</button>}
      <Link to={browseFrom} className="btn-primary">{t('buyer.EventDetail.browseEvents')}</Link>
    </div>
  )
  if (!event) return null

  const organizerName = event.organizer?.business_name || event.organizer?.name || ''
  const truncatedDescription = (event.short_description || event.description || '').slice(0, 160)
  const eventUrl = `${PUBLIC_WEB_URL}/events/${event.slug}`
  const summary = priceSummary(event.ticket_types || [])
  const advertisedDescription = !summary ? truncatedDescription
    : `${summary.kind === 'free' ? t('events.free') : `${t('buyer.EventDetail.from', { value1: formatTicketPrice(summary.cents) })}. ${t(allInPriceNoteKey(event.ticket_types, event.service_fee_includes_processing === true), { platform: 'HåfaPass' })}`}. ${truncatedDescription}`.slice(0, 160)
  // A direct link still opens after a postponement or cancellation so ticket
  // holders can read the status; sales are closed and the page offers no buying.
  const closedStatus = ['postponed', 'cancelled'].includes(event.status) ? event.status : null
  const primaryAction = getPrimaryAction(event, summary, getServerNow())
  const onSale = ['paid', 'free'].includes(primaryAction.kind)
  const selectedAction = selectionAction({ ...selection, formattedTotal: formatTicketPrice(selection.totalCents) })
  const openPrimaryAction = click => {
    click.preventDefault()
    if (primaryAction.kind === 'notify') return void marketplaceAction('reminder')
    const panel = document.getElementById(primaryAction.target || 'tickets')
    panel?.scrollIntoView({ behavior: 'auto', block: 'start' })
    if (primaryAction.kind === 'waitlist') panel?.querySelector('input')?.focus({ preventScroll: true })
    else panel?.focus({ preventScroll: true })
  }
  const barAction = click => {
    if (onSale && selection.count && !event.assigned_seating) { click.preventDefault(); handleCheckout(selection.lineItems) }
    else openPrimaryAction(click)
  }
  const buyBarPrice = primaryAction.kind === 'waitlist' ? t('events.soldOut') : primaryAction.kind === 'notify' ? t('eventActions.salesOpen', { date: formatEventDate(primaryAction.opensAt, event.timezone, { month: 'short', year: undefined }) }) : summary?.kind === 'free' ? t('buyer.EventDetail.free') : summary ? t('buyer.EventDetail.from', { value1: formatTicketPrice(summary.cents) }) : t('buyer.EventDetail.ticketsAvailable')

  // Build JSON-LD structured data for the event
  const ticketTypes = event.ticket_types || []
  // Offers carry all-in prices (ticket + mandatory buyer fee), like every other display.
  const prices = purchasableAllInPrices(ticketTypes).map(price => price / 100)
  const design = normalizePageCustomization(event.page_customization)
  const eventAccentStyle = accentStyle(design.accent)
  const coverImage = approvedImageUrl(event.cover_image_url, event.image_asset_host) ? event.cover_image_url : null
  const lineup = design.sections.find(section => section.type === 'lineup' && section.enabled)
  const eventJsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Event',
    name: event.title,
    startDate: event.starts_at,
    ...(event.ends_at && { endDate: event.ends_at }),
    ...(closedStatus && { eventStatus: closedStatus === 'postponed' ? 'https://schema.org/EventPostponed' : 'https://schema.org/EventCancelled' }),
    description: advertisedDescription,
    ...(coverImage && { image: coverImage }),
    ...(lineup?.items?.length && { performer: lineup.items.map(item => ({ '@type': 'Person', name: item.name })) }),
    url: eventUrl,
    ...(event.venue_name && {
      location: {
        '@type': 'Place',
        name: event.venue_name,
        ...(event.venue_address && { address: event.venue_address }),
      },
    }),
    ...(prices.length > 0 && !closedStatus && {
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
    <div className={`public-listing-min-height${eventAccentStyle ? ' event-customized' : ''}`} style={eventAccentStyle}>
      <SEO
        title={event.title}
        description={advertisedDescription}
        image={coverImage || undefined}
        url={eventUrl}
        jsonLd={eventJsonLd}
        noIndex={isLiveMoneyProof || event.private_preview}
        noSocial={event.private_preview}
      />
      {event.private_preview && <div role="status" className="border-b border-amber-300 bg-amber-50 px-4 py-4 text-center text-sm font-semibold text-amber-950">
        {t('organizerVerification.previewBanner')}
      </div>}
      {closedStatus && <div role="status" className={`border-b px-4 py-4 text-center text-sm font-semibold ${closedStatus === 'cancelled' ? 'border-red-200 bg-red-50 text-red-900' : 'border-amber-300 bg-amber-50 text-amber-950'}`}>
        <AlertTriangle aria-hidden="true" className="mr-2 inline h-4 w-4 align-[-2px]" />
        {t(closedStatus === 'cancelled' ? 'buyer.EventDetail.cancelledBanner' : 'buyer.EventDetail.postponedBanner')}
      </div>}
      {/* One grid keeps purchasing beside the title on desktop and after the artwork on phones. */}
      <div className="bg-white">
        <div className={`max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 pt-2 ${onSale ? 'pb-4 lg:pb-8' : 'pb-8'}`}>
                        {/* Back link */}
              <Link to={browseFrom} className="mb-3 flex min-h-11 w-fit items-center gap-1.5 text-sm font-medium text-brand-800 transition-colors hover:text-brand-900">
                <ArrowLeft aria-hidden="true" className="w-4 h-4" />{t('buyer.EventDetail.allEvents')}</Link>


          <div className="grid grid-cols-1 items-start gap-8 lg:grid-cols-3">
            <section className="min-w-0 lg:col-span-2">
              {coverImage && (
                <div className="event-art relative mb-5">
                  <div className="relative aspect-video overflow-hidden rounded-2xl bg-neutral-100 ring-1 ring-black/5">
                    <img src={coverImage} alt={event.title} width="1600" height="900" fetchpriority="high"
                      className="h-full w-full object-cover" style={{ objectPosition: focalPosition(design) }} />
                  </div>
                </div>
              )}

              {event.category && event.category !== 'other' && (
                <span className="block text-sm font-semibold text-brand-800 mb-1">
                  {t(`buyer.categories.${event.category}`, { defaultValue: event.category_label || event.category })}
                </span>
              )}
              <h1 className="font-display text-4xl sm:text-5xl lg:text-[3.5rem] font-bold leading-tight tracking-tight text-neutral-950 mb-3 break-words">{content.title}</h1>
              {content.notice && <MachineTranslationNotice {...content.notice} className="mb-3" />}

              {/* Bento strip: one card with 1px dividers for the key facts guests check. */}
              <dl className="event-bento mt-5 grid grid-cols-1 gap-px overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-200 sm:grid-cols-2">
                {event.starts_at && <div className="bg-white px-4 py-3">
                  <dt className="flex items-center gap-2 text-sm font-semibold text-neutral-600"><Calendar aria-hidden="true" className="h-4 w-4 text-brand-800" />{t('buyer.EventDetail.dateAndTime')}</dt>
                  <dd className="mt-1 text-base font-semibold text-neutral-950">{formatEventDate(event.starts_at, event.timezone, { weekday: 'long', month: 'long' })}</dd>
                  <dd className="text-base text-neutral-700 [overflow-wrap:anywhere]">{formatEventTimeRange(event.starts_at, event.ends_at, event.timezone)}</dd>
                </div>}
                {event.doors_open_at && <div className="bg-white px-4 py-3">
                  <dt className="flex items-center gap-2 text-sm font-semibold text-neutral-600"><Clock aria-hidden="true" className="h-4 w-4 text-brand-800" />{t('buyer.EventDetail.doorsOpen')}</dt>
                  <dd className="mt-1 text-base font-semibold text-neutral-950">{formatEventTime(event.doors_open_at, event.timezone)}</dd>
                </div>}
                {(event.venue_name || event.venue_address) && <div className="bg-white px-4 py-3 sm:col-span-2">
                  <dt className="flex items-center gap-2 text-sm font-semibold text-neutral-600"><MapPin aria-hidden="true" className="h-4 w-4 text-brand-800" />{t('buyer.EventDetail.venue')}</dt>
                  <dd className="text-base font-semibold text-neutral-950 [overflow-wrap:anywhere]">{event.venue?.slug
                    ? <Link to={`/venues/${event.venue.slug}`} className="inline-flex min-h-11 items-center text-brand-800 hover:underline">{event.venue_name}</Link>
                    : event.venue_name}</dd>
                  <dd className="text-base text-neutral-700 [overflow-wrap:anywhere]">{event.venue_address || event.venue_city}</dd>
                  <dd><a href={buildMapsUrl(event)} target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-brand-800"><Navigation aria-hidden="true" className="h-4 w-4" />{t('buyer.EventDetail.directions')}<span className="sr-only">{t('buyer.EventDetail.opensGoogleMapsInANewTab')}</span></a></dd>
                </div>}
              </dl>
              {primaryAction.actionable && <a ref={heroTicketsLink} href={`#${primaryAction.target || 'tickets'}`} onClick={openPrimaryAction} className="btn-primary event-buy mt-5 min-h-12 w-full sm:w-auto lg:hidden">{t(primaryAction.labelKey)}</a>}
              {primaryAction.kind === 'notify' && <p className="mt-2 text-sm text-neutral-600">{t('eventActions.onSale', { date: formatEventDate(primaryAction.opensAt, event.timezone, { weekday: 'short', month: 'short', year: undefined }), time: formatEventTime(primaryAction.opensAt, event.timezone) })}</p>}
              {primaryAction.kind === 'past' && <div className="mt-5"><button disabled className="min-h-12 w-full rounded-xl bg-neutral-200 px-6 font-semibold text-neutral-600 sm:w-auto">{t(primaryAction.labelKey)}</button><Link to="/orders/recover" className="mt-2 flex min-h-11 items-center font-semibold text-brand-800 underline">{t('buyer.EventDetail.findMyTickets')}</Link></div>}
              <WhosGoing compact attendeeCount={event.attendee_count} attendeesPreview={event.attendees_preview} showAttendees={event.show_attendees} />
            </section>

            {/* Sidebar - Tickets */}
            {primaryAction.kind !== 'past' && <div
              ref={ticketPanel}
              id="tickets"
              tabIndex={-1}
              className="min-w-0 scroll-mt-24 rounded-2xl focus:outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-focus lg:col-start-3 lg:row-start-1 lg:row-span-2 lg:self-stretch"
            >
              <div className="lg:sticky lg:top-24 lg:max-h-[calc(100dvh-var(--ticket-panel-space,7rem))] lg:overflow-y-auto overscroll-contain">
                {!closedStatus && !event.private_preview && waitlistOffer && !waitlistOffer.error && (
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
                {primaryAction.kind === 'waitlist' && <div id="waitlist" className="scroll-mt-24"><WaitlistForm event={event} ticketTypes={event.ticket_types} showOriginal={content.showingOriginal} accent soldOutFirst /></div>}
                <div className="card p-3 sm:p-5">
                  {closedStatus ? (
                    <div className="p-2 text-sm text-neutral-700">
                      <p className="font-semibold text-neutral-900">{t('buyer.EventDetail.salesClosed')}</p>
                      <Link to="/orders/recover" className="mt-3 inline-flex min-h-11 items-center font-semibold text-brand-700 underline">{t('buyer.EventDetail.findMyTickets')}</Link>
                    </div>
                  ) : event.private_preview ? (
                    <div className="rounded-xl bg-amber-50 p-4 text-sm text-amber-950">
                      <button type="button" disabled aria-describedby="preview-ticket-explanation" className="btn-primary w-full min-h-11 opacity-60">{t('buyer.EventDetail.getTickets')}</button>
                      <p id="preview-ticket-explanation" className="mt-2">{t('organizerVerification.previewTicketsDisabled')}</p>
                    </div>
                  ) : event.assigned_seating ? (
                    <SeatSelector event={event} onReserved={handleSeatCheckout} />
                  ) : event.ticket_types && event.ticket_types.length > 0 ? (
                    primaryAction.kind === 'waitlist' ? <details><summary className="min-h-11 cursor-pointer font-semibold text-neutral-700">{t('eventActions.soldOutTypes', { count: event.ticket_types.length })}</summary><TicketTypesSection ticketTypes={event.ticket_types} onCheckout={handleCheckout} onSelectionChange={setSelection} primaryAction={primaryAction} onPrimaryAction={openPrimaryAction} showOriginal={content.showingOriginal} showTranslationNotice={!content.notice} /></details> : <TicketTypesSection ticketTypes={event.ticket_types} onCheckout={handleCheckout} onSelectionChange={setSelection} primaryAction={primaryAction} onPrimaryAction={openPrimaryAction} showOriginal={content.showingOriginal} showTranslationNotice={!content.notice} />
                  ) : (
                    <p className="text-neutral-500 text-center py-4">{t('buyer.EventDetail.noTicketsAvailable')}</p>
                  )}
                  {!closedStatus && <div className="mt-4 space-y-1 border-t border-neutral-100 pt-3">
                    <AllInPriceNote ticketTypes={event.ticket_types || []} includesProcessing={event.service_fee_includes_processing === true}
                      platform={event.seller?.ticketing_service} />
                    <SellerLine seller={event.seller} />
                  </div>}
                </div>
              </div>
            </div>}

            {/* Main content */}
            <div className="min-w-0 lg:col-span-2 lg:col-start-1 lg:row-start-2">
              {/* Action buttons */}
              {!event.private_preview && (
                <ChipRow role="group" ariaLabel="Event actions" bleed="mobile" className="">
                  {event.starts_at && !closedStatus && (
                    <a
                      href={buildGoogleCalendarUrl(event)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="chip"
                    >
                      <CalendarPlus aria-hidden="true" className="h-4 w-4 shrink-0" />
                      {t('buyer.EventDetail.addToCalendar')}
                    </a>
                  )}
                  <button type="button" onClick={handleShare} className="chip">
                    {copied ? <Check aria-hidden="true" className="h-4 w-4 shrink-0 text-emerald-600" /> : <Share2 aria-hidden="true" className="h-4 w-4 shrink-0" />}
                    {copied ? t('buyer.EventDetail.copied') : t('buyer.EventDetail.share')}
                  </button>
                  <button type="button" onClick={() => marketplaceAction('favorite')} aria-pressed={Boolean(event.favorited)} className="chip">
                    <Heart aria-hidden="true" className={`h-4 w-4 shrink-0 ${event.favorited ? 'fill-current' : ''}`} />
                    {event.favorited ? t('buyer.EventDetail.saved') : t('buyer.EventDetail.save')}
                  </button>
                  {!closedStatus && primaryAction.kind !== 'notify' && primaryAction.kind !== 'past' && (
                    <button type="button" onClick={() => marketplaceAction('reminder')} aria-pressed={Boolean(event.reminder)} className="chip">
                      <Bell aria-hidden="true" className={`h-4 w-4 shrink-0 ${event.reminder ? 'fill-current' : ''}`} />
                      {event.reminder ? t('buyer.EventDetail.reminderSet') : t('buyer.EventDetail.remindMe')}
                    </button>
                  )}
                </ChipRow>
              )}

              {actionNotice && <p role="status" className="mt-3 text-sm text-neutral-600">{actionNotice}</p>}
              {shareFallback && <label className="mt-3 block text-sm text-neutral-600">{t('eventActions.copyLink')}<input readOnly className="input mt-2" value={shareFallback} onFocus={e => e.target.select()} /><button type="button" className="btn-secondary mt-2" onClick={async () => { try { await navigator.clipboard.writeText(shareFallback); setCopied(true); setShareFallback('') } catch { /* The selected URL can be copied manually. */ } }}>{t('eventActions.copy')}</button></label>}
              {/* Badges */}
              {event.age_restriction && event.age_restriction !== 'all_ages' && (
                <ChipRow bleed="mobile" className="mb-6">
                  <span className="inline-flex h-8 items-center gap-1.5 rounded-full bg-neutral-100 px-3 text-xs font-medium text-neutral-700 whitespace-nowrap">
                    <Users aria-hidden="true" className="h-3.5 w-3.5" />
                    {ageLabels[event.age_restriction] || event.age_restriction}
                  </span>
                </ChipRow>
              )}

              {/* Description */}
              {content.description && (
                <FadeUp><div className="mt-9 sm:mt-12">
                  <h2 className="font-display text-2xl font-bold text-neutral-950 sm:text-3xl mb-4 mt-0">{t('buyer.EventDetail.about')}</h2>
                  <div id="event-description" className={!descriptionExpanded && content.description.length > 600 ? 'line-clamp-6' : ''}><EventDescription text={content.description} format={design.description_format} /></div>
                  {content.description.length > 600 && <button type="button" aria-controls="event-description" aria-expanded={descriptionExpanded} onClick={() => setDescriptionExpanded(value => !value)} className="inline-flex min-h-11 items-center text-sm font-semibold text-brand-800">{t(descriptionExpanded ? 'eventActions.readLess' : 'eventActions.readMore')}</button>}
                </div></FadeUp>
              )}

              <EventPageSections design={design} imageAssetHost={event.image_asset_host} />

              {event.organizer && (
                <FadeUp>
                  <div className="mt-9 sm:mt-12 rounded-2xl border border-neutral-200 p-5">
                    <p className="text-xs font-semibold uppercase tracking-[0.08em] text-neutral-600">{t('buyer.EventDetail.organizer')}</p>
                    <div className="mt-2 flex flex-wrap items-center justify-between gap-4">
                      <div className="flex min-w-0 flex-1 items-center gap-3">
                        {approvedImageUrl(event.organizer.logo_url, event.image_asset_host) && (
                          <img src={event.organizer.logo_url} alt="" loading="lazy" width="48" height="48" className="h-12 w-12 shrink-0 rounded-xl object-contain" />
                        )}
                        <p className="min-w-0 text-lg font-bold leading-snug text-neutral-950">
                          {event.private_preview ? (
                            <span>
                              {organizerName.split(' ').slice(0, -1).join(' ')}{' '}<span className="whitespace-nowrap">{organizerName.split(' ').at(-1)}
                              {event.organizer.verified && (
                                <BadgeCheck
                                  aria-label={t('buyer.EventDetail.verified')}
                                  className="ml-1.5 inline-block h-[0.95em] w-[0.95em] align-[-0.14em] text-emerald-700"
                                />
                              )}</span>
                            </span>
                          ) : (
                            <Link to={`/organizers/${event.organizer.slug}`} className="hover:text-brand-600">
                              {organizerName.split(' ').slice(0, -1).join(' ')}{' '}<span className="whitespace-nowrap">{organizerName.split(' ').at(-1)}
                              {event.organizer.verified && (
                                <BadgeCheck
                                  aria-label={t('buyer.EventDetail.verified')}
                                  className="ml-1.5 inline-block h-[0.95em] w-[0.95em] align-[-0.14em] text-emerald-700"
                                />
                              )}</span>
                            </Link>
                          )}
                        </p>
                      </div>
                      {!event.private_preview && (
                        <button type="button" onClick={() => marketplaceAction('follow')} aria-pressed={event.organizer.followed} className="btn-secondary inline-flex shrink-0 items-center gap-2">
                          <UserPlus aria-hidden="true" className="h-4 w-4" />
                          {event.organizer.followed ? t('buyer.EventDetail.following') : t('buyer.EventDetail.follow')}
                        </button>
                      )}
                    </div>
                  </div>
                </FadeUp>
              )}

            </div>


          </div>
        </div>
      </div>
      {primaryAction.actionable && <>
        {/* Room for the buy bar so the last content never sits underneath it. */}
        <div aria-hidden="true" className="h-[calc(4.5rem+env(safe-area-inset-bottom,0px))] bg-white lg:hidden" />
        <div ref={pageEnd} aria-hidden="true" className="h-px" />
        <MobileBuyBar priceLabel={selection.count ? t('eventActions.selection', { count: selection.count, total: formatTicketPrice(selection.totalCents) }) : buyBarPrice} targets={buyBarTargets} endMarker={pageEnd} actionTarget={primaryAction.target}
          label={onSale && selection.count ? t(selection.totalCents === 0 ? selectedAction.key : 'eventActions.checkout', selectedAction.values) : t(primaryAction.labelKey)} onAction={barAction} />
      </>}
    </div>
  )
}

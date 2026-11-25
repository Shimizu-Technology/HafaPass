import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { CalendarDays, CheckCircle2, Circle, CircleAlert, Copy, ExternalLink, Loader2, MapPin } from 'lucide-react'
import apiClient from '../../api/client'
import EventWorkspace from '../../components/EventWorkspace'
import { BackLink, WorkspacePage } from '../../components/WorkspacePage'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { formatEventDateTime } from '../../utils/eventTime'
import { formatMoneyCents } from '../../utils/money'
import { PUBLIC_WEB_URL } from '../../utils/site'
import useLaunchCapabilities from '../../hooks/useLaunchCapabilities'
import { eventToolLinks } from '../../utils/eventWorkspaceNavigation'
import { canViewOrganizationActivity, loadOrganizerOrganizations } from '../../utils/organizerOrganizations'
import { organizerChecklist } from '../../utils/organizerChecklist'
import { serviceDayString } from '../../utils/reEntryRules'
import VerificationNotice from '../../components/VerificationNotice'
import { useTranslation } from 'react-i18next'

const statusCopy = {
  draft: 'Draft — only your team can see it.',
  published: 'Published — buyers can find it and get tickets.',
  postponed: 'Postponed — ticket holders keep their tickets until a new date is set.',
  cancelled: 'Cancelled — sales are closed.',
  completed: 'Completed — the event has ended.',
  archived: 'Archived — kept for your records.',
}

// Sales held back by HåfaPass organizer verification, mapped to the
// verification state to show if the organizer profile cannot be loaded.
const verificationReasons = { organizer_not_verified: 'unverified', organizer_verification_requested: 'pending', organizer_paused: 'suspended' }

// Four plain steps for a first-time volunteer organizer. Each links to the
// tool that finishes it when this teammate may use that tool. Questions and
// waivers are optional, so that step never counts as unfinished.
// Publishing needs event management as well as content editing, and a
// published event may still be a private preview until verification.
function setupChecklist(event, has, publiclyVisible) {
  const base = `/dashboard/events/${event.id}`
  const published = ['published', 'postponed', 'completed'].includes(event.status)
  const ticketTypes = (event.ticket_types || []).length
  return [
    { key: 'tickets', label: 'Ticket types set up', state: ticketTypes ? 'done' : 'todo',
      detail: ticketTypes ? `${ticketTypes} ticket ${ticketTypes === 1 ? 'type' : 'types'} ready.` : 'Add at least one ticket, free or paid.',
      link: has('manage_inventory') && has('edit_event_content') ? { to: `${base}/edit#ticket-types`, label: ticketTypes ? 'Review tickets' : 'Add tickets' } : null },
    { key: 'questions', label: 'Questions & waivers', state: 'optional',
      detail: 'Optional. Ask buyers a question at checkout or have them sign a waiver.',
      link: has('manage_events') ? { to: `${base}/sales-tools`, label: 'Set up questions' } : null },
    { key: 'publish', label: 'Event published', state: published ? 'done' : 'todo',
      detail: !published ? 'Only your team can see it until you publish.'
        : publiclyVisible ? 'Buyers can find your event.' : 'Published as a private preview. Only people with the preview link can see it for now.',
      link: !published && has('edit_event_content') && has('manage_events') ? { to: `${base}/edit`, label: 'Review and publish' } : null },
    { key: 'scanner', label: 'Door scanner ready', state: published && ticketTypes ? 'done' : 'todo',
      detail: published && ticketTypes ? 'Open the Door Scanner on any phone to check tickets in.' : 'Ready once your event is published with tickets.',
      link: published && has('scan') ? { to: `/dashboard/scanner?event=${event.id}`, label: 'Open Door Scanner' } : null },
  ]
}

// The server message may repeat the headline shown above it.
const salesDetail = message => {
  const detail = (message || '').replace(/^(Visible but not on sale yet|Sales paused by HåfaPass)[:.]?\s*/i, '')
  return detail && detail[0].toUpperCase() + detail.slice(1)
}

export default function EventOverviewPage() {
  const { id } = useParams()
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(`/dashboard/events/${id}`)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <EventOverviewSession key={`${identity.accountKey}:${identity.organizationId}:${id}:${visit.generation}`} id={id} identity={identity} />
}

function EventOverviewSession({ id, identity }) {
  const { t } = useTranslation()
  const { current, beginRequest } = useOrganizerRequests(identity, `/dashboard/events/${id}`)
  const [event, setEvent] = useState(null)
  // Sales and door numbers load after the event: { status, stats, admissions }.
  const [extras, setExtras] = useState({ status: 'idle' })
  const [currency, setCurrency] = useState('USD')
  const [canViewActivity, setCanViewActivity] = useState(false)
  // GET /organizer_profile, loaded only when verification holds back sales.
  const [profile, setProfile] = useState({ status: 'idle' })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [copyState, setCopyState] = useState(null)
  const [previewUrl, setPreviewUrl] = useState('')
  const [confirmNewPreview, setConfirmNewPreview] = useState(false)
  const [previewError, setPreviewError] = useState('')
  const generation = useRef(0)
  const extrasGeneration = useRef(0)
  const capabilities = useLaunchCapabilities()

  const get = useCallback(async url => {
    const request = beginRequest()
    if (!request) throw new DOMException('Page context changed', 'AbortError')
    try {
      const response = await apiClient.get(url, request.config)
      if (!request.current()) throw new DOMException('Page context changed', 'AbortError')
      return response
    } finally { request.release() }
  }, [beginRequest])

  // A failure here leaves the rest of the overview usable and offers a retry.
  const loadExtras = useCallback(async saved => {
    const permissions = saved.permissions || {}
    const wantsStats = permissions.view_finance === true
    const wantsAdmissions = !wantsStats && permissions.scan === true
    if (!wantsStats && !wantsAdmissions) { setExtras({ status: 'idle' }); return }
    const attempt = ++extrasGeneration.current
    const canApply = () => current() && attempt === extrasGeneration.current
    setExtras({ status: 'loading' })
    try {
      const response = await get(`/organizer/events/${id}/${wantsStats ? 'stats' : 'admissions'}`)
      if (!canApply()) return
      setExtras(wantsStats ? { status: 'ready', stats: response.data } : { status: 'ready', admissions: response.data?.counts || null })
    } catch {
      if (canApply()) setExtras({ status: 'error' })
    }
  }, [current, get, id])

  const load = useCallback(async () => {
    if (!current()) return
    const attempt = ++generation.current
    const canApply = () => current() && attempt === generation.current
    setLoading(true); setError(null); setExtras({ status: 'idle' }); setCanViewActivity(false)
    try {
      const saved = (await get(`/organizer/events/${id}`)).data
      if (!canApply()) return
      if (String(saved.id) !== String(id) || (identity.organizationId != null && saved.organization_id != null && String(saved.organization_id) !== String(identity.organizationId))) {
        setEvent(null)
        setError('This event could not be matched to the selected organization. Return to your dashboard and pick it again.')
        return
      }
      setEvent(saved)
      if (saved.status === 'published' && saved.permissions?.manage_events && saved.publicly_visible === false &&
        (['unverified', 'pending', 'rejected'].includes(saved.organizer_verification_status) ||
          (!saved.organizer_verification_status && ['organizer_not_verified', 'organizer_verification_requested'].includes(saved.sales_status?.reason)))) {
        get(`/organizer/events/${id}/preview_link`).then(response => { if (canApply()) setPreviewUrl(response.data.url) }).catch(() => {})
      }
      setLoading(false)
      void loadExtras(saved)
      if (verificationReasons[saved.sales_status?.reason] || ['unverified', 'pending', 'rejected', 'suspended'].includes(saved.organizer_verification_status)) {
        setProfile({ status: 'loading' })
        get('/organizer_profile').then(response => { if (canApply()) setProfile({ status: 'ready', data: response.data }) })
          .catch(() => { if (canApply()) setProfile({ status: 'error' }) })
      }
      // Same currency source as the dashboard: the selected organization.
      loadOrganizerOrganizations(identity.authContext).then(response => {
        const match = (Array.isArray(response.data) ? response.data : []).find(item => String(item.id) === String(saved.organization_id))
        if (canApply() && match?.currency) setCurrency(match.currency)
        if (canApply()) setCanViewActivity(canViewOrganizationActivity(match))
      }).catch(() => {})
    } catch (requestError) {
      if (!canApply()) return
      setEvent(null)
      const status = requestError.response?.status
      setError(status === 401 ? 'Please sign in to see this event.'
        : status === 403 ? 'You don’t have access to this event. Ask your organization owner if you need it.'
          : status === 404 ? 'Event not found.' : 'We could not load this event. Please try again.')
    } finally { if (canApply()) setLoading(false) }
  }, [current, get, id, identity.authContext, identity.organizationId, loadExtras])
  useEffect(() => { load() }, [load])

  const copyLink = async url => {
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable')
      await navigator.clipboard.writeText(url)
      setCopyState('copied')
    } catch { setCopyState('failed') }
  }

  const sharePreview = async () => {
    if (!previewUrl) return
    if (navigator.share) {
      try { await navigator.share({ title: event.title, url: previewUrl }); return } catch (error) {
        if (error?.name === 'AbortError') return
      }
    }
    await copyLink(previewUrl)
  }

  const rotatePreview = async () => {
    const request = beginRequest()
    if (!request) return false
    setPreviewError('')
    try {
      const response = await apiClient.post(`/organizer/events/${id}/rotate_preview_link`, {}, request.config)
      if (request.current()) { setPreviewUrl(response.data.url); setCopyState(null); return true }
    } catch { if (request.current()) setPreviewError('Could not get a new preview link. Try again.') }
    finally { request.release() }
    return false
  }

  if (loading && !event) {
    return <EventWorkspace eventId={id} event={null}>
      <p role="status" className="flex items-center gap-2 text-sm text-neutral-700"><Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" />Loading event overview…</p>
    </EventWorkspace>
  }
  if (!event) {
    return <WorkspacePage width="form">
      <BackLink>All events</BackLink>
      <div className="mt-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700" role="alert">
        <p>{error}</p>
        <button type="button" onClick={load} className="mt-2 min-h-11 font-semibold underline">Try again</button>
      </div>
    </WorkspacePage>
  }

  const has = key => event.permissions?.[key] === true
  const { stats, admissions } = extras
  const ticketTypes = event.ticket_types || []
  const sold = stats ? stats.total_tickets_sold : ticketTypes.reduce((sum, type) => sum + (type.quantity_sold || 0), 0)
  const inventory = ticketTypes.reduce((sum, type) => sum + (type.quantity_available || 0), 0)
  const capacity = inventory || event.max_capacity || 0
  const soldPercent = capacity > 0 ? Math.min(100, Math.round((sold / capacity) * 100)) : 0
  const checkIn = stats ? { admitted: stats.tickets_checked_in, total: stats.total_tickets_sold }
    : admissions ? { admitted: admissions.admitted, total: admissions.admitted + admissions.remaining } : null
  const reEntryEnabled = Boolean(event.re_entry_mode && event.re_entry_mode !== 'off')
  const isCooldownMode = event.re_entry_mode === 'cooldown'
  const liveHeadcount = reEntryEnabled ? (stats?.live_headcount ?? admissions?.live_headcount ?? null) : null
  const untrackedPreReEntry = reEntryEnabled ? Number(stats?.untracked_pre_re_entry_admits ?? admissions?.untracked_pre_re_entry_admits ?? 0) : 0
  const headcountByDay = reEntryEnabled ? (stats?.headcount_by_day || admissions?.headcount_by_day || []) : []
  const currentServiceDay = serviceDayString(Date.now(), event)
  const numberFormat = new Intl.NumberFormat('en-US')
  const reEntryLabel = event.re_entry_mode === 'exit_scan'
    ? 'Exit scan (in & out)'
    : event.re_entry_mode === 'cooldown'
      ? `Cool-down (${event.re_entry_cooldown_minutes || 15} min)`
      : null
  const checklist = organizerChecklist(event.publish_checklist || [])
  const openItems = checklist.filter(item => !item.complete)
  // Older servers send no sales_status; their published events are on sale.
  const salesStatus = event.sales_status
  const onSale = !salesStatus || salesStatus.on_sale === true
  const salesPaused = ['event_paused', 'sales_paused'].includes(salesStatus?.reason)
  const verificationState = event.organizer_verification_status && event.organizer_verification_status !== 'verified'
    ? event.organizer_verification_status : verificationReasons[salesStatus?.reason]
  const verificationProfile = verificationState && (profile.status === 'ready' ? profile.data
    : profile.status === 'error' ? { verification_status: verificationState } : null)
  const suspendedOrganizer = verificationProfile?.verification_status === 'suspended'
  const publiclyVisible = event.publicly_visible == null ? !verificationState : event.publicly_visible
  const publicPath = event.slug ? `/events/${event.slug}` : null
  const tools = eventToolLinks(event, capabilities)
  const setupSteps = ['draft', 'published'].includes(event.status) ? setupChecklist(event, has, publiclyVisible) : []
  const requiredSteps = setupSteps.filter(step => step.state !== 'optional')

  return <EventWorkspace eventId={id} event={event}>
    <div className="space-y-6">
      <section aria-labelledby="overview-status" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-status" className="text-lg font-semibold text-neutral-950">Overview</h2>
        {event.status === 'published' && verificationState && <span className="mt-2 inline-flex rounded-full bg-amber-100 px-3 py-1 text-xs font-semibold text-amber-950">{t(suspendedOrganizer ? 'organizerVerification.suspendedChip' : 'organizerVerification.waitingChip')}</span>}
        <p className="mt-1 text-sm text-neutral-700">{event.status === 'published' && verificationState ? t(suspendedOrganizer ? 'organizerVerification.suspendedBody' : 'organizerVerification.publishExplanation') : event.status === 'published' && !onSale ? 'Published — tickets are not on sale yet.' : statusCopy[event.status] || 'Event status unavailable.'}</p>
        <div className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
          <div className="flex items-start gap-2"><CalendarDays aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" /><div><span className="sr-only">Date: </span><span className="text-neutral-900">{event.starts_at ? formatEventDateTime(event.starts_at, event.timezone) : 'Date not set yet'}</span></div></div>
          <div className="flex items-start gap-2"><MapPin aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" /><div className="min-w-0"><span className="sr-only">Venue: </span><span className="break-words text-neutral-900">{event.venue_name || 'Venue not set yet'}{event.venue_city ? `, ${event.venue_city}` : ''}</span></div></div>
        </div>
      </section>

      {(canViewActivity || has('view_activity_events')) && <Link to={`/dashboard/settings/activity?event_id=${encodeURIComponent(event.id)}`} className="inline-flex min-h-11 items-center font-semibold text-brand-700 underline">View activity</Link>}

      <section aria-labelledby="overview-sales" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-sales" className="text-lg font-semibold text-neutral-950">Sales so far</h2>
        <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-3">
          <div className="rounded-xl bg-neutral-50 p-3">
            <p className="text-xs text-neutral-600">Tickets sold</p>
            <p className="mt-1 text-xl font-bold text-neutral-950">{sold}{capacity > 0 && <span className="text-sm font-medium text-neutral-600"> / {capacity}</span>}</p>
          </div>
          {stats && <div className="rounded-xl bg-neutral-50 p-3">
            <p className="text-xs text-neutral-600">Revenue</p>
            <p className="mt-1 text-xl font-bold text-neutral-950">{formatMoneyCents(stats.total_revenue_cents, currency)}</p>
          </div>}
          {extras.status === 'loading' && <>
            <div aria-hidden="true" className="h-[72px] animate-pulse rounded-xl bg-neutral-100 motion-reduce:animate-none" />
            {has('view_finance') && <div aria-hidden="true" className="h-[72px] animate-pulse rounded-xl bg-neutral-100 motion-reduce:animate-none" />}
          </>}
          {checkIn && <div className="rounded-xl bg-neutral-50 p-3">
            <p className="text-xs text-neutral-600">Checked in</p>
            <p className="mt-1 text-xl font-bold tabular-nums text-neutral-950">{numberFormat.format(checkIn.admitted)}<span className="text-sm font-medium text-neutral-600"> / {numberFormat.format(checkIn.total)}</span></p>
          </div>}
          {liveHeadcount != null && <div className="rounded-xl bg-neutral-50 p-3" data-testid="overview-live-headcount">
            <p className="text-xs text-neutral-600">{isCooldownMode ? 'Entered today' : 'Inside now'}</p>
            <p className="mt-1 text-xl font-bold tabular-nums text-neutral-950">{numberFormat.format(liveHeadcount)}</p>
            {reEntryLabel && <p className="mt-0.5 text-xs text-neutral-600">Re-entry: {reEntryLabel}</p>}
            {untrackedPreReEntry > 0 && <p className="mt-0.5 text-xs text-neutral-600">+{numberFormat.format(untrackedPreReEntry)} earlier check-ins</p>}
          </div>}
        </div>
        {headcountByDay.length > 1 && (
          <div className="mt-3 rounded-xl border border-neutral-200 bg-neutral-50 p-3" aria-label="Headcount by day">
            <p className="text-xs font-semibold text-neutral-700">{isCooldownMode ? 'Admissions by day' : 'Live headcount by day'}</p>
            <ul className="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
              {headcountByDay.map(day => {
                const isPastDay = Boolean(day.day && currentServiceDay && day.day < currentServiceDay)
                const label = isPastDay || isCooldownMode
                  ? `${numberFormat.format(day.entries ?? day.headcount ?? 0)} entered`
                  : `${numberFormat.format(day.headcount ?? 0)} inside`
                return (
                  <li key={`${day.event_id || 'e'}-${day.day}`} className="flex items-center justify-between gap-2 rounded-lg bg-white px-3 py-2 text-sm">
                    <span className="min-w-0 truncate font-medium text-neutral-900">{day.event_title || day.label || day.day}</span>
                    <span className="shrink-0 font-bold tabular-nums text-neutral-950">{label}</span>
                  </li>
                )
              })}
            </ul>
          </div>
        )}
        {extras.status === 'loading' && <p role="status" className="sr-only">Loading sales figures…</p>}
        {extras.status === 'error' && <div role="alert" className="mt-3 flex flex-wrap items-center gap-x-3 text-sm text-neutral-700">
          <p>Sales figures unavailable.</p>
          <button type="button" onClick={() => loadExtras(event)} className="min-h-11 font-semibold text-brand-700 underline">Retry</button>
        </div>}
        {capacity > 0 && <div className="mt-4 h-2 overflow-hidden rounded-full bg-neutral-100" role="progressbar" aria-label="Tickets sold of capacity" aria-valuemin={0} aria-valuemax={100} aria-valuenow={soldPercent}>
          <div className="h-full rounded-full bg-brand-600" style={{ width: `${soldPercent}%` }} />
        </div>}
      </section>

      <section aria-labelledby="overview-next" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-next" className="text-lg font-semibold text-neutral-950">Next steps</h2>
        {event.status === 'draft' && <>
          <p className="mt-1 text-sm text-neutral-700">{openItems.length ? `${checklist.length - openItems.length} of ${checklist.length} publish checks done.` : 'All publish checks are done.'}</p>
          {openItems.length > 0 && <ul className="mt-3 space-y-2 text-sm text-neutral-800">
            {openItems.slice(0, 5).map(item => <li key={item.code} className="flex items-start gap-2"><Circle aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-400" />{item.label}</li>)}
            {openItems.length > 5 && <li className="pl-6 text-neutral-600">and {openItems.length - 5} more</li>}
          </ul>}
          {has('edit_event_content')
            ? <Link to={`/dashboard/events/${event.id}/edit`} className="btn-primary mt-4 inline-flex min-h-11 text-sm">{openItems.length ? 'Finish setup' : 'Review and publish'}</Link>
            : <p className="mt-3 text-sm text-neutral-600">Ask an event manager to finish setup and publish.</p>}
        </>}
        {event.status === 'published' && <>
          {onSale
            ? <p className="mt-1 flex items-center gap-2 text-sm text-neutral-700"><CheckCircle2 aria-hidden="true" className="h-4 w-4 text-emerald-600" />Your event is live. Share it and get ready for the door.</p>
            : <div className="mt-2 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
              <p className="flex items-start gap-2 font-semibold"><CircleAlert aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" />{verificationState ? t(suspendedOrganizer ? 'organizerVerification.suspendedChip' : 'organizerVerification.waitingChip') : salesPaused ? 'Sales paused by HåfaPass.' : 'Tickets are not on sale yet.'}</p>
              {(() => {
                const detail = salesStatus.reason === 'event_paused' && event.policy_hold?.reason ? event.policy_hold.reason : salesDetail(salesStatus.message)
                return detail && <p className="mt-1 whitespace-pre-wrap pl-6 [overflow-wrap:anywhere]">{detail}</p>
              })()}
              {verificationProfile && <VerificationNotice profile={verificationProfile} beginRequest={beginRequest} showSummary={false} inline className="mt-2 pl-6" />}
            </div>}
          <div className="mt-4 flex flex-wrap gap-2">
            {publicPath && publiclyVisible && <Link to={publicPath} className="btn-secondary inline-flex min-h-11 gap-2 text-sm"><ExternalLink aria-hidden="true" className="h-4 w-4" />View public page</Link>}
            {publicPath && publiclyVisible && <button type="button" onClick={() => copyLink(`${PUBLIC_WEB_URL}${publicPath}`)} className="btn-secondary inline-flex min-h-11 gap-2 text-sm"><Copy aria-hidden="true" className="h-4 w-4" />{copyState === 'copied' ? 'Link copied' : 'Copy event link'}</button>}
            {previewUrl && !publiclyVisible && !suspendedOrganizer && <><a href={previewUrl} className="btn-secondary inline-flex min-h-11 gap-2 text-sm"><ExternalLink aria-hidden="true" className="h-4 w-4" />Preview event</a>
              <button type="button" onClick={sharePreview} className="btn-secondary min-h-11 text-sm">{t('organizerVerification.sharePreview')}</button>
              <button type="button" onClick={() => copyLink(previewUrl)} className="btn-secondary min-h-11 text-sm">{copyState === 'copied' ? t('organizerVerification.copied') : t('organizerVerification.copyPreview')}</button>
              <button type="button" onClick={() => setConfirmNewPreview(true)} className="btn-secondary min-h-11 text-sm">Get a new preview link</button></>}
            {has('scan') && <Link to={`/dashboard/scanner?event=${event.id}`} className="btn-secondary inline-flex min-h-11 text-sm">Open Door Scanner</Link>}
          </div>
          {previewUrl && !publiclyVisible && <p className="mt-2 text-sm text-neutral-700">Anyone using the old link will lose access.</p>}
          {!publiclyVisible && !previewUrl && <p className="mt-2 text-sm text-neutral-700">This event has no public link right now.</p>}
          {confirmNewPreview && <div role="group" aria-label="Confirm new preview link" className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950"><p>Anyone using the old link will lose access. Get a new preview link?</p><div className="mt-2 flex gap-2"><button type="button" className="btn-secondary min-h-11" onClick={() => { setConfirmNewPreview(false); setPreviewError('') }}>Cancel</button><button type="button" className="btn-primary min-h-11" onClick={async () => { if (await rotatePreview()) setConfirmNewPreview(false) }}>Get new link</button></div>{previewError && <p role="alert" className="mt-2 text-red-800">{previewError}</p>}</div>}
          <p className={copyState === 'failed' ? 'mt-3 text-sm text-neutral-700' : 'sr-only'} aria-live="polite">
            {copyState === 'copied' ? t('organizerVerification.copied') : copyState === 'failed' ? "Couldn't copy. Select the link below." : ''}
          </p>
          {copyState === 'failed' && publicPath && <label className="mt-2 block text-sm text-neutral-700">
            <span className="sr-only">Event link</span>
            <input type="text" readOnly value={previewUrl || `${PUBLIC_WEB_URL}${publicPath}`} onFocus={focusEvent => focusEvent.target.select()} className="input w-full min-w-0 text-sm" />
          </label>}
        </>}
        {event.status === 'postponed' && <p className="mt-1 text-sm text-neutral-700">{has('edit_event_content') ? <>Set a new date in <Link to={`/dashboard/events/${event.id}/edit`} className="font-semibold text-brand-700 underline">event details</Link> when you have one.</> : 'Your event manager will set a new date.'}</p>}
        {['cancelled', 'completed', 'archived'].includes(event.status) && <p className="mt-1 text-sm text-neutral-700">This event is closed. {has('view_finance') ? <>Review the final numbers in <Link to={`/dashboard/events/${event.id}/analytics`} className="font-semibold text-brand-700 underline">reports &amp; sales</Link>.</> : 'Nothing else needs doing here.'}</p>}
      </section>

      {setupSteps.length > 0 && <section aria-labelledby="overview-setup" className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6">
        <h2 id="overview-setup" className="text-lg font-semibold text-neutral-950">Event setup checklist</h2>
        <p className="mt-1 text-base text-neutral-700">{requiredSteps.filter(step => step.state === 'done').length} of {requiredSteps.length} steps done.</p>
        <ol className="mt-4 divide-y divide-neutral-100">
          {setupSteps.map(step => <li key={step.key} className="flex flex-col gap-3 py-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex min-w-0 items-start gap-3">
              {step.state === 'done'
                ? <CheckCircle2 aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700" />
                : <Circle aria-hidden="true" className={`mt-0.5 h-5 w-5 shrink-0 ${step.state === 'optional' ? 'text-neutral-400' : 'text-amber-700'}`} />}
              <div className="min-w-0">
                <p className="text-base font-semibold text-neutral-950">{step.label}<span className="sr-only">{step.state === 'done' ? ' (done)' : step.state === 'optional' ? ' (optional)' : ' (to do)'}</span></p>
                <p className="text-base text-neutral-700">{step.detail}</p>
              </div>
            </div>
            {step.link && <Link to={step.link.to} className="btn-secondary inline-flex min-h-12 shrink-0 text-sm">{step.link.label}</Link>}
          </li>)}
        </ol>
      </section>}

      {tools.length > 0 && <section aria-labelledby="overview-tools">
        <h2 id="overview-tools" className="text-lg font-semibold text-neutral-950">Event tools</h2>
        <ul className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {tools.map(tool => <li key={tool.to}><Link to={tool.to} className="flex min-h-11 items-center rounded-xl border border-neutral-200 bg-white px-4 py-3 text-sm font-medium text-neutral-900 transition-colors hover:border-brand-300 hover:bg-brand-50">{tool.label}</Link></li>)}
        </ul>
      </section>}
    </div>
  </EventWorkspace>
}

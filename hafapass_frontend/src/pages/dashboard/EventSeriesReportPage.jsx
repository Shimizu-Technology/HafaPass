import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import {
  AlertTriangle,
  CheckCircle2,
  Circle,
  Clock,
  Download,
  Loader2,
  Pencil,
  ShieldCheck,
  WalletCards,
} from 'lucide-react'
import apiClient from '../../api/client'
import NoAccessNotice from '../../components/NoAccessNotice'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { saveBlob } from '../../utils/download'
import { formatEventDate } from '../../utils/eventTime'
import { formatMoneyCents } from '../../utils/money'
import { loadOrganizerOrganizations, selectedOrganization } from '../../utils/organizerOrganizations'

const ROLE_LABELS = {
  regular_night: 'Regular Night',
  championship_night: 'Championship Night',
  pass_sale: 'Pass Sale',
  registration: 'Team Registration',
  other: 'Other',
}

const ROLE_STYLES = {
  regular_night: 'bg-brand-50 text-brand-800',
  championship_night: 'bg-amber-50 text-amber-900',
  pass_sale: 'bg-emerald-50 text-emerald-800',
  registration: 'bg-neutral-100 text-neutral-800',
  other: 'bg-neutral-100 text-neutral-700',
}

const STATUS_STYLES = {
  draft: 'bg-amber-100 text-amber-900',
  active: 'bg-emerald-100 text-emerald-900',
  completed: 'bg-neutral-100 text-neutral-800',
  archived: 'bg-neutral-200 text-neutral-700',
}

const BASE_OPTIONS = [
  {
    value: 'admissions_net_proceeds',
    label: 'Admissions net proceeds',
    description: 'Organizer proceeds across regular nights, championship nights, and pass sales (already net of discounts, organizer-absorbed fees, and refunded proceeds).',
  },
  {
    value: 'admissions_gross',
    label: 'Admissions gross (after discounts & refunds)',
    description: 'Gross ticket sales minus discounts and refunds across admissions events.',
  },
  {
    value: 'admissions_net_after_processing',
    label: 'Admissions net after processing fees',
    description: 'Admissions organizer proceeds minus organizer-paid card processing fees.',
  },
  {
    value: 'all_net_proceeds',
    label: 'All series net proceeds',
    description: 'Organizer proceeds across every event in this series, including team registration and other roles.',
  },
]

const TONES = {
  neutral: 'bg-neutral-100 text-neutral-700',
  good: 'bg-emerald-50 text-emerald-800',
  warning: 'bg-amber-50 text-amber-900',
  action: 'bg-brand-50 text-brand-800',
  critical: 'bg-red-50 text-red-800',
}

function Badge({ tone = 'neutral', icon: Icon = Circle, children }) {
  return (
    <span className={`inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ${TONES[tone]}`}>
      <Icon aria-hidden="true" className="h-3.5 w-3.5 shrink-0" />
      {children}
    </span>
  )
}

function SeriesStatusBadge({ status }) {
  const label = status ? status.charAt(0).toUpperCase() + status.slice(1) : 'Draft'
  return (
    <span className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${STATUS_STYLES[status] || 'bg-neutral-100 text-neutral-800'}`}>
      {label}
    </span>
  )
}

function RoleBadge({ role }) {
  return (
    <span className={`inline-flex items-center whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ${ROLE_STYLES[role] || 'bg-neutral-100 text-neutral-700'}`}>
      {ROLE_LABELS[role] || role}
    </span>
  )
}

function StatementBadge({ row }) {
  const version = row.settlement?.version
  if (row.settlement_state === 'finalized') return <Badge tone="good" icon={CheckCircle2}>Finalized v{version}</Badge>
  if (row.settlement_state === 'changed') return <Badge tone="warning" icon={AlertTriangle}>Changed since v{version}</Badge>
  if (row.awaiting_completion) return <Badge tone="warning" icon={Clock}>Mark completed to finalize</Badge>
  return <Badge>Not finalized</Badge>
}

function PayoutStateBadge({ state }) {
  switch (state) {
    case 'ready': return <Badge tone="action" icon={WalletCards}>Ready to request</Badge>
    case 'in_progress': return <Badge tone="warning" icon={Clock}>Payout in progress</Badge>
    case 'on_hold': return <Badge tone="warning" icon={Clock}>On hold</Badge>
    case 'paid': return <Badge tone="good" icon={CheckCircle2}>Paid</Badge>
    case 'needs_new_version': return <Badge tone="warning" icon={AlertTriangle}>Finalize new version</Badge>
    case 'awaiting_statement': return <Badge icon={Clock}>Waiting for statement</Badge>
    default: return <Badge>Nothing owed</Badge>
  }
}

function formatBpsPercent(bps) {
  const safe = Number.isFinite(bps) ? bps : 0
  return `${(safe / 100).toFixed(2)}%`
}

function baseOptionMeta(value) {
  return BASE_OPTIONS.find((opt) => opt.value === value) || BASE_OPTIONS[0]
}

function extractSplitSettingsFromReport(report) {
  const share = report?.revenue_share
  if (!share) return null
  return {
    revenue_share_bps: share.revenue_share_bps ?? 1600,
    revenue_share_base: share.revenue_share_base || 'admissions_net_proceeds',
    revenue_share_includes_door_cash: Boolean(share.revenue_share_includes_door_cash),
    revenue_share_label: report?.series?.revenue_share_label ?? share.revenue_share_label ?? '',
    primary_share_label: report?.series?.primary_share_label ?? share.primary_share_label ?? '',
  }
}

function extractSplitSettingsFromPatch(patchData, submittedPayload, fallbackSettings) {
  const source = patchData && typeof patchData === 'object' ? patchData : {}
  return {
    revenue_share_bps: source.revenue_share_bps ?? submittedPayload.revenue_share_bps ?? fallbackSettings?.revenue_share_bps ?? 1600,
    revenue_share_base: source.revenue_share_base ?? submittedPayload.revenue_share_base ?? fallbackSettings?.revenue_share_base ?? 'admissions_net_proceeds',
    revenue_share_includes_door_cash:
      typeof source.revenue_share_includes_door_cash === 'boolean'
        ? source.revenue_share_includes_door_cash
        : Boolean(submittedPayload.revenue_share_includes_door_cash ?? fallbackSettings?.revenue_share_includes_door_cash),
    revenue_share_label:
      source.revenue_share_label ?? submittedPayload.revenue_share_label ?? fallbackSettings?.revenue_share_label ?? '',
    primary_share_label:
      source.primary_share_label ?? submittedPayload.primary_share_label ?? fallbackSettings?.primary_share_label ?? '',
  }
}

export default function EventSeriesReportPage() {
  const { seriesId } = useParams()
  const identity = useOrganizerIdentity()
  const path = `/dashboard/series/${seriesId}/report`
  const visit = useOrganizerPageVisit(path)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return (
    <EventSeriesReportSession
      key={`${identity.accountKey}:${identity.organizationId}:${seriesId}:${visit.generation}`}
      seriesId={seriesId}
      identity={identity}
      path={path}
    />
  )
}

function EventSeriesReportSession({ seriesId, identity, path }) {
  const { current, beginRequest } = useOrganizerRequests(identity, path)
  const [state, setState] = useState({ status: 'loading', data: null, error: null })
  const [canEditSplit, setCanEditSplit] = useState(false)
  const [exporting, setExporting] = useState(false)
  const [exportError, setExportError] = useState(null)

  const [editingSplit, setEditingSplit] = useState(false)
  const [savedSplitSettings, setSavedSplitSettings] = useState(null)
  const [splitPercent, setSplitPercent] = useState('16.00')
  const [splitBase, setSplitBase] = useState('admissions_net_proceeds')
  const [includeDoorCash, setIncludeDoorCash] = useState(false)
  const [shareLabel, setShareLabel] = useState('')
  const [primaryLabel, setPrimaryLabel] = useState('')
  const [savingSplit, setSavingSplit] = useState(false)
  const [splitError, setSplitError] = useState(null)
  const [splitNotice, setSplitNotice] = useState(null)
  const [refreshError, setRefreshError] = useState(null)

  const loadRequest = useRef(null)

  const syncSplitForm = useCallback((settings) => {
    if (!settings) return
    setSplitPercent(((settings.revenue_share_bps ?? 1600) / 100).toFixed(2))
    setSplitBase(settings.revenue_share_base || 'admissions_net_proceeds')
    setIncludeDoorCash(Boolean(settings.revenue_share_includes_door_cash))
    setShareLabel(settings.revenue_share_label || '')
    setPrimaryLabel(settings.primary_share_label || '')
  }, [])

  const load = useCallback(async ({ preserveData = false } = {}) => {
    const request = beginRequest()
    if (!request) return
    loadRequest.current?.controller.abort()
    loadRequest.current = request
    const applies = () => request.current() && loadRequest.current === request
    setRefreshError(null)
    setState((previous) => ({ status: previous.data ? 'refreshing' : 'loading', data: previous.data, error: null }))
    try {
      const [reportRes, orgsRes] = await Promise.all([
        apiClient.get(`/organizer/event_series/${seriesId}/report`, request.config),
        loadOrganizerOrganizations(identity.authContext).catch(() => ({ data: [] })),
      ])
      if (!applies()) return
      const orgs = Array.isArray(orgsRes.data) ? orgsRes.data : []
      const currentOrg = selectedOrganization(orgs, identity.organizationId)
      const perms = currentOrg?.permissions || {}
      setCanEditSplit(Boolean(perms.manage_finance))
      setSavedSplitSettings(null)
      syncSplitForm(extractSplitSettingsFromReport(reportRes.data))
      setState({ status: 'ready', data: reportRes.data, error: null })
    } catch (error) {
      if (!applies() || error?.name === 'AbortError' || error?.name === 'CanceledError') return
      const status = error.response?.status
      if (preserveData) {
        setState((previous) => (
          previous.data
            ? { status: 'ready', data: previous.data, error: null }
            : {
                status: 'error',
                data: null,
                error: status === 403 ? 'denied' : status === 404 ? 'not-found' : status === 401 ? 'signed-out' : 'failed',
              }
        ))
        setRefreshError('Split settings were saved, but the report could not be refreshed. Please try again.')
        return
      }
      setState({
        status: 'error',
        data: null,
        error: status === 403 ? 'denied' : status === 404 ? 'not-found' : status === 401 ? 'signed-out' : 'failed',
      })
    } finally {
      request.release()
    }
  }, [beginRequest, identity.authContext, identity.organizationId, seriesId, syncSplitForm])

  useEffect(() => {
    load()
  }, [load])

  const handleExportCsv = async () => {
    if (exporting) return
    const request = beginRequest()
    if (!request) return
    setExporting(true)
    setExportError(null)
    try {
      const response = await apiClient.get(`/organizer/event_series/${seriesId}/report_export`, {
        ...request.config,
        responseType: 'blob',
      })
      if (request.current()) {
        const slug = state.data?.series?.slug || `series-${seriesId}`
        saveBlob(response.data, `${slug}-series-report.csv`)
      }
    } catch (error) {
      if (request.current() && error?.name !== 'AbortError' && error?.name !== 'CanceledError') {
        setExportError(
          error.response?.status === 403
            ? 'Your role does not include finance exports.'
            : 'Could not download the series report CSV. Please try again.'
        )
      }
    } finally {
      request.release()
      if (current()) setExporting(false)
    }
  }

  const handleSaveSplit = async (e) => {
    e.preventDefault()
    const parsed = Number(splitPercent)
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > 100) {
      setSplitError('Revenue share percentage must be between 0 and 100.')
      return
    }
    const bps = Math.round(parsed * 100)
    const request = beginRequest()
    if (!request) return
    setSavingSplit(true)
    setSplitError(null)
    setSplitNotice(null)
    const payload = {
      revenue_share_bps: bps,
      revenue_share_base: splitBase,
      revenue_share_includes_door_cash: includeDoorCash,
      revenue_share_label: shareLabel.trim(),
      primary_share_label: primaryLabel.trim(),
    }
    try {
      const patchRes = await apiClient.patch(
        `/organizer/event_series/${seriesId}`,
        payload,
        request.config
      )
      if (!request.current()) return
      const persistedSplitSettings = extractSplitSettingsFromPatch(
        patchRes?.data,
        payload,
        savedSplitSettings || extractSplitSettingsFromReport(state.data)
      )
      setSavedSplitSettings(persistedSplitSettings)
      syncSplitForm(persistedSplitSettings)
      setEditingSplit(false)
      setSplitNotice('Revenue-share settings updated.')
      await load({ preserveData: true })
    } catch (error) {
      if (!request.current()) return
      const msg = error.response?.data?.errors?.[0] || error.response?.data?.error || 'Could not update split settings.'
      setSplitError(msg)
    } finally {
      request.release()
      if (current()) setSavingSplit(false)
    }
  }

  const backLink = <BackLink to="/dashboard/series">Back to event series</BackLink>

  if (state.status === 'loading') {
    return (
      <WorkspacePage>
        <PageHeader back={backLink} title="Series financial report" description="Loading series sales, attendance, and revenue-share worksheet…" />
        <div aria-busy="true">
          <p role="status" className="sr-only">Loading series report…</p>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5">
            {Array.from({ length: 5 }, (_, idx) => (
              <div key={idx} className="h-24 animate-pulse rounded-2xl bg-neutral-100 motion-reduce:animate-none" />
            ))}
          </div>
          <div className="mt-6 h-64 animate-pulse rounded-2xl bg-neutral-100 motion-reduce:animate-none" />
        </div>
      </WorkspacePage>
    )
  }

  if (state.status === 'error' && state.error === 'denied') {
    return (
      <WorkspacePage>
        <PageHeader back={backLink} title="Series financial report" />
        <NoAccessNotice
          title="Series financial reports aren’t part of your role"
          detail="Viewing series financial reports requires organization-level finance access. Owners, managers, and finance members can open this page."
        />
      </WorkspacePage>
    )
  }

  if (state.status === 'error') {
    const message = state.error === 'not-found'
      ? 'This event series could not be found in the selected organization.'
      : state.error === 'signed-out'
        ? 'Please sign in again to view this series report.'
        : 'The series report could not be loaded. Check your connection and try again.'
    return (
      <WorkspacePage>
        <PageHeader back={backLink} title="Series financial report" />
        <div role="alert" className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm text-neutral-700">
          <p>{message}</p>
          {state.error === 'failed' && (
            <button type="button" onClick={load} className="btn-secondary mt-4 !px-4 !py-2.5 text-sm">
              Try again
            </button>
          )}
        </div>
      </WorkspacePage>
    )
  }

  const data = state.data
  const series = data.series || {}
  const currency = (data.currency || 'usd').toUpperCase()
  const money = (cents) => formatMoneyCents(cents, currency)
  const groups = data.groups || {}
  const admissions = groups.admissions || {}
  const registration = groups.registration || {}
  const otherGroup = groups.other || {}
  const combined = groups.combined || {}
  const channels = data.channels || {}
  const share = data.revenue_share || {}
  const checklist = data.closeout_checklist || {}
  const events = data.events || []
  const ticketTypes = data.ticket_types || []
  const baseMeta = baseOptionMeta(share.revenue_share_base)

  const groupRows = [
    { key: 'admissions', label: 'Admissions', subtitle: 'Regular nights, championship nights & passes', row: admissions },
    { key: 'registration', label: 'Team Registration', subtitle: 'Registration events', row: registration },
    ...(otherGroup.events_count > 0 ? [{ key: 'other', label: 'Other', subtitle: 'Other series events', row: otherGroup }] : []),
    { key: 'combined', label: 'Combined Series Total', subtitle: 'All events in this series', row: combined, total: true },
  ]

  const channelRows = ['online_stripe', 'door_card', 'door_cash', 'free_comp'].map((key) => channels[key]).filter(Boolean)

  return (
    <WorkspacePage>
      <PageHeader
        back={backLink}
        title={series.name || 'Series report'}
        titleAccessory={<SeriesStatusBadge status={series.status} />}
        description={series.description || 'Read-only tournament-wide sales, check-ins, and revenue-share worksheet reconciled to per-event settlements.'}
        actions={(
          <button
            type="button"
            disabled={exporting}
            onClick={handleExportCsv}
            className="btn-secondary inline-flex min-h-11 items-center gap-2 whitespace-nowrap px-4 text-sm"
          >
            {exporting ? <Loader2 aria-hidden="true" className="h-4 w-4 animate-spin" /> : <Download aria-hidden="true" className="h-4 w-4" />}
            Export CSV
          </button>
        )}
      />

      {exportError && (
        <div role="alert" className="-mt-4 mb-6 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          {exportError}
        </div>
      )}

      {refreshError && (
        <div role="alert" className="-mt-4 mb-6 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
          <span>{refreshError}</span>
          <button
            type="button"
            onClick={() => load({ preserveData: true })}
            className="btn-secondary min-h-9 px-3 text-xs"
          >
            Retry refresh
          </button>
        </div>
      )}

      {splitNotice && (
        <div role="status" className="-mt-4 mb-6 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900">
          {splitNotice}
        </div>
      )}

      <div className={`space-y-6 transition-opacity duration-150 ${state.status === 'refreshing' ? 'opacity-60' : ''}`} aria-busy={state.status === 'refreshing'}>
        {/* Top KPI Cards */}
        <section aria-label="Series financial highlights" className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-5">
          <div className="rounded-2xl border border-neutral-200 bg-white p-4">
            <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Admissions gross</p>
            <p className="mt-1.5 text-2xl font-bold tabular-nums text-neutral-950">{money(admissions.gross_cents)}</p>
            <p className="mt-1 text-xs text-neutral-600 tabular-nums">
              {admissions.tickets_issued_count || 0} tickets · {admissions.checked_in_count || 0} checked in
            </p>
          </div>
          <div className="rounded-2xl border border-neutral-200 bg-white p-4">
            <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Organizer proceeds</p>
            <p className="mt-1.5 text-2xl font-bold tabular-nums text-neutral-950">{money(combined.organizer_proceeds_cents)}</p>
            <p className="mt-1 text-xs text-neutral-600 tabular-nums">
              Admissions: {money(admissions.organizer_proceeds_cents)}
            </p>
          </div>
          <div className="rounded-2xl border border-neutral-200 bg-white p-4">
            <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Door cash retained</p>
            <p className="mt-1.5 text-2xl font-bold tabular-nums text-neutral-950">{money(combined.door_cash_retained_cents)}</p>
            <p className="mt-1 text-xs text-neutral-600">Kept by organizer at door</p>
          </div>
          <div className="rounded-2xl border border-neutral-200 bg-white p-4">
            <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Net platform payable</p>
            <p className="mt-1.5 text-2xl font-bold tabular-nums text-neutral-950">{money(combined.payable_cents)}</p>
            <p className="mt-1 text-xs text-neutral-600 tabular-nums">
              Reserves held: {money(combined.reserve_cents)}
            </p>
          </div>
          <div className={`rounded-2xl border bg-white p-4 ${(combined.negative_balance_cents > 0 || combined.unresolved_buyer_liability_cents > 0) ? 'border-red-300 bg-red-50/40' : 'border-neutral-200'}`}>
            <p className="text-xs font-medium uppercase tracking-wide text-neutral-500">Paid / remaining owed</p>
            <p className="mt-1.5 text-2xl font-bold tabular-nums text-neutral-950">{money(combined.owed_cents)}</p>
            <p className="mt-1 text-xs text-neutral-600 tabular-nums">
              Paid out: {money(combined.paid_cents)}
            </p>
            {combined.negative_balance_cents > 0 && (
              <p className="mt-1 text-xs font-semibold tabular-nums text-red-700">
                Overpaid: −{money(combined.negative_balance_cents)}
              </p>
            )}
            {combined.unresolved_buyer_liability_cents > 0 && (
              <p className="mt-0.5 text-xs font-semibold tabular-nums text-red-700">
                Buyer liability: {money(combined.unresolved_buyer_liability_cents)}
              </p>
            )}
          </div>
        </section>

        {(combined.negative_balance_cents > 0 || combined.unresolved_buyer_liability_cents > 0) && (
          <div
            role="alert"
            className="flex items-start gap-3 rounded-2xl border border-red-200 bg-red-50 px-5 py-4 text-sm text-red-900"
          >
            <AlertTriangle aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-red-700" />
            <div className="space-y-1">
              <p className="font-semibold text-red-950">Overpayment or unresolved buyer refund liability requires reconciliation</p>
              {combined.negative_balance_cents > 0 && (
                <p>
                  One or more events have a negative balance totaling{' '}
                  <strong className="tabular-nums">−{money(combined.negative_balance_cents)}</strong>{' '}
                  (overpaid after refunds or adjustments). This balance must be recouped or carried forward.
                </p>
              )}
              {combined.unresolved_buyer_liability_cents > 0 && (
                <p>
                  Unresolved post-payout buyer refund liability totals{' '}
                  <strong className="tabular-nums">{money(combined.unresolved_buyer_liability_cents)}</strong>.
                </p>
              )}
            </div>
          </div>
        )}

        {/* Revenue-Share Worksheet & Closeout Checklist */}
        <div className="grid min-w-0 grid-cols-1 gap-6 lg:grid-cols-12">
          <section aria-labelledby="revenue-share-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6 lg:col-span-7">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="min-w-0">
                <h2 id="revenue-share-heading" className="text-lg font-semibold text-neutral-950">
                  Revenue-Share Worksheet
                </h2>
                <p className="mt-1 text-sm text-neutral-600">
                  Read-only split calculation. HåfaPass still settles and pays out to one primary payee per event.
                </p>
              </div>
              {canEditSplit && (
                <button
                  type="button"
                  aria-expanded={editingSplit}
                  onClick={() => {
                    setSplitError(null)
                    if (!editingSplit) {
                      syncSplitForm(savedSplitSettings || extractSplitSettingsFromReport(data))
                    }
                    setEditingSplit((prev) => !prev)
                  }}
                  className="btn-secondary inline-flex min-h-10 shrink-0 items-center gap-1.5 px-3 text-sm"
                >
                  <Pencil aria-hidden="true" className="h-4 w-4" />
                  {editingSplit ? 'Cancel edit' : 'Edit Split Settings'}
                </button>
              )}
            </div>

            <div className="mt-4 flex flex-wrap items-center gap-2">
              <span className="inline-flex items-center rounded-full bg-brand-50 px-2.5 py-1 text-xs font-medium text-brand-800">
                Base: {baseMeta.label}
              </span>
              <span className={`inline-flex items-center rounded-full px-2.5 py-1 text-xs font-medium ${share.revenue_share_includes_door_cash ? 'bg-emerald-50 text-emerald-800' : 'bg-amber-50 text-amber-900'}`}>
                {share.revenue_share_includes_door_cash ? 'Includes door cash' : 'Excludes door cash'}
              </span>
            </div>
            <p className="mt-2 text-xs text-neutral-600">{baseMeta.description}</p>

            {editingSplit && (
              <form onSubmit={handleSaveSplit} className="mt-4 space-y-4 rounded-xl border border-brand-200 bg-brand-50/30 p-4">
                <h3 className="text-sm font-semibold text-neutral-900">Edit split settings</h3>
                {splitError && (
                  <div role="alert" className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-800">
                    {splitError}
                  </div>
                )}
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <div>
                    <label htmlFor="split-percent" className="mb-1 block text-xs font-medium text-neutral-800">
                      Revenue share (%)
                    </label>
                    <input
                      id="split-percent"
                      type="number"
                      min="0"
                      max="100"
                      step="0.01"
                      value={splitPercent}
                      onChange={(e) => setSplitPercent(e.target.value)}
                      className="input text-sm"
                      disabled={savingSplit}
                      required
                    />
                  </div>
                  <div>
                    <label htmlFor="split-base" className="mb-1 block text-xs font-medium text-neutral-800">
                      Calculation base
                    </label>
                    <select
                      id="split-base"
                      value={splitBase}
                      onChange={(e) => setSplitBase(e.target.value)}
                      className="input text-sm"
                      disabled={savingSplit}
                    >
                      {BASE_OPTIONS.map((opt) => (
                        <option key={opt.value} value={opt.value}>{opt.label}</option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <label htmlFor="split-share-label" className="mb-1 block text-xs font-medium text-neutral-800">
                      Revenue-share label
                    </label>
                    <input
                      id="split-share-label"
                      type="text"
                      value={shareLabel}
                      onChange={(e) => setShareLabel(e.target.value)}
                      placeholder="e.g. School Share"
                      className="input text-sm"
                      disabled={savingSplit}
                    />
                  </div>
                  <div>
                    <label htmlFor="split-primary-label" className="mb-1 block text-xs font-medium text-neutral-800">
                      Primary-share label
                    </label>
                    <input
                      id="split-primary-label"
                      type="text"
                      value={primaryLabel}
                      onChange={(e) => setPrimaryLabel(e.target.value)}
                      placeholder="e.g. Alumni Share"
                      className="input text-sm"
                      disabled={savingSplit}
                    />
                  </div>
                </div>
                <label className="flex items-center gap-2 text-sm text-neutral-800">
                  <input
                    type="checkbox"
                    checked={includeDoorCash}
                    onChange={(e) => setIncludeDoorCash(e.target.checked)}
                    disabled={savingSplit}
                    className="h-4 w-4 rounded border-neutral-300 text-brand-600 focus:ring-brand-500"
                  />
                  Include door cash sales in revenue-share base
                </label>
                <div className="flex flex-wrap justify-end gap-2">
                  <button
                    type="button"
                    onClick={() => setEditingSplit(false)}
                    disabled={savingSplit}
                    className="btn-secondary min-h-10 px-3.5 text-sm"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    disabled={savingSplit}
                    className="btn-primary min-h-10 px-4 text-sm"
                  >
                    {savingSplit ? 'Saving…' : 'Save Split Settings'}
                  </button>
                </div>
              </form>
            )}

            <dl className="mt-5 divide-y divide-neutral-100 rounded-xl border border-neutral-200 bg-neutral-50/50 text-sm" data-testid="revenue-share-worksheet">
              <div className="flex items-baseline justify-between gap-4 px-4 py-3">
                <dt className="text-neutral-700">Shareable base</dt>
                <dd className="font-semibold tabular-nums text-neutral-950">{money(share.base_cents)}</dd>
              </div>
              <div className="flex items-baseline justify-between gap-4 bg-white px-4 py-3">
                <dt className="min-w-0 font-medium text-neutral-900">
                  {share.revenue_share_label || 'Revenue Share'}
                  <span className="ml-2 text-xs font-normal text-neutral-600">
                    ({formatBpsPercent(share.revenue_share_bps)})
                  </span>
                </dt>
                <dd className="shrink-0 font-bold tabular-nums text-brand-800">{money(share.share_cents)}</dd>
              </div>
              <div className="flex items-baseline justify-between gap-4 bg-white px-4 py-3">
                <dt className="min-w-0 font-medium text-neutral-900">
                  {share.primary_share_label || 'Primary Organizer'}
                  <span className="ml-2 text-xs font-normal text-neutral-600">
                    ({formatBpsPercent(share.primary_share_bps)})
                  </span>
                </dt>
                <dd className="shrink-0 font-bold tabular-nums text-neutral-950">{money(share.primary_cents)}</dd>
              </div>
              <div className="flex items-baseline justify-between gap-4 px-4 py-3 font-semibold text-neutral-950">
                <dt>Total split (100.00% of base)</dt>
                <dd className="tabular-nums">{money((share.share_cents || 0) + (share.primary_cents || 0))}</dd>
              </div>
            </dl>

            <div className="mt-4 grid grid-cols-2 gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-3.5 text-xs sm:grid-cols-4">
              <div>
                <p className="text-neutral-500">Door cash retained</p>
                <p className="mt-0.5 font-semibold tabular-nums text-neutral-900">{money(share.door_cash_retained_cents)}</p>
              </div>
              <div>
                <p className="text-neutral-500">Platform payable</p>
                <p className="mt-0.5 font-semibold tabular-nums text-neutral-900">{money(share.net_platform_payable_cents)}</p>
              </div>
              <div>
                <p className="text-neutral-500">Paid / owed</p>
                <p className="mt-0.5 font-semibold tabular-nums text-neutral-900">
                  {money(share.paid_cents)} / {money(share.owed_cents)}
                </p>
              </div>
              <div>
                <p className="text-neutral-500">Reserves held</p>
                <p className="mt-0.5 font-semibold tabular-nums text-neutral-900">{money(share.reserve_cents)}</p>
              </div>
            </div>
          </section>

          {/* Closeout & Payout Checklist */}
          <section aria-labelledby="closeout-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6 lg:col-span-5">
            <div className="flex items-center gap-2">
              <ShieldCheck aria-hidden="true" className="h-5 w-5 text-brand-700" />
              <h2 id="closeout-heading" className="text-lg font-semibold text-neutral-950">
                Closeout & Payout Checklist
              </h2>
            </div>
            <p className="mt-1 text-sm text-neutral-600">
              Track per-event settlement finalization, check references, and post-event reserve holdbacks.
            </p>

            <dl className="mt-4 grid grid-cols-2 gap-2.5 text-sm">
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Total events</dt>
                <dd className="mt-0.5 text-lg font-bold tabular-nums text-neutral-950">{checklist.events_total ?? 0}</dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Awaiting completion</dt>
                <dd className="mt-0.5 text-lg font-bold tabular-nums text-amber-900">{checklist.awaiting_completion_count ?? 0}</dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Not finalized</dt>
                <dd className="mt-0.5 text-lg font-bold tabular-nums text-neutral-950">{checklist.not_finalized_count ?? 0}</dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Changed since finalization</dt>
                <dd className="mt-0.5 text-lg font-bold tabular-nums text-amber-900">{checklist.changed_since_finalization_count ?? 0}</dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Ready for payout</dt>
                <dd className="mt-0.5 text-lg font-bold tabular-nums text-brand-800">{checklist.ready_for_payout_count ?? 0}</dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Paid in full</dt>
                <dd className="mt-0.5 text-lg font-bold tabular-nums text-emerald-800">{checklist.paid_count ?? 0}</dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Active reserves</dt>
                <dd className="mt-0.5 text-base font-bold tabular-nums text-neutral-950">
                  {checklist.active_reserve_count ?? 0} · {money(checklist.total_reserve_cents)}
                </dd>
              </div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <dt className="text-xs text-neutral-600">Total remaining owed</dt>
                <dd className="mt-0.5 text-base font-bold tabular-nums text-neutral-950">{money(checklist.total_owed_cents)}</dd>
              </div>
            </dl>

            <div className="mt-4 space-y-2 rounded-xl border border-amber-200 bg-amber-50 p-3.5 text-xs text-amber-950">
              <p className="font-semibold">
                Reference for approved check exceptions:{' '}
                <code className="rounded bg-white px-1.5 py-0.5 font-mono text-neutral-900">
                  {checklist.check_reference_pattern || 'CHK-<check_number>-E<event_id>'}
                </code>
              </p>
              <p>
                <strong>30-day reserve holdback reminder:</strong> Reconcile any open refunds or disputes, then release the remaining reserve 30 days after the event and finalize a closing statement.
              </p>
              {checklist.guidance && <p className="text-amber-900">{checklist.guidance}</p>}
            </div>
          </section>
        </div>

        {/* Group Subtotals & Channel Breakdown */}
        <div className="grid min-w-0 grid-cols-1 gap-6 lg:grid-cols-2">
          <section aria-labelledby="groups-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white">
            <div className="px-5 pt-5 sm:px-6">
              <h2 id="groups-heading" className="text-lg font-semibold text-neutral-950">Group Subtotals</h2>
              <p className="mt-1 text-sm text-neutral-600">Admissions separated from team registration so revenue-share bases stay clean.</p>
            </div>
            <div className="mt-4 overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-neutral-50 text-xs text-neutral-600">
                  <tr>
                    <th scope="col" className="px-5 py-3 text-left font-medium">Group</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Events</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Tickets</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Gross</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Proceeds</th>
                    <th scope="col" className="px-5 py-3 text-right font-medium">Owed</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {groupRows.map(({ key, label, subtitle, row, total }) => (
                    <tr key={key} className={total ? 'bg-neutral-50/80 font-semibold text-neutral-950' : ''}>
                      <td className="px-5 py-3">
                        <p className="font-medium text-neutral-950">{label}</p>
                        <p className="text-xs font-normal text-neutral-500">{subtitle}</p>
                      </td>
                      <td className="px-3 py-3 text-right tabular-nums">{row.events_count || 0}</td>
                      <td className="px-3 py-3 text-right tabular-nums">
                        {row.tickets_issued_count || 0}
                        <span className="block text-xs font-normal text-neutral-500">{row.checked_in_count || 0} in</span>
                      </td>
                      <td className="px-3 py-3 text-right tabular-nums">{money(row.gross_cents)}</td>
                      <td className="px-3 py-3 text-right tabular-nums">{money(row.organizer_proceeds_cents)}</td>
                      <td className="px-5 py-3 text-right tabular-nums">{money(row.owed_cents)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <section aria-labelledby="channels-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white">
            <div className="px-5 pt-5 sm:px-6">
              <h2 id="channels-heading" className="text-lg font-semibold text-neutral-950">Channel Breakdown</h2>
              <p className="mt-1 text-sm text-neutral-600">Online Stripe payments, door card sales, door cash retained by organizer, and free/comp tickets.</p>
            </div>
            <div className="mt-4 overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="bg-neutral-50 text-xs text-neutral-600">
                  <tr>
                    <th scope="col" className="px-5 py-3 text-left font-medium">Channel</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Orders</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Tickets</th>
                    <th scope="col" className="px-3 py-3 text-right font-medium">Gross</th>
                    <th scope="col" className="px-5 py-3 text-right font-medium">Proceeds</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {channelRows.map((row) => (
                    <tr key={row.channel}>
                      <td className="px-5 py-3">
                        <p className="font-medium text-neutral-950">{row.label}</p>
                        {row.channel === 'door_cash' && (
                          <p className="text-xs text-neutral-500">
                            Cash retained: {money(row.door_cash_retained_cents)}
                          </p>
                        )}
                      </td>
                      <td className="px-3 py-3 text-right tabular-nums">{row.orders_count || 0}</td>
                      <td className="px-3 py-3 text-right tabular-nums">
                        {row.tickets_issued_count || 0}
                        <span className="block text-xs text-neutral-500">{row.checked_in_count || 0} in</span>
                      </td>
                      <td className="px-3 py-3 text-right tabular-nums">{money(row.gross_cents)}</td>
                      <td className="px-5 py-3 text-right font-medium tabular-nums text-neutral-950">{money(row.organizer_proceeds_cents)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </div>

        {/* Per-Event Breakdown */}
        <section aria-labelledby="events-breakdown-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white">
          <div className="px-5 pt-5 sm:px-6">
            <h2 id="events-breakdown-heading" className="text-lg font-semibold text-neutral-950">Per-Event Breakdown</h2>
            <p className="mt-1 text-sm text-neutral-600">Select any event to open its settlement statement and payout controls.</p>
          </div>
          {events.length === 0 ? (
            <p className="m-5 rounded-xl bg-neutral-50 px-4 py-8 text-center text-sm text-neutral-600 sm:m-6">
              No events are assigned to this series yet.
            </p>
          ) : (
            <>
              <div className="mt-4 hidden overflow-x-auto md:block">
                <table className="w-full text-sm">
                  <thead className="bg-neutral-50 text-xs text-neutral-600">
                    <tr>
                      <th scope="col" className="px-5 py-3 text-left font-medium">Event</th>
                      <th scope="col" className="px-3 py-3 text-left font-medium">Role</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Tickets / In</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Gross</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Proceeds</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Door Cash</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Payable</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Paid / Owed</th>
                      <th scope="col" className="px-5 py-3 text-left font-medium">Settlement & Payout</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-neutral-100">
                    {events.map((row) => (
                      <tr key={row.event_id} className="align-top">
                        <td className="max-w-xs px-5 py-3">
                          <Link
                            to={`/dashboard/events/${row.event_id}/analytics#settlement`}
                            className="font-semibold text-neutral-950 underline-offset-2 hover:text-brand-800 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus"
                          >
                            {row.title}
                          </Link>
                          <p className="text-xs capitalize text-neutral-500">
                            {row.starts_at ? formatEventDate(row.starts_at, row.timezone || undefined) : 'Date TBD'} · {row.status}
                          </p>
                        </td>
                        <td className="px-3 py-3"><RoleBadge role={row.role} /></td>
                        <td className="px-3 py-3 text-right tabular-nums">
                          {row.tickets_issued_count} / {row.checked_in_count}
                          <span className="block text-xs text-neutral-500">
                            {row.direct_paid_tickets_count} paid · {row.free_tickets_count} free
                            {row.pass_child_tickets_count > 0 ? ` · ${row.pass_child_tickets_count} pass` : ''}
                          </span>
                        </td>
                        <td className="px-3 py-3 text-right tabular-nums">
                          {money(row.gross_cents)}
                          {(row.discount_cents > 0 || row.refund_cents > 0) && (
                            <span className="block text-xs text-neutral-500">
                              {row.discount_cents > 0 ? `−${money(row.discount_cents)} disc` : ''}
                              {row.discount_cents > 0 && row.refund_cents > 0 ? ' · ' : ''}
                              {row.refund_cents > 0 ? `−${money(row.refund_cents)} ref` : ''}
                            </span>
                          )}
                        </td>
                        <td className="px-3 py-3 text-right font-medium tabular-nums text-neutral-950">
                          {money(row.organizer_proceeds_cents)}
                          {row.processing_fee_cents > 0 && (
                            <span className="block text-xs font-normal text-neutral-500">
                              −{money(row.processing_fee_cents)} proc
                            </span>
                          )}
                        </td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.door_cash_retained_cents)}</td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.payable_cents)}</td>
                        <td className="px-3 py-3 text-right tabular-nums">
                          <span className="font-semibold text-neutral-950">{money(row.owed_cents)}</span>
                          <span className="block text-xs text-neutral-500">Paid {money(row.paid_cents)}</span>
                          {row.negative_balance_cents > 0 && (
                            <span className="block text-xs font-semibold text-red-700">
                              Overpaid −{money(row.negative_balance_cents)}
                            </span>
                          )}
                          {row.unresolved_buyer_liability_cents > 0 && (
                            <span className="block text-xs font-semibold text-red-700">
                              Liability {money(row.unresolved_buyer_liability_cents)}
                            </span>
                          )}
                        </td>
                        <td className="px-5 py-3">
                          <div className="flex flex-wrap gap-1.5">
                            <StatementBadge row={row} />
                            <PayoutStateBadge state={row.payout_state} />
                            {row.negative_balance_cents > 0 && (
                              <Badge tone="critical" icon={AlertTriangle}>
                                Overpaid −{money(row.negative_balance_cents)}
                              </Badge>
                            )}
                            {row.unresolved_buyer_liability_cents > 0 && (
                              <Badge tone="critical" icon={AlertTriangle}>
                                Liability {money(row.unresolved_buyer_liability_cents)}
                              </Badge>
                            )}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <ul className="mt-4 divide-y divide-neutral-100 border-t border-neutral-100 md:hidden">
                {events.map((row) => (
                  <li key={row.event_id} className="px-5 py-4">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <Link
                          to={`/dashboard/events/${row.event_id}/analytics#settlement`}
                          className="break-words font-semibold text-neutral-950 hover:text-brand-800 hover:underline"
                        >
                          {row.title}
                        </Link>
                        <div className="mt-1 flex flex-wrap items-center gap-1.5">
                          <RoleBadge role={row.role} />
                          <span className="text-xs text-neutral-500">
                            {row.starts_at ? formatEventDate(row.starts_at, row.timezone || undefined) : 'Date TBD'}
                          </span>
                        </div>
                      </div>
                      <div className="shrink-0 text-right">
                        <p className="font-semibold tabular-nums text-neutral-950">{money(row.owed_cents)}</p>
                        <p className="text-xs text-neutral-500">owed</p>
                        {row.negative_balance_cents > 0 && (
                          <p className="text-xs font-semibold tabular-nums text-red-700">
                            Overpaid −{money(row.negative_balance_cents)}
                          </p>
                        )}
                        {row.unresolved_buyer_liability_cents > 0 && (
                          <p className="text-xs font-semibold tabular-nums text-red-700">
                            Liability {money(row.unresolved_buyer_liability_cents)}
                          </p>
                        )}
                      </div>
                    </div>
                    <p className="mt-2 text-xs tabular-nums text-neutral-600">
                      Tickets {row.tickets_issued_count} ({row.checked_in_count} in) · Gross {money(row.gross_cents)} · Proceeds {money(row.organizer_proceeds_cents)}
                    </p>
                    {(row.discount_cents > 0 || row.refund_cents > 0) && (
                      <p className="mt-0.5 text-xs tabular-nums text-neutral-500">
                        {row.discount_cents > 0 ? `Discounts −${money(row.discount_cents)}` : ''}
                        {row.discount_cents > 0 && row.refund_cents > 0 ? ' · ' : ''}
                        {row.refund_cents > 0 ? `Refunds −${money(row.refund_cents)}` : ''}
                      </p>
                    )}
                    <p className="mt-0.5 text-xs tabular-nums text-neutral-600">
                      Door cash {money(row.door_cash_retained_cents)} · Payable {money(row.payable_cents)} · Paid {money(row.paid_cents)}
                    </p>
                    <div className="mt-2 flex flex-wrap gap-1.5">
                      <StatementBadge row={row} />
                      <PayoutStateBadge state={row.payout_state} />
                      {row.negative_balance_cents > 0 && (
                        <Badge tone="critical" icon={AlertTriangle}>
                          Overpaid −{money(row.negative_balance_cents)}
                        </Badge>
                      )}
                      {row.unresolved_buyer_liability_cents > 0 && (
                        <Badge tone="critical" icon={AlertTriangle}>
                          Liability {money(row.unresolved_buyer_liability_cents)}
                        </Badge>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            </>
          )}
        </section>

        {/* Ticket-Type Breakdown */}
        <section aria-labelledby="ticket-types-heading" className="min-w-0 rounded-2xl border border-neutral-200 bg-white">
          <div className="px-5 pt-5 sm:px-6">
            <h2 id="ticket-types-heading" className="text-lg font-semibold text-neutral-950">Ticket-Type Breakdown</h2>
            <p className="mt-1 text-sm text-neutral-600">Issued tickets, check-ins, and proceeds by event, ticket type, and pricing tier.</p>
          </div>
          {ticketTypes.length === 0 ? (
            <p className="m-5 rounded-xl bg-neutral-50 px-4 py-8 text-center text-sm text-neutral-600 sm:m-6">
              No tickets have been issued in this series yet.
            </p>
          ) : (
            <>
              <div className="mt-4 hidden overflow-x-auto md:block">
                <table className="w-full text-sm">
                  <thead className="bg-neutral-50 text-xs text-neutral-600">
                    <tr>
                      <th scope="col" className="px-5 py-3 text-left font-medium">Event</th>
                      <th scope="col" className="px-3 py-3 text-left font-medium">Ticket Type</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Price</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Issued / In</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Gross</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Discounts</th>
                      <th scope="col" className="px-3 py-3 text-right font-medium">Refunded</th>
                      <th scope="col" className="px-5 py-3 text-right font-medium">Proceeds</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-neutral-100">
                    {ticketTypes.map((row) => (
                      <tr key={`${row.event_id}-${row.ticket_type_id}-${row.pricing_tier_id ?? 'base'}-${row.price_cents ?? 0}`}>
                        <td className="px-5 py-3">
                          <p className="font-medium text-neutral-950">{row.event_title}</p>
                          <div className="mt-0.5"><RoleBadge role={row.role} /></div>
                        </td>
                        <td className="px-3 py-3">
                          <p className="font-medium text-neutral-900">{row.ticket_type_name}</p>
                          {row.pricing_tier_name && (
                            <span className="text-xs text-neutral-500">Tier: {row.pricing_tier_name}</span>
                          )}
                        </td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.price_cents)}</td>
                        <td className="px-3 py-3 text-right tabular-nums">{row.tickets_issued_count} / {row.checked_in_count}</td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.gross_cents)}</td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.discount_cents)}</td>
                        <td className="px-3 py-3 text-right tabular-nums">{money(row.refunded_proceeds_cents)}</td>
                        <td className="px-5 py-3 text-right font-semibold tabular-nums text-neutral-950">{money(row.organizer_proceeds_cents)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <ul className="mt-4 divide-y divide-neutral-100 border-t border-neutral-100 md:hidden">
                {ticketTypes.map((row) => (
                  <li key={`${row.event_id}-${row.ticket_type_id}-${row.pricing_tier_id ?? 'base'}-${row.price_cents ?? 0}`} className="px-5 py-4">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="font-semibold text-neutral-950">
                          {row.ticket_type_name}
                          {row.pricing_tier_name ? ` · ${row.pricing_tier_name}` : ''}
                        </p>
                        <p className="text-xs text-neutral-600">{row.event_title}</p>
                      </div>
                      <p className="shrink-0 font-semibold tabular-nums text-neutral-950">{money(row.organizer_proceeds_cents)}</p>
                    </div>
                    <p className="mt-1.5 text-xs tabular-nums text-neutral-600">
                      {money(row.price_cents)} ea · {row.tickets_issued_count} issued ({row.checked_in_count} in) · Gross {money(row.gross_cents)}
                    </p>
                    {(row.discount_cents > 0 || row.refunded_proceeds_cents > 0) && (
                      <p className="mt-0.5 text-xs tabular-nums text-neutral-500">
                        {row.discount_cents > 0 ? `Discounts −${money(row.discount_cents)}` : ''}
                        {row.discount_cents > 0 && row.refunded_proceeds_cents > 0 ? ' · ' : ''}
                        {row.refunded_proceeds_cents > 0 ? `Refunded −${money(row.refunded_proceeds_cents)}` : ''}
                      </p>
                    )}
                  </li>
                ))}
              </ul>
            </>
          )}
        </section>
      </div>
    </WorkspacePage>
  )
}

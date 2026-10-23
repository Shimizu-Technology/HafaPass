import { useCallback, useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import apiClient from '../../api/client'
import { organizerActivityApi } from '../../api/activity'
import { useOrganizerIdentity, useOrganizerPageVisit, useOrganizerRequests } from '../../hooks/useOrganizerContext'
import { canViewOrganizationActivity } from '../../utils/organizerOrganizations'
import { BackLink, PageHeader, WorkspacePage } from '../../components/WorkspacePage'
import NoAccessNotice from '../../components/NoAccessNotice'
import ActivityFilters from '../../components/activity/ActivityFilters'
import ActivityTimeline from '../../components/activity/ActivityTimeline'
import ActivityExportButton from '../../components/activity/ActivityExportButton'
import SettingsNavigation from '../../components/activity/SettingsNavigation'

const PATH = '/dashboard/settings/activity'
const FILTERS = ['q', 'from', 'to', 'actor_user_id', 'area', 'event_id', 'outcome']
const compactParams = values => Object.fromEntries(Object.entries(values).filter(([, value]) => value !== '' && value != null))

export default function ActivityPage() {
  const identity = useOrganizerIdentity()
  const visit = useOrganizerPageVisit(PATH)
  if (!visit.active) return null
  if (!identity.ready) return <p role="status" className="p-6">Preparing your account…</p>
  return <ActivitySession key={`${identity.accountKey}:${identity.organizationId}:${visit.generation}`} identity={identity} />
}

function ActivitySession({ identity }) {
  const { beginRequest } = useOrganizerRequests(identity, PATH)
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = Object.fromEntries(FILTERS.map(name => [name, searchParams.get(name) || '']))
  const filterKey = JSON.stringify(compactParams(filters))
  const [organization, setOrganization] = useState(null)
  const [state, setState] = useState({ loading: true, data: null, error: '', denied: false })
  const generation = useRef(0)
  const pending = useRef(null)
  const accessEpoch = useRef(0)
  const activityScope = useRef(null)
  const requests = useRef(new Set())

  const handleDenied = useCallback(error => {
    if (![401, 403].includes(error.response?.status)) return false
    ++accessEpoch.current
    requests.current.forEach(request => request.controller.abort())
    setOrganization(null)
    setState({ loading: false, data: null, denied: true, error: 'Your activity access changed. Retry to verify your current role.' })
    return true
  }, [])
  const beginActivityRequest = useCallback(() => {
    const request = beginRequest()
    if (!request) return null
    const epoch = accessEpoch.current
    requests.current.add(request)
    return { ...request,
      current: () => request.current() && epoch === accessEpoch.current,
      handleError: handleDenied,
      release: () => { requests.current.delete(request); request.release() },
    }
  }, [beginRequest, handleDenied])

  const load = useCallback(async (cursor = null) => {
    const request = beginActivityRequest()
    if (!request) return
    pending.current?.controller.abort()
    pending.current = request
    const attempt = ++generation.current
    const current = () => request.current() && attempt === generation.current
    setState(previous => ({ ...previous, loading: true, error: '', denied: false, data: cursor ? previous.data : null }))
    try {
      const response = await apiClient.get('/organizer/organization', request.config)
      if (!current()) return
      const org = response.data
      if (org.id == null || (identity.organizationId != null && String(org.id) !== identity.organizationId)) throw new Error('Organization mismatch')
      const scope = org.activity_scope || JSON.stringify([org.role, org.permissions, org.activity_access])
      if (activityScope.current && activityScope.current !== scope) {
        // A role or assignment downgrade can retain some activity access.
        // Withdraw old rows/exports and start a new authorized snapshot.
        activityScope.current = scope
        ++accessEpoch.current
        requests.current.forEach(pendingRequest => pendingRequest.controller.abort())
        setState({ loading: true, data: null, denied: false, error: '' })
        setOrganization(org)
        load()
        return
      }
      activityScope.current = scope
      setOrganization(org)
      if (!canViewOrganizationActivity(org)) {
        ++accessEpoch.current
        requests.current.forEach(pendingRequest => pendingRequest.controller.abort())
        setState({ loading: false, data: null, denied: true, error: '' })
        return
      }
      const result = await organizerActivityApi.list({ ...JSON.parse(filterKey), ...(cursor ? { cursor } : {}), limit: 50 }, request.config)
      if (!current()) return
      setState(previous => ({ loading: false, error: '', denied: false, data: {
        ...result.data,
        filters: result.data.filters || (cursor ? previous.data?.filters : undefined),
        activity_logs: cursor ? [...new Map([...(previous.data?.activity_logs || []), ...result.data.activity_logs].map(entry => [entry.id, entry])).values()] : result.data.activity_logs,
      } }))
    } catch (error) {
      if (!current() || request.handleError(error)) return
      setState(previous => ({ ...previous, loading: false, error: 'Activity could not be loaded. Your filters have been kept.' }))
    } finally { request.release() }
  }, [beginActivityRequest, identity.organizationId, filterKey])
  useEffect(() => { load(); return () => pending.current?.controller.abort() }, [load])

  const setFilter = changes => setSearchParams(compactParams({ ...filters, ...changes }), { replace: true })
  const entries = state.data?.activity_logs || []
  const started = state.data?.meta?.activity_logging_started_at
  const startedDate = started && new Intl.DateTimeFormat('en-US', { timeZone: 'Pacific/Guam', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(started.length === 10 ? `${started}T00:00:00+10:00` : started))
  return <WorkspacePage>
    <PageHeader back={<BackLink />} eyebrow={organization?.name || 'Organization'} title="Activity" description="See what changed and who made it happen. All times are Guam time."
      actions={!state.denied && organization && <ActivityExportButton key={`${filterKey}:${activityScope.current}`} api={organizerActivityApi} params={JSON.parse(filterKey)} beginRequest={beginActivityRequest} disabled={state.loading || !state.data} />} />
    {organization && <SettingsNavigation organization={organization} />}
    {state.denied ? <>
      <NoAccessNotice title="Activity is not available for your role" detail="Ask your organization owner if you need access to activity. Event managers can view activity for their assigned events." />
      {state.error && <p role="alert" className="mt-3 text-sm text-red-800">{state.error}</p>}
      <button type="button" className="btn-secondary mt-4" onClick={() => load()}>Retry activity access</button>
    </> : <>
      <ActivityFilters filters={filters} options={state.data?.filters} onChange={setFilter} onClear={() => setSearchParams({}, { replace: true })} busy={state.loading} />
      {startedDate && <p className="mb-5 text-sm text-neutral-600">Activity is recorded from {startedDate}. Earlier changes aren’t shown.</p>}
      {state.loading && <p role="status" className="py-5 text-sm text-neutral-600">{state.data ? 'Loading more activity…' : 'Loading activity…'}</p>}
      {state.error && <div role="alert" className="mb-4 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
        {state.error} <button type="button" className="min-h-11 px-2 font-semibold underline" onClick={() => load(state.data?.meta?.next_cursor)}>Try again</button>
      </div>}
      {entries.length > 0 && <ActivityTimeline entries={entries} />}
      {!state.loading && !state.error && !entries.length && <div className="rounded-xl border border-neutral-200 bg-white px-5 py-12 text-center">
        <h2 className="font-semibold text-neutral-900">{Object.values(filters).some(Boolean) ? 'No activity matches these filters.' : 'No activity yet'}</h2>
        <p className="mt-2 text-sm text-neutral-600">{Object.values(filters).some(Boolean) ? 'Try a wider date range or clear your filters.' : 'Changes made by your organization will appear here.'}</p>
      </div>}
      {state.data?.meta?.next_cursor && <div className="mt-6 text-center"><button type="button" className="btn-secondary" disabled={state.loading} onClick={() => load(state.data.meta.next_cursor)}>Load more</button></div>}
    </>}
  </WorkspacePage>
}

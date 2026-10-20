import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ArrowLeft, LayoutDashboard, Loader2 } from 'lucide-react'
import apiClient from '../../api/client'
import AdminLayout from './AdminLayout'
import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import TeamManager from '../../components/team/TeamManager'
import { usePlatformIdentity, usePlatformRequests, usePlatformVisit } from '../../hooks/usePlatformContext'
import { resetOrganizerOrganizations } from '../../utils/organizerOrganizations'
import { TEAM_ROLES } from '../../utils/roles'
import { adminLabel } from './adminLabels'

function AdminOrganizationSession({ id, identity }) {
  const { beginRequest } = usePlatformRequests(identity, `/admin/organizations/${id}`)
  const navigate = useNavigate()
  const [state, setState] = useState({ status: 'loading', organization: null })

  const load = useCallback(() => {
    const request = beginRequest()
    if (!request) return
    apiClient.get(`/admin/organizations/${id}`, request.config)
      .then(response => { if (request.current()) setState({ status: 'ready', organization: response.data }) })
      .catch(error => { if (request.current() && !request.handleError(error)) setState({ status: error.response?.status === 404 ? 'missing' : 'error', organization: null }) })
      .finally(() => request.release())
  }, [beginRequest, id])
  useEffect(() => { load() }, [load])

  // Bound to this page's admin authority; TeamManager reuses the organizer rules.
  const teamRequest = useCallback(async (method, url, payload) => {
    const request = beginRequest()
    if (!request) throw new DOMException('Page context changed', 'AbortError')
    try {
      return method === 'get' || method === 'delete'
        ? await apiClient[method](url, request.config)
        : await apiClient[method](url, payload, request.config)
    } catch (error) {
      request.handleError(error)
      throw error
    } finally { request.release() }
  }, [beginRequest])

  const openWorkspace = () => {
    window.localStorage.setItem('hafapass_organization_id', String(id))
    resetOrganizerOrganizations()
    navigate('/dashboard')
  }

  const organization = state.organization
  const hasOwner = organization?.memberships?.some(item => item.role === 'owner' && ['accepted', 'pending'].includes(item.invitation_status))
  return (
    <AdminLayout>
      <Link to="/admin/organizations" className="mb-4 inline-flex min-h-11 items-center gap-1.5 text-sm font-semibold text-neutral-700 [@media(hover:hover)]:hover:text-neutral-950"><ArrowLeft aria-hidden="true" className="h-4 w-4" />All organizations</Link>
      {state.status === 'loading' && <div role="status" aria-label="Loading organization" className="flex justify-center py-12"><Loader2 aria-hidden="true" className="h-6 w-6 animate-spin text-brand-700 motion-reduce:animate-none" /></div>}
      {state.status === 'missing' && <p role="alert" className="rounded-xl border border-neutral-200 bg-white p-5">That organization was not found.</p>}
      {state.status === 'error' && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-5 text-red-800">The organization could not be loaded. <button type="button" onClick={load} className="min-h-11 font-semibold underline">Try again</button></div>}
      {organization && (
        <div className="space-y-6">
          <section className="rounded-2xl border border-neutral-200 bg-white p-5 sm:p-6" aria-labelledby="organization-name">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
              <div className="min-w-0">
                <h2 id="organization-name" className="text-xl font-bold text-neutral-900 [overflow-wrap:anywhere]">{organization.name}</h2>
                <dl className="mt-3 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
                  <div><dt className="inline text-content-muted">Owner: </dt><dd className="inline [overflow-wrap:anywhere]">{organization.owner?.email || 'none yet'}</dd></div>
                  <div><dt className="inline text-content-muted">Verification: </dt><dd className="inline">{adminLabel(organization.organizer_profile?.verification_status) || 'No profile'}</dd></div>
                  <div><dt className="inline text-content-muted">Agreement: </dt><dd className="inline">{organization.organizer_profile?.policy_accepted ? 'Accepted' : 'Not accepted'}</dd></div>
                  <div><dt className="inline text-content-muted">Events: </dt><dd className="inline">{organization.events_count}</dd></div>
                  <div><dt className="inline text-content-muted">Payouts: </dt><dd className="inline">{organization.payout_ready ? 'Ready' : 'Not ready'}</dd></div>
                </dl>
              </div>
              <button type="button" onClick={openWorkspace} className="btn-primary shrink-0 gap-2"><LayoutDashboard aria-hidden="true" className="h-4 w-4" />Open its dashboard</button>
            </div>
            <p className="mt-4 text-sm text-content-muted">Opening the dashboard lets you work inside this organization as an admin. Everything you change is recorded in the audit log.</p>
          </section>
          <TeamManager key={organization.id} basePath={`/admin/organizations/${id}/memberships`} request={teamRequest} canTransfer
            heading="Team" inviteRoles={hasOwner ? TEAM_ROLES : ['owner', ...TEAM_ROLES]}
            onChanged={load}
            description="Invite people, change roles, resend or cancel invitations and transfer ownership. Organizers see the same changes in their Settings." />
        </div>
      )}
    </AdminLayout>
  )
}

export default function AdminOrganizationPage() {
  const { id } = useParams()
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit(`/admin/organizations/${id}`)
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <AdminOrganizationSession key={`${identity.accountKey}:${id}:${visit.generation}`} id={id} identity={identity} />
}

import { NavLink } from 'react-router-dom'
import { canManageOrganizationSettings, canViewOrganizationActivity } from '../../utils/organizerOrganizations'

export default function SettingsNavigation({ organization }) {
  return <nav aria-label="Organization settings" className="my-6 flex min-w-0 flex-wrap gap-2 border-b border-neutral-200 pb-3">
    {canManageOrganizationSettings(organization) && <NavLink end to="/dashboard/settings" className={({ isActive }) => `inline-flex min-h-11 items-center rounded-lg px-4 text-sm font-semibold ${isActive ? 'bg-brand-50 text-brand-800' : 'text-neutral-700 hover:bg-neutral-100'}`}>Team &amp; payouts</NavLink>}
    {canViewOrganizationActivity(organization) && <NavLink to="/dashboard/settings/activity" className={({ isActive }) => `inline-flex min-h-11 items-center rounded-lg px-4 text-sm font-semibold ${isActive ? 'bg-brand-50 text-brand-800' : 'text-neutral-700 hover:bg-neutral-100'}`}>Activity</NavLink>}
  </nav>
}

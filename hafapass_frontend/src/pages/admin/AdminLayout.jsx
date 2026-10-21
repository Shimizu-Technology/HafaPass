import { useEffect, useId, useState } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { BarChart3, Building2, Calendar, Users, ShoppingCart, Shield, LifeBuoy, Compass, ShieldCheck, Menu, PanelLeftClose, PanelLeftOpen, Landmark, Scale, Settings, ScrollText } from 'lucide-react'
import AdminNavigationDrawer from './AdminNavigationDrawer'
import { WORKSPACE_WIDTHS } from '../../utils/workspace'

const preferenceKey = 'hafapass_admin_sidebar_collapsed'
// Grouped so the money and platform-control screens stay findable without
// crowding the rail. Support stays last: it is a separate console.
const navGroups = [
  { label: null, items: [{ to: '/admin', label: 'Dashboard', icon: BarChart3, exact: true }] },
  { label: 'Marketplace', items: [
    { to: '/admin/events', label: 'Events', icon: Calendar },
    { to: '/admin/orders', label: 'Orders', icon: ShoppingCart },
    { to: '/admin/organizations', label: 'Organizations', icon: Building2 },
    { to: '/admin/users', label: 'Users', icon: Users },
    { to: '/admin/marketplace', label: 'Marketplace', icon: Compass },
  ] },
  { label: 'Money', items: [
    { to: '/admin/payouts', label: 'Payouts', icon: Landmark },
    { to: '/admin/disputes', label: 'Disputes', icon: Scale },
  ] },
  { label: 'Platform', items: [
    { to: '/admin/settings', label: 'Settings', icon: Settings },
    { to: '/admin/provider-readiness', label: 'Provider readiness', icon: ShieldCheck },
    { to: '/admin/audit-log', label: 'Audit log', icon: ScrollText },
    { to: '/support', label: 'Support', icon: LifeBuoy },
  ] },
]
const navItems = navGroups.flatMap(group => group.items)

const matches = (pathname, item) => item.exact ? pathname === item.to
  : pathname === item.to || pathname.startsWith(`${item.to}/`)

function NavigationLink({ item, pathname, collapsed, onNavigate }) {
  const Icon = item.icon
  const active = matches(pathname, item)
  return (
    <Link to={item.to} aria-label={item.label} aria-current={active ? 'page' : undefined}
      onClick={onNavigate}
      className={`group relative flex min-h-11 items-center rounded-lg text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 ${collapsed ? 'justify-center px-2' : 'gap-3 px-3'} ${active ? 'bg-brand-50 text-brand-800 ring-1 ring-brand-200' : 'text-content-muted hover:bg-neutral-100 hover:text-neutral-900'}`}>
      <Icon aria-hidden="true" className="h-5 w-5 shrink-0" />
      {!collapsed && <span>{item.label}</span>}
      {collapsed && <span aria-hidden="true" className="pointer-events-none absolute left-full top-1/2 z-50 ml-3 -translate-y-1/2 whitespace-nowrap rounded-lg bg-neutral-950 px-3 py-2 text-xs text-white opacity-0 shadow-lg group-hover:opacity-100 group-focus-visible:opacity-100">{item.label}</span>}
    </Link>
  )
}

function Navigation({ pathname, collapsed = false, onNavigate, label }) {
  return (
    <nav aria-label={label}>
      {navGroups.map((group, index) => (
        <div key={group.label || 'overview'} className={index > 0 ? `mt-3 ${collapsed ? 'border-t border-neutral-200 pt-3' : ''}` : ''}>
          {group.label && !collapsed && <p className="mb-1 px-3 text-xs font-semibold text-neutral-600">{group.label}</p>}
          <ul className="space-y-1">
            {group.items.map(item => <li key={item.to}><NavigationLink item={item} pathname={pathname} collapsed={collapsed} onNavigate={onNavigate} /></li>)}
          </ul>
        </div>
      ))}
    </nav>
  )
}

// Every admin page is wrapped in AdminRoute. Navigation does not grant access;
// the existing route and API authorization remain the source of authority.
export default function AdminLayout({ children }) {
  const location = useLocation()
  const drawerId = useId()
  const [mobileOpen, setMobileOpen] = useState(false)
  useEffect(() => { setMobileOpen(false) }, [location.pathname])
  const [collapsed, setCollapsed] = useState(() => {
    try { return window.localStorage.getItem(preferenceKey) === 'true' }
    catch { return false }
  })
  const toggleCollapsed = () => setCollapsed(current => {
    const next = !current
    try { window.localStorage.setItem(preferenceKey, String(next)) } catch { /* Storage can be unavailable in private browsing. */ }
    return next
  })
  const current = navItems.find(item => matches(location.pathname, item))

  return (
    <div className={`mx-auto w-full min-w-0 ${WORKSPACE_WIDTHS.standard} px-4 py-6 sm:px-6 lg:px-8`}>
      <header className="mb-6 flex items-center gap-3 border-b border-neutral-200 pb-5">
        <button type="button" onClick={() => setMobileOpen(true)} aria-label="Open admin navigation" aria-controls={drawerId} aria-expanded={mobileOpen}
          className="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg border border-neutral-200 bg-white text-neutral-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 lg:hidden">
          <Menu aria-hidden="true" className="h-5 w-5" />
        </button>
        <Shield aria-hidden="true" className="hidden h-6 w-6 shrink-0 text-brand-700 lg:block" />
        <div className="min-w-0">
          <p className="text-xs font-medium text-content-muted">HåfaPass administration</p>
          <h1 className="mt-1 text-2xl font-bold text-neutral-900">{current?.label || 'Administration'}</h1>
        </div>
      </header>

      <div className="flex items-start gap-6">
        <aside className={`hidden shrink-0 self-start rounded-xl border border-neutral-200 bg-white p-3 lg:sticky lg:top-24 lg:block ${collapsed ? 'w-20' : 'w-64'}`}>
          <button type="button" onClick={toggleCollapsed} aria-label={collapsed ? 'Expand admin sidebar' : 'Collapse admin sidebar'} aria-expanded={!collapsed}
            className={`mb-3 flex min-h-11 w-full items-center rounded-lg text-content-muted hover:bg-neutral-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 ${collapsed ? 'justify-center' : 'gap-3 px-3'}`}>
            {collapsed ? <PanelLeftOpen aria-hidden="true" className="h-5 w-5" /> : <PanelLeftClose aria-hidden="true" className="h-5 w-5" />}
            {!collapsed && <span className="text-sm">Collapse sidebar</span>}
          </button>
          <Navigation pathname={location.pathname} collapsed={collapsed} label="Admin sidebar" />
        </aside>
        <section aria-label={`${current?.label || 'Administration'} workspace`} className="min-w-0 flex-1">{children}</section>
      </div>

      {mobileOpen && <AdminNavigationDrawer id={drawerId} onClose={() => setMobileOpen(false)}>
        <Navigation pathname={location.pathname} label="Mobile admin navigation" onNavigate={() => setMobileOpen(false)} />
      </AdminNavigationDrawer>}
    </div>
  )
}

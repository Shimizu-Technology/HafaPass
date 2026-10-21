import HafaPassMark from './HafaPassMark'
import { useState, useEffect, useRef, useSyncExternalStore } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { UserButton, SignedIn, useAuth } from '@clerk/clerk-react'
import { Menu, X, Ticket, LayoutDashboard, ScanLine, CalendarDays, Shield, Search, Compass, Heart, Settings, LifeBuoy, Globe, CalendarPlus, WalletCards } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import apiClient, { getApiAuthContext, subscribeApiAuthContext } from '../api/client'
import LanguageSwitcher from './LanguageSwitcher'
import { isWorkspacePath, publishAccountRole } from '../utils/workspace'
import { useCanManageOrganizationSettings, useCanViewOrganizationFinances } from '../utils/organizerOrganizations'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function NavContent({ isSignedIn, isLoaded, userId, sessionId, clerkEnabled }) {
  const menuTrigger = useRef(null)
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)
  const [scrolled, setScrolled] = useState(false)
  const [roleState, setRoleState] = useState(null)
  const [roleAttempt, setRoleAttempt] = useState(0)
  const authContext = useSyncExternalStore(subscribeApiAuthContext, getApiAuthContext)
  const accountReady = Boolean(isLoaded && isSignedIn && userId && sessionId && authContext?.ready
    && authContext.userId === userId && authContext.sessionId === sessionId)
  const currentRole = accountReady && roleState?.context === authContext ? roleState : null
  const [searchQuery, setSearchQuery] = useState('')
  const [searchOpen, setSearchOpen] = useState(false)
  const location = useLocation()
  const navigate = useNavigate()
  const { t } = useTranslation()
  const isHomepage = location.pathname === '/'

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 10)
    window.addEventListener('scroll', handleScroll, { passive: true })
    return () => window.removeEventListener('scroll', handleScroll)
  }, [])

  useEffect(() => {
    if (!accountReady) return
    let active = true
    setRoleState({ context: authContext, status: 'loading', role: null })
    apiClient.get('/me', { authContext }).then(res => {
      if (!active || getApiAuthContext() !== authContext) return
      if (res.data.clerk_id !== userId || typeof res.data.role !== 'string') {
        throw new Error('Account access response does not match the signed-in user')
      }
      setRoleState({ context: authContext, status: 'loaded', role: res.data.role, workspace: res.data.workspace || null })
    }).catch(() => {
      if (active && getApiAuthContext() === authContext) {
        setRoleState({ context: authContext, status: 'failed', role: null })
      }
    })
    return () => { active = false }
  }, [accountReady, authContext, userId, roleAttempt])

  useEffect(() => {
    setMobileMenuOpen(false)
  }, [location.pathname])

  const loadedRole = currentRole?.status === 'loaded' ? currentRole.role : null
  // What this account can use. Unknown (still loading or an older API) keeps
  // the links; known-false hides them. Pages still check access themselves.
  const workspace = currentRole?.status === 'loaded' ? currentRole.workspace : null
  const showScanner = workspace ? workspace.scanner === true : currentRole?.status !== 'loading'
  const showDashboard = workspace ? workspace.organizer === true || loadedRole === 'admin' : currentRole?.status !== 'loading'
  useEffect(() => {
    publishAccountRole(loadedRole ? authContext : null, loadedRole)
  }, [authContext, loadedRole])

  const roleAlert = isSignedIn && currentRole?.status === 'failed'

  if (isWorkspacePath(location.pathname)) {
    return <WorkspaceNav
      authContext={accountReady ? authContext : null}
      role={loadedRole}
      workspace={workspace}
      isSignedIn={isSignedIn}
      clerkEnabled={clerkEnabled}
      roleAlert={roleAlert}
      onRetryRole={() => setRoleAttempt(attempt => attempt + 1)}
      mobileMenuOpen={mobileMenuOpen}
      setMobileMenuOpen={setMobileMenuOpen}
      menuTrigger={menuTrigger}
    />
  }

  const navLinks = [
    { to: '/events', label: t('nav.events'), icon: CalendarDays },
    { to: '/discover', label: 'Discover', icon: Compass },
    // Signed-in accounts reach organizer tools through Dashboard once they
    // belong to an organization; everyone else gets the setup path.
    ...(!isSignedIn ? [{ to: '/host', label: t('nav.hostEvent'), icon: CalendarPlus }] : []),
    ...(isSignedIn ? [
      { to: '/my-tickets', label: t('nav.myTickets'), icon: Ticket },
      { to: '/saved', label: 'Saved', icon: Heart },
      ...(showScanner ? [{ to: '/dashboard/scanner', label: t('nav.scanner'), icon: ScanLine }] : []),
      ...(showDashboard ? [{ to: '/dashboard', label: t('nav.dashboard'), icon: LayoutDashboard }]
        : workspace ? [{ to: '/dashboard', label: t('nav.hostEvent'), icon: CalendarPlus }] : []),
      ...(currentRole?.role === 'admin' ? [
        { to: '/admin', label: t('nav.admin'), icon: Shield },
      ] : []),
    ] : []),
  ]

  const isActive = (path) => location.pathname === path || location.pathname.startsWith(path + '/')

  // Determine if navbar should be in "dark/transparent" mode
  const isDarkMode = isHomepage && !scrolled

  return (
    <header
      className={`app-nav sticky top-0 z-50 ${
        isDarkMode
          ? 'bg-neutral-950 border-b border-white/10'
          : scrolled
            ? 'bg-white border-b border-neutral-200 shadow-sm'
            : 'bg-white border-b border-neutral-200'
      }`}
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <Link to="/" className="flex items-center gap-2.5 group">
            <div className="w-9 h-9 rounded-xl bg-brand-700 flex items-center justify-center">
              <HafaPassMark className="h-5 w-5 text-white" />
            </div>
            <span className={`text-xl font-bold tracking-tight transition-colors duration-300 ${isDarkMode ? 'text-white' : 'text-neutral-900'}`}>
              Håfa<span className="text-brand-500">Pass</span>
            </span>
          </Link>

          {/* Desktop Nav */}
          <nav aria-label="Primary navigation" className="hidden xl:flex items-center gap-1">
            {navLinks.map(link => (
              <Link
                key={link.to}
                to={link.to}
                className={`px-3 py-2 text-sm font-medium rounded-lg transition-colors duration-200 ${
                  isActive(link.to)
                    ? isDarkMode
                      ? 'text-white bg-white/15'
                      : 'text-brand-600 bg-brand-50/80'
                    : isDarkMode
                      ? 'text-neutral-300 hover:text-white hover:bg-white/10'
                      : 'text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100/80'
                }`}
              >
                {link.label}
              </Link>
            ))}
          </nav>

          {/* Search */}
          <div className="hidden xl:flex items-center">
            {searchOpen ? (
              <form
                onSubmit={(e) => {
                  e.preventDefault()
                  if (searchQuery.trim()) {
                    navigate(`/events?search=${encodeURIComponent(searchQuery.trim())}`)
                    setSearchQuery('')
                    setSearchOpen(false)
                  }
                }}
                className="flex items-center gap-2"
              >
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-neutral-400" />
                  <input
                    type="text"
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    placeholder={t('nav.search')}
                    autoFocus
                    onBlur={() => { if (!searchQuery) setSearchOpen(false) }}
                    className={`w-56 pl-9 pr-3 py-2 text-sm rounded-lg border transition-[color,background-color,border-color,box-shadow] ${
                      isDarkMode
                        ? 'border-white/20 bg-white/10 backdrop-blur-sm text-white placeholder-neutral-400 focus:outline-none focus:ring-2 focus:ring-brand-500/30 focus:border-brand-400'
                        : 'border-neutral-200/80 bg-white/80 backdrop-blur-sm focus:outline-none focus:ring-2 focus:ring-brand-500/30 focus:border-brand-400'
                    }`}
                  />
                </div>
              </form>
            ) : (
              <button
                onClick={() => setSearchOpen(true)}
                className={`w-9 h-9 flex items-center justify-center rounded-lg transition-colors ${
                  isDarkMode
                    ? 'text-neutral-300 hover:text-white hover:bg-white/10'
                    : 'text-neutral-400 hover:text-neutral-600 hover:bg-neutral-100/80'
                }`}
                aria-label="Search events"
              >
                <Search className="w-4.5 h-4.5" />
              </button>
            )}
          </div>

          {/* Right side */}
          <div className="hidden xl:flex items-center gap-3">
            <LanguageSwitcher isDarkMode={isDarkMode} />
            {clerkEnabled && isSignedIn ? (
              <SignedIn>
                <UserButton afterSignOutUrl="/" />
              </SignedIn>
            ) : (
              <>
                <Link to="/sign-in" className={`text-sm font-medium transition-colors px-3 py-2 ${
                  isDarkMode ? 'text-neutral-300 hover:text-white' : 'text-neutral-500 hover:text-neutral-900'
                }`}>
                  {t('nav.signIn')}
                </Link>
                <Link to="/sign-up" className="btn-primary text-sm !py-2.5 !px-5">
                  {t('nav.getStarted')}
                </Link>
              </>
            )}
          </div>

          {/* Mobile menu button */}
          <div className="flex items-center gap-1 xl:hidden">
          <LanguageSwitcher isDarkMode={isDarkMode} />
          <button
            ref={menuTrigger}
            onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
            className={`xl:hidden w-11 h-11 flex items-center justify-center rounded-xl transition-colors ${
              isDarkMode
                ? 'text-neutral-300 hover:text-white hover:bg-white/10'
                : 'text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100/80'
            }`}
            aria-label="Toggle menu"
            aria-expanded={mobileMenuOpen}
            aria-controls="primary-mobile-navigation"
          >
            {mobileMenuOpen ? <X className="w-5 h-5" /> : <Menu className="w-5 h-5" />}
          </button>
          </div>
        </div>
      </div>

      {roleAlert && (
        <div role="alert" className={`flex flex-wrap items-center justify-end gap-2 px-4 py-2 text-sm ${isDarkMode ? 'text-white' : 'text-neutral-700'}`}>
          <span>Account access couldn’t load.</span>
          <button className="rounded px-2 py-1 font-semibold underline underline-offset-2" onClick={() => setRoleAttempt(attempt => attempt + 1)}>Retry account access</button>
        </div>
      )}

      {/* Mobile menu */}
      {mobileMenuOpen && (
        <nav onKeyDown={event => { if (event.key === 'Escape') { setMobileMenuOpen(false); menuTrigger.current?.focus() } }} id="primary-mobile-navigation" aria-label="Mobile navigation" className={`mobile-nav xl:hidden overflow-y-auto border-t ${
          isDarkMode
            ? 'border-white/10 bg-neutral-950/95 backdrop-blur-2xl'
            : 'border-neutral-200/50 bg-white/90 backdrop-blur-2xl'
        }`}>
          <div className="px-4 py-3 space-y-1">
            {navLinks.map(link => {
              const Icon = link.icon
              return (
                <Link
                  key={link.to}
                  to={link.to}
                  className={`flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium transition-colors ${
                    isActive(link.to)
                      ? isDarkMode
                        ? 'bg-white/10 text-white'
                        : 'bg-brand-50/80 text-brand-600'
                      : isDarkMode
                        ? 'text-neutral-400 hover:bg-white/5 hover:text-white'
                        : 'text-neutral-500 hover:bg-neutral-50 hover:text-neutral-900'
                  }`}
                >
                  <Icon className="w-4 h-4" />
                  {link.label}
                </Link>
              )
            })}
            {!isSignedIn && (
              <div className={`pt-3 border-t space-y-2 ${isDarkMode ? 'border-white/10' : 'border-neutral-200/50'}`}>
                <Link to="/sign-in" className={`block px-4 py-3 rounded-xl text-sm font-medium ${
                  isDarkMode ? 'text-neutral-400 hover:bg-white/5' : 'text-neutral-500 hover:bg-neutral-50'
                }`}>
                  {t('nav.signIn')}
                </Link>
                <Link to="/sign-up" className="block btn-primary text-center text-sm">
                  {t('nav.getStarted')}
                </Link>
              </div>
            )}
            {clerkEnabled && isSignedIn && (
              <SignedIn>
              <div className={`pt-3 border-t px-4 py-3 ${isDarkMode ? 'border-white/10' : 'border-neutral-200/50'}`}>
                <UserButton afterSignOutUrl="/" />
              </div>
              </SignedIn>
            )}
          </div>
        </nav>
      )}
    </header>
  )
}

// Organizer, admin and support routes use a workspace header: workspace links,
// a clear way back to the public site and account controls. Staff screens are
// English, so there is no language switcher here.
function WorkspaceNav({ authContext, role, workspace, isSignedIn, clerkEnabled, roleAlert, onRetryRole, mobileMenuOpen, setMobileMenuOpen, menuTrigger }) {
  const location = useLocation()
  const { t } = useTranslation()
  const { pathname } = location
  const canManageSettings = useCanManageOrganizationSettings(authContext, Boolean(authContext))
  const canViewFinances = useCanViewOrganizationFinances(authContext, Boolean(authContext))
  const showDashboard = !workspace || workspace.organizer === true || role === 'admin'
  const links = [
    ...(showDashboard ? [{ to: '/dashboard', label: t('nav.dashboard'), icon: LayoutDashboard,
      active: pathname === '/dashboard' || pathname.startsWith('/dashboard/events') }] : []),
    ...(!workspace || workspace.scanner === true ? [{ to: '/dashboard/scanner', label: t('nav.scanner'), icon: ScanLine }] : []),
    ...(canViewFinances ? [{ to: '/dashboard/finances', label: t('nav.finances'), icon: WalletCards }] : []),
    ...(canManageSettings ? [{ to: '/dashboard/settings', label: t('nav.settings'), icon: Settings }] : []),
    ...(['support', 'admin'].includes(role) ? [{ to: '/support', label: t('nav.support'), icon: LifeBuoy }] : []),
    ...(role === 'admin' ? [{ to: '/admin', label: t('nav.admin'), icon: Shield }] : []),
  ].map(link => ({ ...link, active: link.active ?? (pathname === link.to || pathname.startsWith(link.to + '/')) }))
  const linkClass = active => `inline-flex min-h-10 items-center gap-2 rounded-lg px-3 text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${
    active ? 'bg-brand-50 text-brand-800' : 'text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900'}`
  const publicSite = <><Globe aria-hidden="true" className="h-4 w-4" />{t('nav.viewPublicSite')}</>

  return (
    <header className="app-nav sticky top-0 z-50 border-b border-neutral-200 bg-white">
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
        <div className="flex h-16 items-center justify-between gap-4">
          <Link to="/dashboard" className="flex min-w-0 items-center gap-2.5 rounded-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus" aria-label={t('nav.workspaceHome')}>
            <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-brand-700">
              <HafaPassMark className="h-5 w-5 text-white" />
            </span>
            <span className="text-xl font-bold tracking-tight text-neutral-900">Håfa<span className="text-brand-500">Pass</span></span>
            <span className="hidden rounded-md border border-neutral-200 bg-neutral-50 px-2 py-0.5 text-xs font-semibold uppercase tracking-wider text-neutral-600 sm:inline">{t('nav.workspace')}</span>
          </Link>

          <nav aria-label="Primary navigation" className="hidden items-center gap-1 lg:flex">
            {links.map(link => (
              <Link key={link.to} to={link.to} aria-current={link.active ? 'page' : undefined} className={linkClass(link.active)}>
                {link.label}
              </Link>
            ))}
          </nav>

          <div className="hidden items-center gap-3 lg:flex">
            <Link to="/" className="inline-flex min-h-10 items-center gap-1.5 rounded-lg px-2 text-sm font-medium text-neutral-600 transition-colors hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">{publicSite}</Link>
            {clerkEnabled && isSignedIn && <SignedIn><UserButton afterSignOutUrl="/" /></SignedIn>}
          </div>

          <div className="flex items-center gap-1 lg:hidden">
            <button
              ref={menuTrigger}
              onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
              className="flex h-11 w-11 items-center justify-center rounded-xl text-neutral-500 transition-colors hover:bg-neutral-100 hover:text-neutral-900"
              aria-label="Toggle menu"
              aria-expanded={mobileMenuOpen}
              aria-controls="primary-mobile-navigation"
            >
              {mobileMenuOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
            </button>
          </div>
        </div>
      </div>

      {roleAlert && (
        <div role="alert" className="flex flex-wrap items-center justify-end gap-2 px-4 py-2 text-sm text-neutral-700">
          <span>Account access couldn’t load.</span>
          <button className="rounded px-2 py-1 font-semibold underline underline-offset-2" onClick={onRetryRole}>Retry account access</button>
        </div>
      )}

      {mobileMenuOpen && (
        <nav onKeyDown={event => { if (event.key === 'Escape') { setMobileMenuOpen(false); menuTrigger.current?.focus() } }} id="primary-mobile-navigation" aria-label="Mobile navigation" className="mobile-nav overflow-y-auto border-t border-neutral-200 bg-white lg:hidden">
          <div className="space-y-1 px-4 py-3">
            {links.map(link => {
              const Icon = link.icon
              return (
                <Link key={link.to} to={link.to} aria-current={link.active ? 'page' : undefined}
                  className={`flex items-center gap-3 rounded-xl px-4 py-3 text-sm font-medium transition-colors ${link.active ? 'bg-brand-50 text-brand-800' : 'text-neutral-600 hover:bg-neutral-50 hover:text-neutral-900'}`}>
                  <Icon aria-hidden="true" className="h-4 w-4" />
                  {link.label}
                </Link>
              )
            })}
            <div className="space-y-1 border-t border-neutral-200 pt-3">
              <Link to="/" className="flex items-center gap-3 rounded-xl px-4 py-3 text-sm font-medium text-neutral-600 transition-colors hover:bg-neutral-50 hover:text-neutral-900">{publicSite}</Link>
              {clerkEnabled && isSignedIn && <SignedIn><div className="px-4 py-3"><UserButton afterSignOutUrl="/" /></div></SignedIn>}
            </div>
          </div>
        </nav>
      )}
    </header>
  )
}

function ClerkNavContent() {
  const { isSignedIn, isLoaded, userId, sessionId } = useAuth()
  return <NavContent isSignedIn={Boolean(isSignedIn)} isLoaded={isLoaded} userId={userId} sessionId={sessionId} clerkEnabled />
}

export default function Navbar() {
  if (clerkPubKey) {
    return <ClerkNavContent />
  }
  return <NavContent isSignedIn={false} clerkEnabled={false} />
}

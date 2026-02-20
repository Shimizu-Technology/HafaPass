import { useState, useEffect } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { UserButton, SignedIn, SignedOut, useUser } from '@clerk/clerk-react'
import { Menu, X, Ticket, LayoutDashboard, ScanLine, CalendarDays, Shield, Search } from 'lucide-react'
import apiClient from '../api/client'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function NavContent() {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)
  const [scrolled, setScrolled] = useState(false)
  const [userRole, setUserRole] = useState(null)
  const [searchQuery, setSearchQuery] = useState('')
  const [searchOpen, setSearchOpen] = useState(false)
  const location = useLocation()
  const navigate = useNavigate()
  const { isSignedIn } = useUser ? useUser() : { isSignedIn: false }

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 10)
    window.addEventListener('scroll', handleScroll, { passive: true })
    return () => window.removeEventListener('scroll', handleScroll)
  }, [])

  useEffect(() => {
    if (isSignedIn) {
      apiClient.get('/me').then(res => setUserRole(res.data.role)).catch(() => {})
    }
  }, [isSignedIn])

  useEffect(() => {
    setMobileMenuOpen(false)
  }, [location.pathname])

  const navLinks = [
    { to: '/events', label: 'Events', icon: CalendarDays },
    ...(isSignedIn ? [
      { to: '/my-tickets', label: 'My Tickets', icon: Ticket },
      { to: '/dashboard/scanner', label: 'Scanner', icon: ScanLine },
      { to: '/dashboard', label: 'Dashboard', icon: LayoutDashboard },
      ...(userRole === 'admin' ? [
        { to: '/admin', label: 'Admin', icon: Shield },
      ] : []),
    ] : []),
  ]

  const isActive = (path) => location.pathname === path || location.pathname.startsWith(path + '/')

  return (
    <header
      className={`sticky top-0 z-50 transition-all duration-500 ${
        scrolled
          ? 'bg-white/80 backdrop-blur-2xl border-b border-neutral-200/50 shadow-soft'
          : 'bg-white/50 backdrop-blur-xl border-b border-transparent'
      }`}
    >
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex items-center justify-between h-16">
          {/* Logo */}
          <Link to="/" className="flex items-center gap-2.5 group">
            <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center shadow-md shadow-brand-500/20 transition-all duration-300 group-hover:scale-105 group-hover:shadow-glow-brand">
              <svg className="w-5 h-5 text-white" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
                <path d="M13 5v2" /><path d="M13 17v2" /><path d="M13 11v2" />
              </svg>
            </div>
            <span className="text-xl font-bold tracking-tight text-neutral-900">
              Hafa<span className="text-brand-500">Pass</span>
            </span>
          </Link>

          {/* Desktop Nav */}
          <nav className="hidden md:flex items-center gap-1">
            {navLinks.map(link => (
              <Link
                key={link.to}
                to={link.to}
                className={`px-4 py-2 text-sm font-medium rounded-lg transition-all duration-200 ${
                  isActive(link.to)
                    ? 'text-brand-600 bg-brand-50/80'
                    : 'text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100/80'
                }`}
              >
                {link.label}
              </Link>
            ))}
          </nav>

          {/* Search */}
          <div className="hidden md:flex items-center">
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
                    placeholder="Search events..."
                    autoFocus
                    onBlur={() => { if (!searchQuery) setSearchOpen(false) }}
                    className="w-56 pl-9 pr-3 py-2 text-sm rounded-lg border border-neutral-200/80 bg-white/80 backdrop-blur-sm focus:outline-none focus:ring-2 focus:ring-brand-500/30 focus:border-brand-400 transition-all"
                  />
                </div>
              </form>
            ) : (
              <button
                onClick={() => setSearchOpen(true)}
                className="w-9 h-9 flex items-center justify-center rounded-lg text-neutral-400 hover:text-neutral-600 hover:bg-neutral-100/80 transition-colors"
                aria-label="Search events"
              >
                <Search className="w-4.5 h-4.5" />
              </button>
            )}
          </div>

          {/* Right side */}
          <div className="hidden md:flex items-center gap-3">
            <SignedIn>
              <UserButton afterSignOutUrl="/" />
            </SignedIn>
            <SignedOut>
              <Link to="/sign-in" className="text-sm font-medium text-neutral-500 hover:text-neutral-900 transition-colors px-3 py-2">
                Sign In
              </Link>
              <Link to="/sign-up" className="btn-primary text-sm !py-2.5 !px-5">
                Get Started
              </Link>
            </SignedOut>
          </div>

          {/* Mobile menu button */}
          <button
            onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
            className="md:hidden w-10 h-10 flex items-center justify-center rounded-xl text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100/80 transition-colors"
            aria-label="Toggle menu"
          >
            {mobileMenuOpen ? <X className="w-5 h-5" /> : <Menu className="w-5 h-5" />}
          </button>
        </div>
      </div>

      {/* Mobile menu */}
      {mobileMenuOpen && (
        <div className="md:hidden border-t border-neutral-200/50 bg-white/90 backdrop-blur-2xl">
          <div className="px-4 py-3 space-y-1">
            {navLinks.map(link => {
              const Icon = link.icon
              return (
                <Link
                  key={link.to}
                  to={link.to}
                  className={`flex items-center gap-3 px-4 py-3 rounded-xl text-sm font-medium transition-colors ${
                    isActive(link.to)
                      ? 'bg-brand-50/80 text-brand-600'
                      : 'text-neutral-500 hover:bg-neutral-50 hover:text-neutral-900'
                  }`}
                >
                  <Icon className="w-4 h-4" />
                  {link.label}
                </Link>
              )
            })}
            <SignedOut>
              <div className="pt-3 border-t border-neutral-200/50 space-y-2">
                <Link to="/sign-in" className="block px-4 py-3 rounded-xl text-sm font-medium text-neutral-500 hover:bg-neutral-50">
                  Sign In
                </Link>
                <Link to="/sign-up" className="block btn-primary text-center text-sm">
                  Get Started
                </Link>
              </div>
            </SignedOut>
            <SignedIn>
              <div className="pt-3 border-t border-neutral-200/50 px-4 py-3">
                <UserButton afterSignOutUrl="/" />
              </div>
            </SignedIn>
          </div>
        </div>
      )}
    </header>
  )
}

export default function Navbar() {
  if (clerkPubKey) {
    return <NavContent />
  }
  return <NavContent />
}

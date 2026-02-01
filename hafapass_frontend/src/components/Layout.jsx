import { Outlet, useLocation } from 'react-router-dom'
import Navbar from './Navbar'

export default function Layout() {
  const location = useLocation()
  const isHomePage = location.pathname === '/'

  return (
    <div className="min-h-screen flex flex-col bg-neutral-50">
      <Navbar />
      <main className="flex-1">
        <Outlet />
      </main>
      {/* HomePage renders its own footer inside its hero/CTA sections */}
      {!isHomePage && (
        <footer className="bg-brand-950 text-neutral-400 py-12">
          <div className="max-w-6xl mx-auto px-6 lg:px-8">
            <div className="flex flex-col sm:flex-row items-center justify-between gap-4">
              <div className="flex items-center gap-2">
                <div className="w-7 h-7 rounded-lg bg-brand-500/20 flex items-center justify-center">
                  <svg className="w-4 h-4 text-brand-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
                  </svg>
                </div>
                <span className="text-sm font-semibold text-neutral-300">HafaPass</span>
              </div>
              <p className="text-xs text-neutral-500">
                &copy; {new Date().getFullYear()} Shimizu Technology. All rights reserved.
              </p>
            </div>
          </div>
        </footer>
      )}
    </div>
  )
}

import { useEffect, useRef, useState } from 'react'
import { useLocation, useOutlet } from 'react-router-dom'
import { motion, useReducedMotion } from 'framer-motion'
import Navbar from './Navbar'
import Footer, { WorkspaceFooter } from './Footer'
import EnvironmentBanner from './EnvironmentBanner'
import { isWorkspacePath } from '../utils/workspace'

export default function Layout() {
  const location = useLocation()
  const main = useRef(null)
  const previousPath = useRef(location.pathname)
  const [announcement, setAnnouncement] = useState('')
  const outlet = useOutlet()
  const reducedMotion = useReducedMotion()
  const operational = /^\/(dashboard|admin|support|checkout|orders|tickets|sign-in|sign-up)(?:\/|$)/.test(location.pathname)
  const isHomePage = location.pathname === '/'
  const workspace = isWorkspacePath(location.pathname)

  useEffect(() => {
    if (previousPath.current === location.pathname) return undefined
    previousPath.current = location.pathname
    const content = main.current
    if (!content) return undefined
    window.scrollTo({ top: 0, behavior: 'instant' })
    // Focus only for a different page. Query/filter/hash updates leave the
    // user's input and in-page focus alone, including ticket-type anchors.
    content.focus({ preventScroll: true })
    setAnnouncement('Loading page')
    const orient = () => {
      const hash = window.location.hash
      let anchor = null
      try { anchor = hash && document.getElementById(decodeURIComponent(hash.slice(1))) } catch { /* Invalid fragments still get page focus. */ }
      const heading = content.querySelector('h1')
      const target = anchor || heading
      if (!target) return false
      if (document.activeElement === content) {
        const needsFocusTarget = !target.hasAttribute('tabindex') && target.tabIndex < 0
          && !target.matches('[contenteditable="true"], [contenteditable=""]')
        if (needsFocusTarget) {
          target.setAttribute('tabindex', '-1')
          target.addEventListener('blur', () => {
            if (target.getAttribute('tabindex') === '-1') target.removeAttribute('tabindex')
          }, { once: true })
        }
        target.focus({ preventScroll: !anchor })
      }
      setAnnouncement(heading?.textContent?.trim() || 'Page loaded')
      return true
    }
    if (orient()) return undefined
    // Authorized pages can load their heading after their access/data request.
    // Stop after the first heading; ordinary saved-state updates never refocus.
    const observer = new MutationObserver(() => { if (orient()) observer.disconnect() })
    observer.observe(content, { childList: true, subtree: true })
    return () => observer.disconnect()
  }, [location.pathname]) // Search/hash updates are intentionally not route changes.

  return (
    <div className="app-shell flex flex-col">
      <div role="status" aria-live="polite" aria-atomic="true" className="sr-only">{announcement}</div>
      <a href="#main-content" className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100] focus:rounded-xl focus:bg-white focus:px-4 focus:py-3 focus:text-neutral-950">Skip to main content</a>
      <EnvironmentBanner />
      <Navbar />
      <main ref={main} id="main-content" tabIndex={-1} className="flex-1">
        {operational || reducedMotion ? outlet :
          <motion.div
            key={location.pathname}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15, ease: 'easeOut' }}
          >
            {outlet}
          </motion.div>
        }
      </main>
      {/* HomePage renders its own footer; workspace pages keep a slim one. */}
      {workspace ? <WorkspaceFooter /> : !isHomePage && <Footer />}
    </div>
  )
}

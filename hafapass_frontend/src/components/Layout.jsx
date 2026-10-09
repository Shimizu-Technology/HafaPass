import { useEffect } from 'react'
import { useLocation, useOutlet } from 'react-router-dom'
import { motion, AnimatePresence, useReducedMotion } from 'framer-motion'
import Navbar from './Navbar'
import Footer from './Footer'
import EnvironmentBanner from './EnvironmentBanner'

export default function Layout() {
  const location = useLocation()
  const outlet = useOutlet()
  const reducedMotion = useReducedMotion()
  const operational = /^\/(dashboard|admin|support|checkout|orders|tickets|sign-in|sign-up)(?:\/|$)/.test(location.pathname)
  const isHomePage = location.pathname === '/'

  // Scroll to top on route change
  useEffect(() => {
    window.scrollTo({ top: 0, behavior: 'instant' })
  }, [location.pathname])

  return (
    <div className="min-h-screen flex flex-col">
      <a href="#main-content" className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100] focus:rounded-xl focus:bg-white focus:px-4 focus:py-3 focus:text-neutral-950">Skip to main content</a>
      <EnvironmentBanner />
      <Navbar />
      <main id="main-content" tabIndex={-1} className="flex-1">
        {operational || reducedMotion ? outlet :
        <AnimatePresence mode="popLayout">
          <motion.div
            key={location.pathname}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.15, ease: 'easeOut' }}
          >
            {outlet}
          </motion.div>
        </AnimatePresence>}
      </main>
      {/* HomePage renders its own footer */}
      {!isHomePage && <Footer />}
    </div>
  )
}

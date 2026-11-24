import { lazy, Suspense } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '@clerk/clerk-react'
import { Navigate, useLocation } from 'react-router-dom'

import { signInDestination } from '../utils/authDestination'
import PageLoading from './PageLoading'
import { clerkPublishableKey } from '../utils/demoMode'
import { isWorkspacePath } from '../utils/workspacePath'

const DemoAccountNotice = import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1' ? lazy(() => import('../demo/DemoAccountNotice')) : null

const clerkPubKey = clerkPublishableKey()

function AuthGate({ children }) {
  const { isSignedIn, isLoaded } = useAuth()
  const location = useLocation()
  const { t } = useTranslation()

  if (!isLoaded) return <PageLoading label={t('buyer.layout.loadingAccount')} />

  if (!isSignedIn) {
    return <Navigate to={signInDestination(location)} replace />
  }

  return <>{children}</>
}

export default function ProtectedRoute({ children }) {
  const location = useLocation()
  if (import.meta.env.VITE_HAFAPASS_DEMO_DATA === '1') {
    // Preview only: staff screens open with the fictional demo staff identity;
    // buyer account pages (my tickets, saved) keep the sign-in-is-off notice.
    return isWorkspacePath(location.pathname) ? <>{children}</> : <Suspense><DemoAccountNotice /></Suspense>
  }
  // If Clerk is not configured, allow access (dev mode without auth)
  if (!clerkPubKey && !import.meta.env.PROD) {
    return <>{children}</>
  }

  if (!clerkPubKey) return <p className="mx-auto max-w-md px-4 py-12" role="alert">Sign-in is temporarily unavailable. Please try again later.</p>
  return <AuthGate>{children}</AuthGate>
}

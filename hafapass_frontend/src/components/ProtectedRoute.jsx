import { useTranslation } from 'react-i18next'
import { useAuth } from '@clerk/clerk-react'
import { Navigate, useLocation } from 'react-router-dom'

import { signInDestination } from '../utils/authDestination'
import PageLoading from './PageLoading'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

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
  // If Clerk is not configured, allow access (dev mode without auth)
  if (!clerkPubKey && !import.meta.env.PROD) {
    return <>{children}</>
  }

  if (!clerkPubKey) return <p className="mx-auto max-w-md px-4 py-12" role="alert">Sign-in is temporarily unavailable. Please try again later.</p>
  return <AuthGate>{children}</AuthGate>
}

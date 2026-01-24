import { useAuth } from '@clerk/clerk-react'
import { Navigate } from 'react-router-dom'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthGate({ children }) {
  const { isSignedIn, isLoaded } = useAuth()

  if (!isLoaded) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-900"></div>
      </div>
    )
  }

  if (!isSignedIn) {
    return <Navigate to="/sign-in" replace />
  }

  return <>{children}</>
}

export default function ProtectedRoute({ children }) {
  // If Clerk is not configured, allow access (dev mode without auth)
  if (!clerkPubKey) {
    return <>{children}</>
  }

  return <AuthGate>{children}</AuthGate>
}

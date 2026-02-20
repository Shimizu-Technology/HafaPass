import { Loader2 } from 'lucide-react'
import { useAuth } from '@clerk/clerk-react'
import { Navigate } from 'react-router-dom'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthGate({ children }) {
  const { isSignedIn, isLoaded } = useAuth()

  if (!isLoaded) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
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

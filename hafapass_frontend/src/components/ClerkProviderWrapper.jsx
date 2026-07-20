import { ClerkProvider, useAuth, useUser } from '@clerk/clerk-react'
import { Sentry } from '../monitoring'
import { useEffect } from 'react'
import { setAuthTokenGetter } from '../api/client'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync() {
  const { getToken } = useAuth()
  const { isLoaded, isSignedIn, user } = useUser()

  useEffect(() => {
    setAuthTokenGetter(() => getToken())
  }, [getToken])

  useEffect(() => {
    if (!isLoaded) return
    Sentry.setUser(isSignedIn && user ? { id: user.id } : null)
  }, [isLoaded, isSignedIn, user])

  return null
}

export default function ClerkProviderWrapper({ children }) {
  if (!clerkPubKey) {
    return <>{children}</>
  }

  return (
    <ClerkProvider publishableKey={clerkPubKey} afterSignOutUrl="/">
      <AuthTokenSync />
      {children}
    </ClerkProvider>
  )
}

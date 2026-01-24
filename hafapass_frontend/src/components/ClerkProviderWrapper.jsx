import { ClerkProvider, useAuth } from '@clerk/clerk-react'
import { useEffect } from 'react'
import { setAuthTokenGetter } from '../api/client'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync() {
  const { getToken } = useAuth()

  useEffect(() => {
    setAuthTokenGetter(() => getToken())
  }, [getToken])

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

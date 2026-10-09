import { ClerkProvider, useAuth, useUser } from '@clerk/clerk-react'
import { Sentry } from '../monitoring'
import { useEffect, useState } from 'react'
import { setAuthTokenGetter } from '../api/client'
import { clearAllAdmissionData } from '../utils/admissionStore'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync({ children }) {
  const [boundUser, setBoundUser] = useState(null)
  const { getToken } = useAuth()
  const { isLoaded, isSignedIn, user } = useUser()

  useEffect(() => {
    setAuthTokenGetter(() => getToken())
  }, [getToken])

  useEffect(() => {
    if (!isLoaded) return
    Sentry.setUser(isSignedIn && user ? { id: user.id } : null)
    const key = 'hafapass_scanner_user_id'
    const previous = window.localStorage.getItem(key)
    const current = isSignedIn && user ? user.id : null
    let active = true
    if (previous && previous !== current) {
      void clearAllAdmissionData().then(() => {
        if (!active) return
        if (current) window.localStorage.setItem(key, current)
        else window.localStorage.removeItem(key)
        window.localStorage.removeItem('hafapass_organization_id')
        setBoundUser(current)
      })
    } else {
      if (current) window.localStorage.setItem(key, current)
      if (active) setBoundUser(current)
    }
    return () => { active = false }
  }, [isLoaded, isSignedIn, user])

  if (isLoaded && isSignedIn && boundUser !== user?.id) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
  return children
}

export default function ClerkProviderWrapper({ children }) {
  if (!clerkPubKey) {
    return <>{children}</>
  }

  return (
    <ClerkProvider publishableKey={clerkPubKey} afterSignOutUrl="/">
      <AuthTokenSync>{children}</AuthTokenSync>
    </ClerkProvider>
  )
}

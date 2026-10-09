import { ClerkProvider, useAuth, useUser } from '@clerk/clerk-react'
import { Sentry } from '../monitoring'
import { useEffect, useState } from 'react'
import { setAuthTokenGetter } from '../api/client'
import { clearAllAdmissionData } from '../utils/admissionStore'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync({ children, loadingFallback }) {
  const [boundUser, setBoundUser] = useState(null)
  const [bindingReady, setBindingReady] = useState(false)
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
    setBindingReady(false)
    if (previous && previous !== current) {
      void clearAllAdmissionData().then(() => {
        if (!active) return
        if (current) window.localStorage.setItem(key, current)
        else window.localStorage.removeItem(key)
        window.localStorage.removeItem('hafapass_organization_id')
        setBoundUser(current)
        setBindingReady(true)
      })
    } else {
      if (current) window.localStorage.setItem(key, current)
      if (active) setBoundUser(current)
      setBindingReady(true)
    }
    return () => { active = false }
  }, [isLoaded, isSignedIn, user])

  // Only the account-bound, verified door cache can operate before Clerk loads.
  // A definitive sign-out or account switch still purges that cache before routes mount.
  if (!isLoaded && loadingFallback) return loadingFallback
  if (isLoaded && (!bindingReady || boundUser !== (isSignedIn ? user?.id : null))) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
  return children
}

export default function ClerkProviderWrapper({ children, loadingFallback }) {
  if (!clerkPubKey) {
    return <>{children}</>
  }

  return (
    <ClerkProvider publishableKey={clerkPubKey} afterSignOutUrl="/">
      <AuthTokenSync loadingFallback={loadingFallback}>{children}</AuthTokenSync>
    </ClerkProvider>
  )
}

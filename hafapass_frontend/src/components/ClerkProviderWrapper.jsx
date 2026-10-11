import { ClerkProvider, useAuth, useUser } from '@clerk/clerk-react'
import { Sentry } from '../monitoring'
import { useEffect, useState } from 'react'
import { setAuthTokenGetter } from '../api/client'
import { clearAllAdmissionData } from '../utils/admissionStore'
import { clearUploadRecovery } from '../utils/uploadRecovery'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync({ children, loadingFallback }) {
  const [boundUser, setBoundUser] = useState(null)
  const [bindingReady, setBindingReady] = useState(false)
  const [bindingFailed, setBindingFailed] = useState(false)
  const [bindingAttempt, setBindingAttempt] = useState(0)
  const { getToken, isLoaded: authLoaded, sessionId, userId } = useAuth()
  const { isLoaded, isSignedIn, user } = useUser()
  const currentUserId = isSignedIn && user ? user.id : null

  useEffect(() => {
    return setAuthTokenGetter(() => getToken(), {
      userId: currentUserId, sessionId,
      ready: Boolean(authLoaded && isLoaded && currentUserId && userId === currentUserId),
    })
  }, [getToken, authLoaded, isLoaded, currentUserId, userId, sessionId])

  useEffect(() => {
    if (!isLoaded) return
    Sentry.setUser(currentUserId ? { id: currentUserId } : null)
    const key = 'hafapass_scanner_user_id'
    let active = true
    setBindingReady(false)
    setBindingFailed(false)
    const prepareBinding = async () => {
      try {
        const previous = window.localStorage.getItem(key)
        const changed = previous && previous !== currentUserId
        if (changed) {
          await clearAllAdmissionData()
          clearUploadRecovery(previous)
        }
        if (!active) return
        if (changed) window.localStorage.removeItem('hafapass_organization_id')
        if (currentUserId) window.localStorage.setItem(key, currentUserId)
        else window.localStorage.removeItem(key)
        setBoundUser(currentUserId)
        setBindingReady(true)
      } catch {
        // Keep the previous owner and cached routes inaccessible until a full purge succeeds.
        if (active) setBindingFailed(true)
      }
    }
    void prepareBinding()
    return () => { active = false }
  }, [isLoaded, currentUserId, bindingAttempt])

  // Only the account-bound, verified door cache can operate before Clerk loads.
  // A definitive sign-out or account switch still purges that cache before routes mount.
  if (bindingFailed) return <div className="mx-auto max-w-md px-4 py-12" role="alert">
    <p>We could not clear this device’s saved event access. Your account is still locked for privacy. Please try again.</p>
    <button className="btn-primary mt-4" onClick={() => setBindingAttempt(attempt => attempt + 1)}>Retry account preparation</button>
  </div>
  if (!isLoaded && loadingFallback) return loadingFallback
  if (isLoaded && (!bindingReady || boundUser !== currentUserId)) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
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

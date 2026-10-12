import { ClerkProvider, useAuth, useUser } from '@clerk/clerk-react'
import { Sentry } from '../monitoring'
import { useEffect, useLayoutEffect, useState } from 'react'
import { setAuthTokenGetter } from '../api/client'
import { clearAllAdmissionData } from '../utils/admissionStore'
import { clearUploadRecovery } from '../utils/uploadRecovery'
import { completeScannerBinding, currentScannerOwner, hasPendingScannerBinding, SCANNER_OWNER_KEY, withdrawScannerBinding } from '../utils/scannerAccountBinding'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync({ children, loadingFallback }) {
  const [boundUser, setBoundUser] = useState(null)
  const [bindingReady, setBindingReady] = useState(false)
  const [bindingFailed, setBindingFailed] = useState(false)
  const [bindingWithdrawn, setBindingWithdrawn] = useState(hasPendingScannerBinding)
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

  useLayoutEffect(() => {
    if (!isLoaded) return
    Sentry.setUser(currentUserId ? { id: currentUserId } : null)
    let active = true
    setBindingReady(false)
    setBindingFailed(false)
    const prepareBinding = async () => {
      try {
        const previous = window.localStorage.getItem(SCANNER_OWNER_KEY)
        const changed = (previous && previous !== currentUserId) || hasPendingScannerBinding()
        if (changed) {
          setBindingWithdrawn(true)
          withdrawScannerBinding()
          await clearAllAdmissionData({ isCurrent: () => active })
          if (!active) return
          clearUploadRecovery(previous)
        }
        if (!active) return
        if (changed) window.localStorage.removeItem('hafapass_organization_id')
        completeScannerBinding(currentUserId)
        setBindingWithdrawn(false)
        setBoundUser(currentUserId)
        setBindingReady(true)
      } catch {
        // Keep the previous owner and cached routes inaccessible until a full purge succeeds.
        if (active) {
          try { withdrawScannerBinding() } catch { /* In-memory withdrawal still blocks access when storage fails. */ }
          setBindingWithdrawn(true)
          setBindingFailed(true)
        }
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
  const savedOwner = !bindingWithdrawn && !hasPendingScannerBinding()
    && (!bindingReady || (boundUser && boundUser === currentScannerOwner())) ? currentScannerOwner() : null
  if (!isLoaded && loadingFallback && savedOwner) return loadingFallback
  if (isLoaded && (!bindingReady || boundUser !== currentUserId)) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
  return typeof children === 'function' ? children({ scannerOwner: isLoaded ? currentUserId : savedOwner }) : children
}

export default function ClerkProviderWrapper({ children, loadingFallback }) {
  if (!clerkPubKey) {
    return <>{typeof children === 'function' ? children({ scannerOwner: currentScannerOwner() }) : children}</>
  }

  return (
    <ClerkProvider publishableKey={clerkPubKey} afterSignOutUrl="/">
      <AuthTokenSync loadingFallback={loadingFallback}>{children}</AuthTokenSync>
    </ClerkProvider>
  )
}

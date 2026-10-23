import { ClerkProvider, useAuth, useUser } from '@clerk/clerk-react'
import { Sentry } from '../monitoring'
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react'
import { setAuthTokenGetter } from '../api/client'
import { clerkAppearance } from '../config/clerkAppearance'
import { clearAllAdmissionData } from '../utils/admissionStore'
import { clearUploadRecovery } from '../utils/uploadRecovery'
import { captureScannerBindingContext, completeScannerBinding, currentScannerOwner, hasPendingScannerBinding, scannerBindingContextCurrent, scannerBindingRevision, scannerWithdrawalRevision, subscribeScannerBinding, withdrawScannerBinding } from '../utils/scannerAccountBinding'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AuthTokenSync({ children, loadingFallback, loadingFallbackOwner }) {
  useSyncExternalStore(subscribeScannerBinding, scannerBindingRevision)
  const initialFallbackOwner = useRef(currentScannerOwner())
  const verifiedWithdrawal = useRef(scannerWithdrawalRevision())
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
    if (!isLoaded || authLoaded === false || (authLoaded && userId !== currentUserId)) return
    Sentry.setUser(currentUserId ? { id: currentUserId } : null)
    let active = true
    let bindingContext
    const current = () => active && (!bindingContext || scannerBindingContextCurrent(bindingContext))
    setBindingReady(false)
    setBindingFailed(false)
    const prepareBinding = async () => {
      try {
        bindingContext = captureScannerBindingContext()
        if (!bindingContext) throw new Error('Scanner binding storage is unavailable')
        const previous = bindingContext.owner
        const changed = (previous && previous !== currentUserId) || hasPendingScannerBinding()
        if (changed) {
          setBindingWithdrawn(true)
          withdrawScannerBinding()
          bindingContext = captureScannerBindingContext()
          await clearAllAdmissionData({ isCurrent: current })
          if (!current()) return
          clearUploadRecovery(previous)
        }
        if (!current()) return
        if (changed) window.localStorage.removeItem('hafapass_organization_id')
        completeScannerBinding(currentUserId, { context: bindingContext })
        verifiedWithdrawal.current = scannerWithdrawalRevision()
        setBindingWithdrawn(false)
        setBoundUser(currentUserId)
        setBindingReady(true)
      } catch {
        // Keep the previous owner and cached routes inaccessible until a full purge succeeds.
        if (active) {
          if (!bindingContext || scannerBindingContextCurrent(bindingContext)) withdrawScannerBinding()
          setBindingWithdrawn(true)
          setBindingFailed(true)
        }
      }
    }
    void prepareBinding()
    return () => { active = false }
  }, [isLoaded, currentUserId, authLoaded, userId, sessionId, bindingAttempt])

  // Only the account-bound, verified door cache can operate before Clerk loads.
  // A definitive sign-out or account switch still purges that cache before routes mount.
  if (bindingFailed) return <div className="mx-auto max-w-md px-4 py-12" role="alert">
    <p>We could not clear this device’s saved event access. Your account is still locked for privacy. Please try again.</p>
    <button className="btn-primary mt-4" onClick={() => setBindingAttempt(attempt => attempt + 1)}>Retry account preparation</button>
  </div>
  const currentVerification = verifiedWithdrawal.current === scannerWithdrawalRevision()
  // Clerk resolving is not an account change. Decide this during render so
  // the existing routes never disappear while the layout effect confirms it.
  // A withdrawal (including a peer tab's) or unreadable storage must still lock.
  const bindingContext = captureScannerBindingContext()
  const unchangedBinding = currentVerification && !bindingWithdrawn && !hasPendingScannerBinding()
    && bindingContext && bindingContext.owner === currentUserId
    && authLoaded !== false && (!authLoaded || userId === currentUserId)
  const savedOwner = currentVerification && !bindingWithdrawn && !hasPendingScannerBinding()
    && (!bindingReady || (boundUser && boundUser === currentScannerOwner())) ? currentScannerOwner() : null
  if (!isLoaded && loadingFallback && savedOwner && savedOwner === (loadingFallbackOwner ?? initialFallbackOwner.current)) return loadingFallback
  if (isLoaded && !unchangedBinding && (!bindingReady || boundUser !== currentUserId)) return <div className="grid min-h-screen place-items-center" role="status">Preparing your account…</div>
  return typeof children === 'function' ? children({ scannerOwner: isLoaded ? (currentVerification && currentUserId === currentScannerOwner() ? currentUserId : null) : savedOwner }) : children
}

export default function ClerkProviderWrapper({ children, loadingFallback, loadingFallbackOwner }) {
  if (!clerkPubKey) {
    return <>{typeof children === 'function' ? children({ scannerOwner: currentScannerOwner() }) : children}</>
  }

  return (
    <ClerkProvider publishableKey={clerkPubKey} afterSignOutUrl="/" appearance={clerkAppearance}>
      <AuthTokenSync loadingFallback={loadingFallback} loadingFallbackOwner={loadingFallbackOwner}>{children}</AuthTokenSync>
    </ClerkProvider>
  )
}

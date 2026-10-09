import { useEffect, useState } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import { signInDestination } from '../utils/authDestination'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function SupportGate({ children }) {
  const { isSignedIn, isLoaded, userId } = useAuth()
  const location = useLocation()
  const [role, setRole] = useState(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (!isLoaded || !isSignedIn) return
    let current = true
    setLoading(true)
    setFailed(false)
    apiClient.get('/me').then(response => {
      if (current) setRole(response.data.role)
    }).catch(() => { if (current) { setRole(null); setFailed(true) } }).finally(() => { if (current) setLoading(false) })
    return () => { current = false }
  }, [isLoaded, isSignedIn, userId, attempt])

  if (isLoaded && !isSignedIn) return <Navigate to={signInDestination(location)} replace />
  if (!isLoaded || loading) return <div className="min-h-screen grid place-items-center" role="status" aria-label="Checking support access"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
  if (failed) return <div className="mx-auto max-w-md px-4 py-12" role="alert"><p>We could not verify your support access. Please try again.</p><button className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>Retry</button></div>
  if (!['support', 'admin'].includes(role)) return <Navigate to="/" replace />
  return children
}

export default function SupportRoute({ children, clerkConfigured = Boolean(clerkPubKey) }) {
  const location = useLocation()
  if (!clerkConfigured) return <Navigate to={signInDestination(location)} replace />
  return <SupportGate>{children}</SupportGate>
}

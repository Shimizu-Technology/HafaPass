import { useState, useEffect } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import { useTranslation } from 'react-i18next'
import PageLoading from './PageLoading'
import apiClient from '../api/client'
import { signInDestination } from '../utils/authDestination'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AdminGate({ children }) {
  const { isSignedIn, isLoaded, userId } = useAuth()
  const location = useLocation()
  const [role, setRole] = useState(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const { t } = useTranslation()

  useEffect(() => {
    if (!isLoaded) return
    if (!isSignedIn) {
      setRole(null)
      setLoading(false)
      return
    }
    let active = true
    setLoading(true)
    setFailed(false)
    apiClient.get('/me')
      .then(res => { if (active) setRole(res.data.role) })
      .catch(() => { if (active) { setRole(null); setFailed(true) } })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [isLoaded, isSignedIn, userId, attempt])

  if (!isLoaded) return <PageLoading label={t('buyer.layout.checkingAdmin')} />

  if (!isSignedIn) return <Navigate to={signInDestination(location)} replace />
  if (loading) return <PageLoading label={t('buyer.layout.checkingAdmin')} />
  if (failed) return <div className="mx-auto max-w-md px-4 py-12" role="alert"><p>We could not verify your administrator access. Please try again.</p><button className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>Retry</button></div>
  if (role !== 'admin') return <Navigate to="/" replace />

  return <>{children}</>
}

export default function AdminRoute({ children, clerkConfigured = Boolean(clerkPubKey) }) {
  if (!clerkConfigured && !import.meta.env.PROD) return <>{children}</>
  if (!clerkConfigured) return <p className="mx-auto max-w-md px-4 py-12" role="alert">Sign-in is temporarily unavailable. Please try again later.</p>
  return <AdminGate>{children}</AdminGate>
}

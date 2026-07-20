import { useEffect, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function SupportGate({ children }) {
  const { isSignedIn, isLoaded } = useAuth()
  const [role, setRole] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!isLoaded || !isSignedIn) return
    apiClient.get('/me').then(response => setRole(response.data.role)).catch(() => setRole(null)).finally(() => setLoading(false))
  }, [isLoaded, isSignedIn])

  if (!isLoaded || loading) return <div className="min-h-screen grid place-items-center"><Loader2 className="h-8 w-8 animate-spin text-brand-500" /></div>
  if (!isSignedIn) return <Navigate to="/sign-in" replace />
  if (!['support', 'admin'].includes(role)) return <Navigate to="/" replace />
  return children
}

export default function SupportRoute({ children, clerkConfigured = Boolean(clerkPubKey) }) {
  if (!clerkConfigured) return <Navigate to="/sign-in" replace />
  return <SupportGate>{children}</SupportGate>
}

import { useState, useEffect } from 'react'
import { Navigate } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function AdminGate({ children }) {
  const { isSignedIn, isLoaded } = useAuth()
  const [role, setRole] = useState(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!isLoaded || !isSignedIn) return
    apiClient.get('/me')
      .then(res => setRole(res.data.role))
      .catch(() => setRole(null))
      .finally(() => setLoading(false))
  }, [isLoaded, isSignedIn])

  if (!isLoaded || loading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
      </div>
    )
  }

  if (!isSignedIn) return <Navigate to="/sign-in" replace />
  if (role !== 'admin') return <Navigate to="/" replace />

  return <>{children}</>
}

export default function AdminRoute({ children }) {
  if (!clerkPubKey) return <>{children}</>
  return <AdminGate>{children}</AdminGate>
}

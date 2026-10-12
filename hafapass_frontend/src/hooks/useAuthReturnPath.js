import { useLayoutEffect, useRef } from 'react'
import { useLocation } from 'react-router-dom'
import { useAuth } from '@clerk/clerk-react'
import { clearAuthReturnIntent, createAuthReturnIntent, readAuthReturnIntent, storeAuthReturnIntent } from '../utils/authDestination'

export default function useAuthReturnPath(entryPath) {
  const location = useLocation()
  const { isSignedIn } = useAuth()
  const journey = useRef(null)
  const visit = JSON.stringify([location.key, location.pathname, location.search])
  if (journey.current?.visit !== visit) {
    const params = new URLSearchParams(location.search)
    const freshEntry = location.pathname.replace(/\/$/, '') === entryPath
    const previous = journey.current?.intent
    // Clerk rewrites its nested paths without the app's query. Capture each
    // fresh entry, but retain that attempt through factors and verification.
    const intent = freshEntry || params.has('returnTo')
      ? createAuthReturnIntent(params.get('returnTo'))
      : previous || readAuthReturnIntent() || createAuthReturnIntent('/')
    journey.current = { visit, intent }
  }
  const intent = journey.current.intent
  useLayoutEffect(() => {
    storeAuthReturnIntent(intent)
    if (isSignedIn) clearAuthReturnIntent(intent.id)
  }, [intent, isSignedIn])
  return intent.destination
}

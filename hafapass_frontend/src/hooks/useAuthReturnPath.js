import { useLayoutEffect, useRef } from 'react'
import { useLocation } from 'react-router-dom'
import { clearAuthReturnIntent, createAuthReturnIntent, readAuthReturnIntent, storeAuthReturnIntent } from '../utils/authDestination'

export default function useAuthReturnPath(entryPath) {
  const location = useLocation()
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
  }, [intent])
  return intent.destination
}

export function useAuthReturnIntentCleanup() {
  const location = useLocation()
  const inAuthFlow = /^\/sign-(in|up)(?:\/|$)/.test(location.pathname)
  const intentId = inAuthFlow ? null : readAuthReturnIntent()?.id
  // SDK sign-in can precede account binding and temporarily unmount App.
  // Only committed navigation out of the auth routes completes this attempt.
  useLayoutEffect(() => {
    if (intentId) clearAuthReturnIntent(intentId)
  }, [intentId, location.key, location.pathname])
}

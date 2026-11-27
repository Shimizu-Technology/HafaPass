import { useEffect, useRef, useState } from 'react'
import { useLocation } from 'react-router-dom'
import { capturePostHogPageView, initPostHog } from '../utils/posthog'

export function PostHogProvider({ children }) {
  useState(() => initPostHog())
  return children
}

export function PostHogPageView() {
  const location = useLocation()
  const lastCapturedUrlRef = useRef(null)

  useEffect(() => {
    const currentKey = `${location.pathname}${location.search}${location.hash}`
    if (lastCapturedUrlRef.current === currentKey) return
    if (capturePostHogPageView(location)) {
      lastCapturedUrlRef.current = currentKey
    }
  }, [location])

  return null
}

export default PostHogProvider

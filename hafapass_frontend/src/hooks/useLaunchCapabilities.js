import { useCallback, useEffect, useState } from 'react'
import { loadPublicConfig } from '../api/publicConfig'

// `status` separates "the platform has this off" from "we couldn't ask yet",
// so a slow or failed /config never reads as a disabled feature.
export function useLaunchCapabilityState() {
  const [state, setState] = useState({ capabilities: {}, status: 'loading' })
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let current = true
    loadPublicConfig()
      .then(response => { if (current) setState({ capabilities: response.data.launch_capabilities || {}, status: 'ready' }) })
      .catch(() => { if (current) setState(previous => ({ ...previous, status: 'error' })) })
    return () => { current = false }
  }, [attempt])
  const retry = useCallback(() => {
    setState(previous => ({ ...previous, status: 'loading' }))
    setAttempt(value => value + 1)
  }, [])
  return { ...state, retry }
}

export default function useLaunchCapabilities() {
  return useLaunchCapabilityState().capabilities
}

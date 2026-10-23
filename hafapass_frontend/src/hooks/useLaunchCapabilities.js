import { useEffect, useState } from 'react'
import { loadPublicConfig } from '../api/publicConfig'

export default function useLaunchCapabilities() {
  const [capabilities, setCapabilities] = useState({})
  useEffect(() => {
    let current = true
    loadPublicConfig().then(response => { if (current) setCapabilities(response.data.launch_capabilities || {}) }).catch(() => {})
    return () => { current = false }
  }, [])
  return capabilities
}

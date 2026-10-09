import { useEffect, useState } from 'react'
import apiClient from '../api/client'

export default function useLaunchCapabilities() {
  const [capabilities, setCapabilities] = useState({})
  useEffect(() => {
    let current = true
    apiClient.get('/config').then(response => { if (current) setCapabilities(response.data.launch_capabilities || {}) }).catch(() => {})
    return () => { current = false }
  }, [])
  return capabilities
}

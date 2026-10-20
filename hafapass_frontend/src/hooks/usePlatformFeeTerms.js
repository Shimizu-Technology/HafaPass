import { useCallback, useEffect, useState } from 'react'
import apiClient from '../api/client'
import { parseFeeTerms } from '../utils/feeTerms'

// Current platform fee terms from /config. status is loading, ready or error;
// an error never falls back to a guessed fee.
export default function usePlatformFeeTerms() {
  const [state, setState] = useState({ status: 'loading', terms: null })
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let current = true
    apiClient.get('/config')
      .then(response => {
        if (!current) return
        const terms = parseFeeTerms(response.data)
        setState({ status: terms ? 'ready' : 'error', terms })
      })
      .catch(() => { if (current) setState({ status: 'error', terms: null }) })
    return () => { current = false }
  }, [attempt])
  const retry = useCallback(() => {
    setState({ status: 'loading', terms: null })
    setAttempt(value => value + 1)
  }, [])
  return { ...state, retry }
}

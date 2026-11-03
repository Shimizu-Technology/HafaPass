import { createContext, useContext } from 'react'

// Lets the payment form ask StripeProvider for a fresh Stripe load after its
// card element fails to load.
export const StripeRetryContext = createContext(null)
export const useStripeRetry = () => useContext(StripeRetryContext)

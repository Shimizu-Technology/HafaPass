import { useLocation } from 'react-router-dom'
import { safeReturnPath } from '../utils/authDestination'
import { SignUp } from '@clerk/clerk-react'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

export default function SignUpPage() {
  const location = useLocation()
  const returnTo = safeReturnPath(new URLSearchParams(location.search).get('returnTo'))
  if (!clerkPubKey) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-neutral-50">
        <div className="text-center p-8 bg-white rounded-xl shadow-sm max-w-md">
          <h1 className="text-2xl font-bold text-neutral-800 mb-2">Sign Up</h1>
          <p className="text-neutral-500">Account registration is temporarily unavailable. Please try again later.</p>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-neutral-50">
      <div className="flex items-center gap-2 mb-6">
        <div className="w-9 h-9 rounded-xl bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center shadow-md">
          <span className="text-white font-bold text-sm">H</span>
        </div>
        <span className="text-xl font-bold text-neutral-800">HafaPass</span>
      </div>
      <SignUp
        routing="path"
        path="/sign-up"
        signInUrl={`/sign-in?returnTo=${encodeURIComponent(returnTo)}`}
        forceRedirectUrl={returnTo}
      />
    </div>
  )
}

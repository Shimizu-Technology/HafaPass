import HafaPassMark from '../components/HafaPassMark'
import useAuthReturnPath from '../hooks/useAuthReturnPath'
import { SignIn } from '@clerk/clerk-react'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

export default function SignInPage() {
  if (!clerkPubKey) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-neutral-50">
        <div className="text-center p-8 bg-white rounded-xl shadow-sm max-w-md">
          <h1 className="text-2xl font-bold text-neutral-800 mb-2">Sign In</h1>
          <p className="text-neutral-500">Sign-in is temporarily unavailable. Please try again later.</p>
        </div>
      </div>
    )
  }

  return <SignInJourney />
}

function SignInJourney() {
  const returnTo = useAuthReturnPath('/sign-in')
  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-surface px-4 py-8">
      <div className="flex items-center gap-2 mb-6">
        <div className="w-9 h-9 rounded-xl bg-brand-700 flex items-center justify-center shadow-md">
          <HafaPassMark className="h-5 w-5 text-white" />
        </div>
        <span className="text-xl font-bold text-neutral-800">HafaPass</span>
      </div>
      <SignIn
        routing="path"
        path="/sign-in"
        signUpUrl={`/sign-up?returnTo=${encodeURIComponent(returnTo)}`}
        forceRedirectUrl={returnTo}
      />
    </div>
  )
}

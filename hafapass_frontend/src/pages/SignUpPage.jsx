import { SignUp } from '@clerk/clerk-react'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

export default function SignUpPage() {
  if (!clerkPubKey) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-50">
        <div className="text-center p-8 bg-white rounded-lg shadow-md max-w-md">
          <h1 className="text-2xl font-bold text-gray-800 mb-2">Sign Up</h1>
          <p className="text-gray-500">Authentication is not configured. Set VITE_CLERK_PUBLISHABLE_KEY to enable sign up.</p>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-50">
      <SignUp
        routing="path"
        path="/sign-up"
        signInUrl="/sign-in"
        forceRedirectUrl="/"
      />
    </div>
  )
}

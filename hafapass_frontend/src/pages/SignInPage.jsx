import { useTranslation } from 'react-i18next'
import useAuthReturnPath from '../hooks/useAuthReturnPath'
import { SignIn } from '@clerk/clerk-react'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

export default function SignInPage() {
  const { t } = useTranslation()
  if (!clerkPubKey) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-neutral-50">
        <div className="text-center p-8 bg-white rounded-xl shadow-sm max-w-md">
          <h1 className="text-2xl font-bold text-neutral-800 mb-2">{t('buyerDiscovery.signIn.signIn')}</h1>
          <p role="alert" className="text-neutral-600">{t('buyerDiscovery.signIn.signInIsTemporarilyUnavailablePleaseTry')}</p>
        </div>
      </div>
    )
  }

  return <SignInJourney />
}

function SignInJourney() {
  const returnTo = useAuthReturnPath('/sign-in')
  return (
    <div className="min-h-[calc(100dvh-4rem)] flex flex-col items-center justify-center bg-surface px-4 py-8">
      <SignIn
        routing="path"
        path="/sign-in"
        signUpUrl={`/sign-up?returnTo=${encodeURIComponent(returnTo)}`}
        forceRedirectUrl={returnTo}
      />
    </div>
  )
}

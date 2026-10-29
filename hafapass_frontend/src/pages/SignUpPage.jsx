import { useTranslation } from 'react-i18next'
import SEO from '../components/SEO'
import useAuthReturnPath from '../hooks/useAuthReturnPath'
import { SignUp } from '@clerk/clerk-react'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

export default function SignUpPage() {
  const { t } = useTranslation()
  return <>
    <SEO title={t('buyerDiscovery.signUp.documentTitle')} noIndex />
    {!clerkPubKey ? (
      <div className="min-h-[calc(100dvh-4rem)] flex items-center justify-center bg-neutral-50 px-4 py-8">
        <div className="text-center p-8 bg-white rounded-xl shadow-sm max-w-md">
          <h1 className="text-2xl font-bold text-neutral-800 mb-2">{t('buyerDiscovery.signUp.signUp')}</h1>
          <p className="text-neutral-500">{t('buyerDiscovery.signUp.accountRegistrationIsTemporarilyUnavailablePleaseTry')}</p>
        </div>
      </div>
    ) : <SignUpJourney />}
  </>
}

function SignUpJourney() {
  const returnTo = useAuthReturnPath('/sign-up')
  return (
    <div className="min-h-[calc(100dvh-4rem)] flex flex-col items-center justify-center bg-surface px-4 py-8">
      <SignUp
        routing="path"
        path="/sign-up"
        signInUrl={`/sign-in?returnTo=${encodeURIComponent(returnTo)}`}
        forceRedirectUrl={returnTo}
      />
    </div>
  )
}

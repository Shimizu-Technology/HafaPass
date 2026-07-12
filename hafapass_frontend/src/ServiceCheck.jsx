import ClerkProviderWrapper from './components/ClerkProviderWrapper'
import App from './App'
import { useBackendAvailability } from './hooks/useBackendAvailability'
import PrivatePreviewPage from './pages/PrivatePreviewPage'

const API_BASE_URL = (import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1').replace(/\/$/, '')
const HEALTH_URL = `${API_BASE_URL}/health`

export default function ServiceCheck() {
  const { status, retry } = useBackendAvailability(HEALTH_URL)

  if (status === 'checking') {
    return (
      <main className="flex min-h-screen items-center justify-center bg-neutral-950 px-6 text-center" role="status">
        <div>
          <div className="mx-auto h-10 w-10 animate-spin rounded-full border-4 border-white/10 border-t-brand-400" />
          <p className="mt-4 font-semibold text-white/70">Checking HåfaPass services…</p>
        </div>
      </main>
    )
  }

  if (status === 'unavailable') return <PrivatePreviewPage onRetry={retry} />
  return <ClerkProviderWrapper><App /></ClerkProviderWrapper>
}

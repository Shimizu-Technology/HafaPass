import './i18n'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { HelmetProvider } from 'react-helmet-async'
import './index.css'
import ServiceCheck from './ServiceCheck.jsx'
import { initializeMonitoring, Sentry } from './monitoring'
import ErrorFallback from './components/ErrorFallback'

initializeMonitoring()

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <HelmetProvider>
      <BrowserRouter>
        <Sentry.ErrorBoundary fallback={({ error, resetError }) => <ErrorFallback error={error} resetError={resetError} />}>
          <ServiceCheck />
        </Sentry.ErrorBoundary>
      </BrowserRouter>
    </HelmetProvider>
  </StrictMode>,
)

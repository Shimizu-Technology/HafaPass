import * as Sentry from '@sentry/react'

export function initializeMonitoring() {
  const dsn = import.meta.env.VITE_SENTRY_DSN
  if (!dsn) return

  Sentry.init({
    dsn,
    enabled: import.meta.env.PROD || import.meta.env.VITE_SENTRY_ENABLE_DEV === 'true',
    environment: import.meta.env.VITE_SENTRY_ENVIRONMENT || import.meta.env.MODE,
    release: import.meta.env.VITE_SENTRY_RELEASE,
    sendDefaultPii: false,
    sampleRate: 1,
    tracesSampleRate: Number.parseFloat(import.meta.env.VITE_SENTRY_TRACES_SAMPLE_RATE || '0.1'),
    integrations: [Sentry.browserTracingIntegration()],
    beforeSend(event) {
      const message = event.exception?.values?.[0]?.value || ''
      if (message.includes('ResizeObserver')) return null
      if (message.includes('chrome-extension://')) return null
      return event
    },
  })
}

export { Sentry }

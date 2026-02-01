/**
 * Shows a colored banner when not in live mode.
 * - simulate: yellow — orders auto-complete, no real charges
 * - test: blue — real Stripe sandbox, test cards only
 * - live: nothing shown
 */
export default function PaymentModeBanner({ mode }) {
  if (!mode || mode === 'live') return null

  const config = {
    simulate: {
      bg: 'bg-amber-50 border-amber-200',
      icon: 'text-amber-600',
      text: 'text-amber-800',
      label: 'Simulate Mode',
      description: 'Payments are simulated. No real charges will be made.',
    },
    test: {
      bg: 'bg-blue-50 border-blue-200',
      icon: 'text-blue-600',
      text: 'text-blue-800',
      label: 'Test Mode (Stripe Sandbox)',
      description: 'Using Stripe test environment. Use card 4242 4242 4242 4242 to test.',
    },
  }

  const c = config[mode]
  if (!c) return null

  return (
    <div className={`${c.bg} border rounded-lg p-3 mb-4 flex items-start gap-3`}>
      <svg className={`w-5 h-5 ${c.icon} flex-shrink-0 mt-0.5`} fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2}
          d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      <div>
        <p className={`${c.text} text-sm font-semibold`}>{c.label}</p>
        <p className={`${c.text} text-xs opacity-80`}>{c.description}</p>
      </div>
    </div>
  )
}

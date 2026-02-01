import { AlertTriangle, TestTube, CreditCard } from 'lucide-react'

export default function PaymentModeBanner({ mode }) {
  if (mode === 'live') return null

  if (mode === 'simulate') {
    return (
      <div className="flex items-center gap-2.5 bg-amber-50 border border-amber-200/60 rounded-xl px-4 py-2.5 mb-4">
        <AlertTriangle className="w-4 h-4 text-amber-600 shrink-0" />
        <p className="text-sm text-amber-700">
          <span className="font-medium">Simulate Mode</span> - No real payments are processed. Tickets are issued immediately.
        </p>
      </div>
    )
  }

  if (mode === 'test') {
    return (
      <div className="flex items-center gap-2.5 bg-blue-50 border border-blue-200/60 rounded-xl px-4 py-2.5 mb-4">
        <TestTube className="w-4 h-4 text-blue-600 shrink-0" />
        <p className="text-sm text-blue-700">
          <span className="font-medium">Test Mode</span> - Use card <span className="font-mono text-xs bg-blue-100 px-1.5 py-0.5 rounded">4242 4242 4242 4242</span> with any future date.
        </p>
      </div>
    )
  }

  return null
}

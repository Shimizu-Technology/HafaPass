import { Link } from 'react-router-dom'

// Small, persistent, non-blocking banner shown across all routes only when
// preview-only demo mode (VITE_HAFAPASS_DEMO_DATA=1) is active.
export default function DemoPreviewBanner() {
  return (
    <div
      role="status"
      data-testid="demo-preview-banner"
      className="border-b border-amber-300/80 bg-amber-50 px-3 py-1.5 text-center text-xs font-medium text-amber-950"
    >
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-center gap-x-3 gap-y-1">
        <span className="inline-flex items-center gap-1.5 font-semibold">
          <span aria-hidden="true" className="h-2 w-2 rounded-full bg-amber-600" />
          Demo preview · fictional data
        </span>
        <span aria-hidden="true" className="hidden text-amber-700/60 sm:inline">|</span>
        <span className="inline-flex flex-wrap items-center justify-center gap-x-3 gap-y-0.5 text-amber-900">
          <Link to="/orders/demo-copa-2027/confirmation" className="underline underline-offset-2 hover:text-amber-950">
            Sample confirmation
          </Link>
          <Link to="/tickets/demo-ticket-copa-adult-1?order=demo-copa-2027" className="underline underline-offset-2 hover:text-amber-950">
            Sample ticket
          </Link>
        </span>
      </div>
    </div>
  )
}

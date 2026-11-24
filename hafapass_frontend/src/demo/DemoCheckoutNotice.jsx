import { Link } from 'react-router-dom'

// Preview-only checkout gate rendered in place of Stripe payment submission
// when VITE_HAFAPASS_DEMO_DATA === '1'.
export default function DemoCheckoutNotice() {
  return (
    <div
      role="status"
      data-testid="demo-payments-off-notice"
      className="mt-6 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950"
    >
      <p className="font-semibold">Demo preview: payments are off</p>
      <p className="mt-1 text-amber-900">
        This preview uses fictional data. Stripe checkout is disabled and no real order or charge will be created.
      </p>
      <div className="mt-3 grid grid-cols-2 gap-2">
        <Link
          to="/orders/demo-copa-2027/confirmation"
          className="btn-secondary min-h-11 w-full !px-3 !py-2 text-center text-sm leading-tight"
        >
          View sample confirmation
        </Link>
        <Link
          to="/tickets/demo-ticket-copa-adult-1?order=demo-copa-2027"
          className="btn-secondary min-h-11 w-full !px-3 !py-2 text-center text-sm leading-tight"
        >
          View sample ticket
        </Link>
      </div>
    </div>
  )
}

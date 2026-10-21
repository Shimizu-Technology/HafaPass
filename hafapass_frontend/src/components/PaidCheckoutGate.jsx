import { useAccountRole } from '../utils/workspace'

function AdminOnly({ children }) {
  const role = useAccountRole()
  if (role === 'admin') return children
  return <div role="status" className="mt-5 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
    <p className="font-semibold">Paid ticket sales open soon</p>
    <p className="mt-1">You can’t buy paid tickets for this event yet. Free tickets work as usual.</p>
  </div>
}

// While production payments are in Stripe test mode (`/config`
// paid_checkout_admin_only) only platform admins may start a paid checkout;
// the API refuses everyone else. `active` is that flag for a paid selection.
// The role comes from the navbar's account lookup, so admins unlock as soon
// as it loads. Free selections pass `active={false}` and stay open.
export default function PaidCheckoutGate({ active, children }) {
  return active ? <AdminOnly>{children}</AdminOnly> : children
}

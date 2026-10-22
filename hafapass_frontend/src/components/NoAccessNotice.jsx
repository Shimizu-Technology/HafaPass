import { Lock } from 'lucide-react'
import { Link } from 'react-router-dom'

// The calm state for a page someone's role does not include. It names what
// to do next instead of showing an error.
export default function NoAccessNotice({ title = 'You don’t have access to this page', detail, children, className = '' }) {
  return (
    <section role="status" className={`rounded-2xl border border-neutral-200 bg-white p-6 ${className}`}>
      <Lock aria-hidden="true" className="h-6 w-6 text-brand-600" />
      <h2 className="mt-3 text-lg font-semibold text-neutral-900">{title}</h2>
      {detail && <p className="mt-1 text-sm text-neutral-600">{detail}</p>}
      <p className="mt-1 text-sm text-neutral-600">Ask your organization owner if you need it.</p>
      <div className="mt-4 flex flex-wrap gap-3">
        {children}
        <Link to="/dashboard" className="btn-secondary !px-4 !py-2.5 text-sm">Back to dashboard</Link>
      </div>
    </section>
  )
}

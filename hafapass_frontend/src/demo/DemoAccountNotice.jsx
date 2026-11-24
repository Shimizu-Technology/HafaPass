import { Link } from 'react-router-dom'
export default function DemoAccountNotice() {
  return <div className="mx-auto max-w-lg px-4 py-12"><div className="card p-6">
    <h1 className="font-display text-2xl font-bold">Your tickets in this preview</h1>
    <p className="mt-3 text-neutral-600">Sign-in is off in this demo preview. Browse events or open the sample ticket.</p>
    <div className="mt-5 flex flex-wrap gap-3"><Link className="btn-primary" to="/tickets/demo-ticket-copa-adult-1?order=demo-copa-2027">Sample ticket</Link><Link className="btn-secondary" to="/orders/recover">Find my tickets</Link><Link className="btn-secondary" to="/events">Browse events</Link></div>
  </div></div>
}

import { useState } from 'react'
import { Link } from 'react-router-dom'
import { CheckCircle, Mail, Search } from 'lucide-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'

export default function OrderRecoveryPage() {
  const [reference, setReference] = useState('')
  const [email, setEmail] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)

  async function handleSubmit(event) {
    event.preventDefault()
    setSubmitting(true)
    try {
      await apiClient.post('/order_lookup', { reference: reference.trim(), buyer_email: email.trim() })
      setSubmitted(true)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="min-h-[70vh] bg-neutral-50 px-4 py-12">
      <SEO title="Find Your Order" />
      <div className="mx-auto max-w-md">
        <div className="mb-6 text-center">
          <Search className="mx-auto mb-3 h-9 w-9 text-brand-600" />
          <h1 className="text-3xl font-bold tracking-tight text-neutral-950">Find your order</h1>
          <p className="mt-2 text-neutral-500">Enter the reference from your receipt and the email used at checkout.</p>
        </div>
        <div className="card p-6">
          {submitted ? (
            <div className="text-center">
              <CheckCircle className="mx-auto mb-3 h-10 w-10 text-emerald-600" />
              <h2 className="font-semibold text-neutral-950">Check your email</h2>
              <p className="mt-2 text-sm text-neutral-600">If those details match an order, we sent a new secure access link. The same message appears whether or not a match exists.</p>
              <button onClick={() => setSubmitted(false)} className="mt-5 text-sm font-semibold text-brand-600">Try another order</button>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label htmlFor="reference" className="mb-1.5 block text-sm font-medium text-neutral-700">Order reference</label>
                <input id="reference" className="input uppercase" value={reference} onChange={event => setReference(event.target.value)} placeholder="HP-AB12CD34" required />
              </div>
              <div>
                <label htmlFor="recovery-email" className="mb-1.5 block text-sm font-medium text-neutral-700">Email address</label>
                <input id="recovery-email" type="email" className="input" value={email} onChange={event => setEmail(event.target.value)} placeholder="you@example.com" required />
              </div>
              <button disabled={submitting} className="btn-primary flex w-full items-center justify-center gap-2"><Mail className="h-4 w-4" />{submitting ? 'Sending…' : 'Email secure link'}</button>
            </form>
          )}
        </div>
        <p className="mt-5 text-center text-sm text-neutral-500">Have an account? <Link to="/sign-in" className="font-semibold text-brand-600">Sign in</Link></p>
      </div>
    </div>
  )
}

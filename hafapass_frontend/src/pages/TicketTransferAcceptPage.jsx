import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { CheckCircle, Loader2, AlertTriangle } from 'lucide-react'
import apiClient from '../api/client'

export default function TicketTransferAcceptPage() {
  const [searchParams] = useSearchParams()
  const [status, setStatus] = useState('accepting')
  const [message, setMessage] = useState('Accepting your ticket…')

  useEffect(() => {
    const token = searchParams.get('token')
    if (!token) {
      setStatus('error')
      setMessage('This transfer link is incomplete.')
      return
    }

    apiClient.post('/me/ticket_transfers/accept', { token })
      .then(() => { setStatus('accepted'); setMessage('The ticket is now in your HafaPass account. The previous entry code has been disabled.') })
      .catch(err => { setStatus('error'); setMessage(err.response?.data?.error || 'This transfer could not be accepted.') })
  }, [searchParams])

  return <div className="mx-auto max-w-md px-4 py-20"><div className="card p-8 text-center">
    {status === 'accepting' && <Loader2 className="mx-auto mb-4 h-10 w-10 animate-spin text-brand-500" />}
    {status === 'accepted' && <CheckCircle className="mx-auto mb-4 h-10 w-10 text-emerald-500" />}
    {status === 'error' && <AlertTriangle className="mx-auto mb-4 h-10 w-10 text-red-500" />}
    <h1 className="text-xl font-bold text-neutral-900">{status === 'accepted' ? 'Ticket accepted' : status === 'error' ? 'Transfer unavailable' : 'Accepting ticket'}</h1>
    <p className="mt-2 text-sm text-neutral-600">{message}</p>
    {status !== 'accepting' && <Link to="/my-tickets" className="btn-primary mt-6 inline-flex">View my tickets</Link>}
  </div></div>
}

import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { CheckCircle, Loader2, AlertTriangle } from 'lucide-react'
import apiClient from '../api/client'

export default function TicketTransferAcceptPage() {
  const { t } = useTranslation()
  const [searchParams] = useSearchParams()
  const [status, setStatus] = useState('accepting')
  const [messageKey, setMessageKey] = useState('acceptingYourTicket')
  const [errorMessage, setErrorMessage] = useState(null)

  useEffect(() => {
    const token = searchParams.get('token')
    if (!token) {
      setStatus('error')
      setMessageKey('thisTransferLinkIsIncomplete')
      return
    }

    apiClient.post('/me/ticket_transfers/accept', { token })
      .then(() => { setStatus('accepted'); setMessageKey('theTicketIsNowInYourHFaPass') })
      .catch(err => { setStatus('error'); setMessageKey('thisTransferCouldNotBeAccepted'); setErrorMessage(err.response?.data?.error || null) })
  }, [searchParams])

  return <div className="mx-auto max-w-md px-4 py-20"><div className="card p-8 text-center">
    {status === 'accepting' && <Loader2 className="mx-auto mb-4 h-10 w-10 animate-spin text-brand-500" />}
    {status === 'accepted' && <CheckCircle className="mx-auto mb-4 h-10 w-10 text-emerald-500" />}
    {status === 'error' && <AlertTriangle className="mx-auto mb-4 h-10 w-10 text-red-500" />}
    <h1 className="text-xl font-bold text-neutral-900">{status === 'accepted' ? t('buyerAccount.ticketTransferAcceptPage.ticketAccepted') : status === 'error' ? t('buyerAccount.ticketTransferAcceptPage.transferUnavailable') : t('buyerAccount.ticketTransferAcceptPage.acceptingTicket')}</h1>
    <p className="mt-2 text-sm text-neutral-600">{errorMessage || t(`buyerAccount.ticketTransferAcceptPage.${messageKey}`)}</p>
    {status !== 'accepting' && <Link to="/my-tickets" className="btn-primary mt-6 inline-flex">{t('buyerAccount.ticketTransferAcceptPage.viewMyTickets')}</Link>}
  </div></div>
}

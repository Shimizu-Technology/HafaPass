import { Trans, useTranslation } from 'react-i18next'
import { useState } from 'react'
import Dialog from './Dialog'
import { formatEventDateTime } from '../utils/eventTime'

// A sent-but-unaccepted transfer on the holder's ticket, with a confirmed
// cancel. `onCancel` performs the request; `onSettled` refreshes the list
// whether the cancel succeeded or the transfer had already ended.
export default function PendingTransfer({ transfer, onCancel, onSettled }) {
  const { t } = useTranslation()
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const expires = formatEventDateTime(transfer.expires_at, 'Pacific/Guam')

  async function cancel() {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      await onCancel()
      setConfirming(false)
      onSettled?.({ status: 'cancelled', message: t('buyerAccount.pendingTransfer.transferCancelledYourTicketStaysWithYou') })
    } catch (err) {
      const status = err.response?.status
      if (status === 404 || status === 422) {
        // Accepted, expired or cancelled elsewhere while this page was open.
        setConfirming(false)
        onSettled?.({ status: 'ended', message: t('buyerAccount.pendingTransfer.thisTransferAlreadyEndedSoThereWasNothing') })
      } else {
        setError(err.response?.data?.error || t('buyerAccount.pendingTransfer.weCouldNotCancelTheTransferCheckYour'))
      }
    } finally {
      setBusy(false)
    }
  }

  return <div className="mt-1">
    <p className="text-xs text-amber-800">
      <span className="font-semibold">{t('buyerAccount.pendingTransfer.transferPending')}</span>
      {' · '}<Trans t={t} i18nKey="buyerAccount.pendingTransfer.sentToRecipient" values={{ email: transfer.recipient_email }} components={{ recipient: <span className="break-all" /> }} />
      {expires && <>{' · '}{t('buyerAccount.pendingTransfer.expires', { date: expires })}</>}
    </p>
    <button type="button" onClick={() => { setError(null); setConfirming(true) }}
      className="mt-1 min-h-11 rounded-lg px-2 text-xs font-semibold text-red-700 transition-[background-color,transform] duration-150 ease-out-strong active:scale-[0.97] hover:bg-red-50">{t('buyerAccount.pendingTransfer.cancelTransfer')}</button>
    {confirming && <Dialog labelledBy={`cancel-transfer-${transfer.id}`} onClose={() => setConfirming(false)} busy={busy} className="max-w-md">
      <h2 id={`cancel-transfer-${transfer.id}`} className="text-lg font-semibold text-neutral-900">{t('buyerAccount.pendingTransfer.cancelThisTransfer')}</h2>
      <p className="mt-2 text-sm text-neutral-600"><Trans t={t} i18nKey="buyerAccount.pendingTransfer.cancelMessage" values={{ email: transfer.recipient_email }} components={{ recipient: <strong className="break-all text-neutral-900" /> }} /></p>
      {error && <p role="alert" className="mt-3 text-sm text-red-700">{error}</p>}
      <div className="mt-6 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button type="button" className="btn-secondary min-h-11 px-5" onClick={() => setConfirming(false)} disabled={busy}>{t('buyerAccount.pendingTransfer.keepTransfer')}</button>
        <button type="button" className="btn-danger min-h-11 px-5" onClick={cancel} disabled={busy}>{busy ? t('buyerAccount.pendingTransfer.cancelling') : t('buyerAccount.pendingTransfer.cancelTransfer')}</button>
      </div>
    </Dialog>}
  </div>
}

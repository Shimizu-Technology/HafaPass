import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, CheckCircle, XCircle, ClipboardList } from 'lucide-react'
import apiClient from '../api/client'

export default function WaitlistForm({ event, ticketTypes = [] }) {
  const { t } = useTranslation()
  const [form, setForm] = useState({ email: '', name: '', phone: '', ticket_type_id: '', quantity: 1 })
  const [submitting, setSubmitting] = useState(false)
  const [result, setResult] = useState(null) // { position, status } or null
  const [error, setError] = useState(null)
  const [checkEmail, setCheckEmail] = useState('')
  const [checking, setChecking] = useState(false)
  const [existingEntries, setExistingEntries] = useState(null)

  const soldOutTypes = ticketTypes.filter(tt => (tt.quantity_available - tt.quantity_sold) <= 0)

  const handleSubmit = async (e) => {
    e.preventDefault()
    setSubmitting(true)
    setError(null)
    try {
      const params = { ...form }
      if (!params.ticket_type_id) delete params.ticket_type_id
      const res = await apiClient.post(`/events/${event.slug}/waitlist`, params)
      setResult(res.data)
    } catch (err) {
      setError(err.response?.data?.errors?.join(', ') || 'Failed to join waitlist')
    }
    setSubmitting(false)
  }

  const handleCheck = async () => {
    if (!checkEmail) return
    setChecking(true)
    try {
      const res = await apiClient.get(`/events/${event.slug}/waitlist/status`, { params: { email: checkEmail } })
      setExistingEntries(res.data.entries)
    } catch {
      setExistingEntries([])
    }
    setChecking(false)
  }

  const handleLeave = async () => {
    if (!checkEmail || !confirm('Remove yourself from the waitlist?')) return
    try {
      await apiClient.delete(`/events/${event.slug}/waitlist`, { params: { email: checkEmail } })
      setExistingEntries([])
      setResult(null)
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to leave waitlist')
    }
  }

  if (result) {
    return (
      <div className="card p-6 text-center">
        <CheckCircle className="w-12 h-12 text-brand-500 mx-auto mb-3" />
        <h3 className="text-lg font-semibold text-neutral-900 mb-1">{t('waitlist.onWaitlist')}</h3>
        <p className="text-neutral-600">{t('waitlist.positionInLine', { position: result.position })}</p>
        <p className="text-sm text-neutral-500 mt-2">{t('waitlist.willEmail', { email: result.email })}</p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {/* Join Waitlist Form */}
      <div className="card p-5">
        <div className="flex items-center gap-2 mb-4">
          <ClipboardList className="w-5 h-5 text-brand-500" />
          <h3 className="text-lg font-semibold text-neutral-900">{t('waitlist.joinTitle')}</h3>
        </div>
        <p className="text-sm text-neutral-500 mb-4">{t('waitlist.getNotified')}</p>

        <form onSubmit={handleSubmit} className="space-y-3">
          <input
            type="text"
            placeholder={t('waitlist.yourName')}
            value={form.name}
            onChange={(e) => setForm(f => ({ ...f, name: e.target.value }))}
            className="input"
            required
          />
          <input
            type="email"
            placeholder={t('waitlist.emailAddress')}
            value={form.email}
            onChange={(e) => setForm(f => ({ ...f, email: e.target.value }))}
            className="input"
            required
          />
          <input
            type="tel"
            placeholder={t('waitlist.phone')}
            value={form.phone}
            onChange={(e) => setForm(f => ({ ...f, phone: e.target.value }))}
            className="input"
          />

          {soldOutTypes.length > 0 && (
            <select
              value={form.ticket_type_id}
              onChange={(e) => setForm(f => ({ ...f, ticket_type_id: e.target.value }))}
              className="input"
            >
              <option value="">{t('waitlist.anyTicketType')}</option>
              {soldOutTypes.map(tt => (
                <option key={tt.id} value={tt.id}>{tt.name}</option>
              ))}
            </select>
          )}

          <div className="flex items-center gap-2">
            <label className="text-sm text-neutral-600">{t('waitlist.quantity')}:</label>
            <select
              value={form.quantity}
              onChange={(e) => setForm(f => ({ ...f, quantity: parseInt(e.target.value) }))}
              className="input !w-20"
            >
              {[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(n => (
                <option key={n} value={n}>{n}</option>
              ))}
            </select>
          </div>

          {error && (
            <div className="flex items-center gap-2 text-sm text-red-600">
              <XCircle className="w-4 h-4 shrink-0" />
              {error}
            </div>
          )}

          <button type="submit" disabled={submitting} className="w-full btn-primary !py-3 gap-2">
            {submitting ? <Loader2 className="w-4 h-4 animate-spin" /> : <ClipboardList className="w-4 h-4" />}
            {t('waitlist.join')}
          </button>
        </form>
      </div>

      {/* Check Status */}
      <div className="card p-5">
        <h4 className="text-sm font-semibold text-neutral-900 mb-2">{t('waitlist.alreadyOnWaitlist')}</h4>
        <div className="flex gap-2">
          <input
            type="email"
            placeholder={t('waitlist.enterYourEmail')}
            value={checkEmail}
            onChange={(e) => setCheckEmail(e.target.value)}
            className="input flex-1"
          />
          <button onClick={handleCheck} disabled={checking} className="btn-secondary text-sm !py-2.5">
            {checking ? <Loader2 className="w-4 h-4 animate-spin" /> : t('waitlist.check')}
          </button>
        </div>

        {existingEntries !== null && (
          <div className="mt-3">
            {existingEntries.length > 0 ? (
              <div className="space-y-2">
                {existingEntries.map(entry => (
                  <div key={entry.id} className="flex items-center justify-between text-sm bg-neutral-50 rounded-lg p-3">
                    <span className="text-neutral-700">
                      {t('waitlist.position')} <span className="font-bold text-brand-600">#{entry.position}</span>
                      {entry.status !== 'waiting' && (
                        <span className="ml-2 text-xs font-medium text-neutral-500 uppercase">{entry.status}</span>
                      )}
                    </span>
                    {(entry.status === 'waiting' || entry.status === 'notified') && (
                      <button onClick={handleLeave} className="text-xs text-red-500 hover:text-red-700 font-medium">{t('waitlist.leave')}</button>
                    )}
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-neutral-500">No waitlist entries found for this email.</p>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

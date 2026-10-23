import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import apiClient from '../api/client'
import SupportLink from './SupportLink'
import { formatEventDate } from '../utils/eventTime'

const validPhone = value => /^(?:1671|671)\d{7}$|^1[2-9]\d{9}$/.test(value.replace(/\D/g, ''))
const normalizeLink = value => {
  const trimmed = value.trim()
  return /^(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:[/:?#].*)?$/i.test(trimmed) ? `https://${trimmed}` : trimmed
}
const validLink = value => {
  try {
    const url = new URL(normalizeLink(value))
    return ['http:', 'https:'].includes(url.protocol) && /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/i.test(url.hostname) && !url.username && !url.password
  } catch { return false }
}

export default function VerificationNotice({ profile, beginRequest, onUpdated, requestSignal = null, organizationId = profile?.organization?.id, inline = false, className = '' }) {
  const { t } = useTranslation()
  const [updated, setUpdated] = useState(null)
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const current = updated || profile
  const status = current?.verification_status
  const owner = current?.organization?.role === 'owner'
  const [fields, setFields] = useState(() => ({
    business_name: profile?.business_name || '', business_description: profile?.business_description || '',
    verification_phone: profile?.verification_phone || '', verification_link: profile?.verification_link || '',
    verification_request_note: profile?.verification_request_note || '',
  }))
  const [errors, setErrors] = useState({})
  const fieldRefs = useRef({})
  const [errorSummary, setErrorSummary] = useState('')
  useEffect(() => { if (requestSignal && requestSignal.organizationId === organizationId) setOpen(true) }, [requestSignal, organizationId])
  useEffect(() => {
    if (open) return
    setFields({ business_name: profile?.business_name || '', business_description: profile?.business_description || '',
      verification_phone: profile?.verification_phone || '', verification_link: profile?.verification_link || '',
      verification_request_note: profile?.verification_request_note || '' })
  }, [profile?.business_name, profile?.business_description, profile?.verification_phone,
    profile?.verification_link, profile?.verification_request_note, open])
  if (!status) return null

  const labels = {
    business_name: t('organizerVerification.name'), business_description: t('organizerVerification.description'),
    verification_phone: t('organizerVerification.phone'), verification_link: t('organizerVerification.link'),
    verification_request_note: t('organizerVerification.note'),
  }
  const validate = normalizedFields => {
    const next = {}
    for (const key of ['business_name', 'business_description', 'verification_phone', 'verification_link']) {
      if (!normalizedFields[key].trim()) next[key] = t('organizerVerification.required', { field: labels[key] })
    }
    if (normalizedFields.verification_phone.trim() && !validPhone(normalizedFields.verification_phone)) next.verification_phone = t('organizerVerification.phoneError')
    if (normalizedFields.verification_link.trim() && !validLink(normalizedFields.verification_link)) next.verification_link = t('organizerVerification.linkError')
    setErrors(next)
    const firstInvalid = Object.keys(next)[0]
    setErrorSummary(firstInvalid ? `Check ${Object.keys(next).length} highlighted verification ${Object.keys(next).length === 1 ? 'field' : 'fields'}. ${next[firstInvalid]}` : '')
    if (firstInvalid) fieldRefs.current[firstInvalid]?.focus()
    return Object.keys(next).length === 0
  }
  const submit = async event => {
    event.preventDefault()
    const normalizedFields = { ...fields, verification_link: normalizeLink(fields.verification_link) }
    setFields(normalizedFields)
    if (!validate(normalizedFields) || busy) return
    const request = beginRequest?.()
    if (!request) return
    setBusy(true)
    setError('')
    try {
      const response = await apiClient.post('/organizer_profile/submit_verification', normalizedFields, request.config)
      if (!request.current()) return
      setUpdated(response.data)
      setOpen(false)
      onUpdated?.(response.data)
    } catch (failure) {
      if (request.current()) setError(failure.response?.data?.errors?.join(' ') || failure.response?.data?.error || t('organizerVerification.sendError'))
    } finally {
      request.release()
      if (request.current()) setBusy(false)
    }
  }

  return <section id="verification-request" className={`${inline ? '' : 'rounded-xl border border-amber-200 bg-amber-50 p-4 '}text-sm text-amber-950 ${className}`} aria-label={t('organizerVerification.cardLabel')}>
    <h3 className="font-semibold">{t(`organizerVerification.${status}Title`)}</h3>
    {status === 'unverified' && <p className="mt-1">{t('organizerVerification.unverifiedBody')}</p>}
    {status === 'pending' && <p className="mt-1">{t('organizerVerification.pendingBody', { date: current.verification_requested_at ? formatEventDate(current.verification_requested_at) : '' })}</p>}
    {status === 'rejected' && <><p className="mt-1">{t('organizerVerification.rejectedBody')}</p><p className="mt-1 whitespace-pre-wrap">{current.verification_notes}</p></>}
    {status === 'suspended' && <><p className="mt-1">{t('organizerVerification.suspendedBody')}</p><p className="mt-1 whitespace-pre-wrap">{current.verification_notes}</p><SupportLink subject="HåfaPass organizer verification" className="btn-secondary mt-3 min-h-11">{t('organizerVerification.contactSupport')}</SupportLink></>}
    {status === 'verified' && <p className="mt-1">{t('organizerVerification.verifiedBody')}</p>}
    {['unverified', 'pending', 'rejected'].includes(status) && (owner
      ? <button type="button" className="btn-secondary mt-3 min-h-11" onClick={() => setOpen(value => !value)}>{status === 'rejected' ? t('organizerVerification.resubmit') : status === 'pending' ? 'Update request' : t('organizerVerification.request')}</button>
      : <p className="mt-2">{t('organizerVerification.askOwner')}</p>)}
    {open && <form noValidate onSubmit={submit} className="mt-4 grid gap-4">
      <p role="alert" aria-live="assertive" className={errorSummary ? 'text-red-800' : 'sr-only'}>{errorSummary}</p>
      {Object.keys(labels).map(key => <label key={key} className="grid gap-1 font-medium">
        <span>{labels[key]}{key !== 'verification_request_note' && ' *'}</span>
        {['business_description', 'verification_request_note'].includes(key)
          ? <textarea ref={element => { fieldRefs.current[key] = element }} className="input min-h-11" rows={key === 'business_description' ? 3 : 2} value={fields[key]} onChange={event => setFields({ ...fields, [key]: event.target.value })} aria-invalid={Boolean(errors[key])} aria-describedby={errors[key] ? `${key}-error` : undefined} />
          : <input ref={element => { fieldRefs.current[key] = element }} className="input min-h-11" type={key === 'verification_phone' ? 'tel' : key === 'verification_link' ? 'url' : 'text'} value={fields[key]} onChange={event => setFields({ ...fields, [key]: event.target.value })} onBlur={key === 'verification_link' ? () => setFields(currentFields => ({ ...currentFields, verification_link: normalizeLink(currentFields.verification_link) })) : undefined} aria-invalid={Boolean(errors[key])} aria-describedby={errors[key] ? `${key}-error` : undefined} />}
        {errors[key] && <span id={`${key}-error`} role="alert" className="text-red-800">{errors[key]}</span>}
      </label>)}
      <button type="submit" disabled={busy} className="btn-primary min-h-11">{busy ? t('organizerVerification.sending') : t('organizerVerification.send')}</button>
    </form>}
    {error && <p role="alert" className="mt-2 text-red-800">{error}</p>}
  </section>
}

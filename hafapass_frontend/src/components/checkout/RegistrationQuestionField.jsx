import { useTranslation } from 'react-i18next'

const labelClass = 'mb-1 block text-base font-medium text-neutral-800'

export default function RegistrationQuestionField({ question, id, value, onChange, error, disabled }) {
  const { t } = useTranslation()
  const helpId = question.help_text ? `${id}-help` : null
  const errorId = error ? `${id}-error` : null
  const describedBy = [helpId, errorId].filter(Boolean).join(' ') || undefined
  const common = { id, disabled, 'aria-invalid': Boolean(error), 'aria-describedby': describedBy }
  const help = question.help_text && <p id={helpId} className="mt-1 text-base text-neutral-600">{question.help_text}</p>
  const errorText = error && <p id={errorId} className="mt-1 text-base text-danger-700">{error}</p>
  const label = <>{question.prompt}{question.required && ' *'}</>

  if (question.kind === 'checkbox') {
    return <div>
      <label htmlFor={id} className="flex min-h-11 cursor-pointer items-center gap-3 rounded-xl border border-neutral-200 bg-white px-4 py-2 text-base text-neutral-800">
        <input type="checkbox" {...common} required={question.required} checked={value === true}
          onChange={e => onChange(e.target.checked)} className="h-5 w-5 shrink-0 rounded border-neutral-300" />
        <span className="min-w-0 break-words">{label}</span>
      </label>
      {help}{errorText}
    </div>
  }

  if (question.kind === 'multi_select') {
    const selected = Array.isArray(value) ? value : []
    return <fieldset aria-describedby={describedBy} aria-invalid={Boolean(error)}>
      <legend className={labelClass}>{label}</legend>
      <p className="mb-2 text-base text-neutral-600">{t('buyer.Checkout.chooseAllThatApply')}</p>
      <div className="flex flex-wrap gap-2">
        {(question.options || []).map((option, index) => {
          const checked = selected.includes(option)
          return <label key={option} htmlFor={index === 0 ? id : `${id}-${index}`}
            className={`inline-flex min-h-11 cursor-pointer items-center gap-2 rounded-full border px-4 py-2 text-base ${checked ? 'border-brand-600 bg-brand-50 text-brand-900' : 'border-neutral-300 bg-white text-neutral-800'}`}>
            <input type="checkbox" id={index === 0 ? id : `${id}-${index}`} disabled={disabled} checked={checked}
              onChange={e => onChange(e.target.checked ? [...selected, option] : selected.filter(item => item !== option))}
              className="h-5 w-5 shrink-0 rounded border-neutral-300" />
            {option}
          </label>
        })}
      </div>
      {help}{errorText}
    </fieldset>
  }

  let control
  if (question.kind === 'selection') {
    control = <select {...common} required={question.required} className="input text-base" value={value || ''} onChange={e => onChange(e.target.value)}>
      <option value="">{t('buyer.Checkout.selectOne')}</option>
      {(question.options || []).map(option => <option key={option} value={option}>{option}</option>)}
    </select>
  } else if (question.kind === 'long_text') {
    control = <textarea {...common} required={question.required} className="input text-base" rows="3" value={value || ''} onChange={e => onChange(e.target.value)} />
  } else {
    const { min, max, integer } = question.validation_rules || {}
    const typeProps = {
      number: { type: 'number', inputMode: integer ? 'numeric' : 'decimal', min: min ?? undefined, max: max ?? undefined, step: integer ? '1' : 'any' },
      phone: { type: 'tel', inputMode: 'tel', autoComplete: 'tel' },
      email: { type: 'email', inputMode: 'email', autoComplete: 'email' },
    }[question.kind] || { type: 'text' }
    control = <input {...common} {...typeProps} required={question.required} className="input text-base" value={value ?? ''} onChange={e => onChange(e.target.value)} />
  }
  return <div>
    <label className={labelClass} htmlFor={id}>{label}</label>
    {control}
    {help}{errorText}
  </div>
}

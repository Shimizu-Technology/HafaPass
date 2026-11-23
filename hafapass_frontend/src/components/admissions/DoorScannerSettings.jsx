import { useId } from 'react'
import DoorScanCard from './DoorScanCard'

const MODES = [
  ['instant', 'Instant Admit', 'Green flash as soon as the QR is scanned'],
  ['verify', 'Hold & Verify at Door', 'Pause scanner so staff can check ID or confirm details'],
]

function sampleAnswer(question) {
  const { kind, prompt, options = [], validation_rules: rules = {} } = question
  if (kind === 'checkbox') return 'Yes'
  if (kind === 'multi_select') return options.slice(0, 2).join(', ')
  if (kind === 'selection') return options[0]
  if (kind === 'number') {
    const example = /year/i.test(prompt) ? 1998 : 2
    return String(Math.max(rules.min ?? -Infinity, Math.min(example, rules.max ?? Infinity)))
  }
  if (kind === 'email') return 'maria@example.com'
  if (kind === 'phone') return '671-555-0100'
  if (/year/i.test(prompt)) return '1998'
  if (/name/i.test(prompt)) return 'Maria Cruz'
  return 'Sample answer'
}

function previewFields(questions, ticketTypeId) {
  return questions
    .filter(question => (
      question.show_on_scanner &&
      (!question.ticket_type_ids?.length || question.ticket_type_ids.some(id => String(id) === String(ticketTypeId)))
    ))
    .sort((left, right) => Number(right.scope === 'ticket') - Number(left.scope === 'ticket') || left.position - right.position || left.id - right.id)
    .flatMap(question => {
      const value = sampleAnswer(question)
      if (!value) return []
      const characters = Array.from(value)
      return [{ label: question.prompt, value: characters.length > 80 ? `${characters.slice(0, 79).join('')}…` : value }]
    })
}

export default function DoorScannerSettings({ form, setForm, ticketTypeId, questions, saving }) {
  const fieldId = useId()
  const update = (key, value) => setForm(current => ({ ...current, [key]: value }))
  const doorFields = previewFields(questions, ticketTypeId)
  const ticket = {
    attendee_name: 'Maria Cruz',
    buyer_name: form.scanner_show_buyer ? 'Pat Cruz' : null,
    ticket_type_name: form.name.trim() || 'Ticket type name',
    door_alert_label: form.door_alert_label.trim(),
    door_instructions: form.door_instructions.trim(),
    door_fields: doorFields,
  }

  return (
    <section aria-labelledby={`${fieldId}-heading`} className="grid gap-5 rounded-xl border border-neutral-300 bg-white p-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,20rem)]">
      <div className="space-y-4">
        <h3 id={`${fieldId}-heading`} className="text-lg font-bold text-neutral-950">Door Scanner Behavior</h3>
        <fieldset disabled={saving} className="space-y-2">
          <legend className="sr-only">Admission mode</legend>
          {MODES.map(([value, label, help]) => (
            <label key={value} className={`flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border-2 px-3 py-2 text-neutral-950 focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-brand-800 ${form.door_check_mode === value ? 'border-brand-800 bg-brand-50' : 'border-neutral-500'}`}>
              <input type="radio" name={`${fieldId}-mode`} value={value} checked={form.door_check_mode === value}
                onChange={() => update('door_check_mode', value)} className="mt-1 h-5 w-5 shrink-0 accent-brand-800" />
              <span><span className="block font-bold">{label}</span><span className="block text-neutral-700">{help}</span></span>
            </label>
          ))}
        </fieldset>
        <div>
          <label htmlFor={`${fieldId}-alert`} className="mb-1 block font-semibold text-neutral-950">Alert Banner</label>
          <input id={`${fieldId}-alert`} className="input min-h-12 border-neutral-500 text-base" maxLength={120} value={form.door_alert_label}
            onChange={event => update('door_alert_label', event.target.value)} placeholder="FREE ALUMNI — CHECK ID" disabled={saving} />
          <p className="mt-1 text-base text-neutral-700">Shown when staff need to verify a ticket.</p>
        </div>
        <div>
          <label htmlFor={`${fieldId}-instructions`} className="mb-1 block font-semibold text-neutral-950">Staff Instructions</label>
          <textarea id={`${fieldId}-instructions`} className="input min-h-12 border-neutral-500 text-base" rows={3} maxLength={400} value={form.door_instructions}
            onChange={event => update('door_instructions', event.target.value)} placeholder="Check alumni ID or confirm graduation year." disabled={saving} />
        </div>
        <label className="flex min-h-12 cursor-pointer items-center gap-3 rounded-lg font-semibold text-neutral-950">
          <input type="checkbox" className="h-5 w-5 shrink-0 accent-brand-800" checked={form.scanner_show_buyer}
            onChange={event => update('scanner_show_buyer', event.target.checked)} disabled={saving} />
          Show buyer name if someone else bought the ticket
        </label>
      </div>
      <section aria-labelledby={`${fieldId}-preview`} className="mx-auto w-full max-w-xs self-start">
        <h4 id={`${fieldId}-preview`} className="mb-2 text-base font-bold text-neutral-950">Live Door Scanner Preview</h4>
        <div className="overflow-hidden rounded-[1.75rem] border-[5px] border-neutral-950">
          <DoorScanCard ticket={ticket} verifying={form.door_check_mode === 'verify'} preview />
        </div>
        {doorFields.length === 0 && <p className="mt-2 text-base text-neutral-700">Want to show an answer here? Turn on “Show on scanner” for a registration question that applies to this ticket type.</p>}
      </section>
    </section>
  )
}

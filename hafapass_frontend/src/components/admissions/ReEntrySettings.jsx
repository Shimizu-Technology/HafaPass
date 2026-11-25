import { useId } from 'react'
import { AlertTriangle } from 'lucide-react'

const RE_ENTRY_MODES = [
  {
    value: 'off',
    label: 'Off (single entry)',
    help: 'Default. Each ticket scans in once and cannot re-enter. Door staff see no extra controls or taps.',
  },
  {
    value: 'exit_scan',
    label: 'Exit scan (in & out)',
    help: 'Door staff get a big Entry / Exit switch. Guests must scan out before scanning back in, stopping passback if a ticket is already inside.',
  },
  {
    value: 'cooldown',
    label: 'Cool-down (no exit staff)',
    help: 'Entry scanning only. Re-scanning inside the cool-down window is blocked; after the window, the ticket can scan back in.',
  },
]

const LOCAL_DATETIME_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/
const CUTOFF_TIME_RE = /^([01]\d|2[0-3]):([0-5]\d)$/

function parseLocalWallClockMs(value) {
  const match = LOCAL_DATETIME_RE.exec(String(value || '').trim())
  if (!match) return Number.NaN
  return Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), 0)
}

function getCutoffScheduleWarning({ cutoffTime, startsAt, endsAt, doorsOpenAt }) {
  const cutMatch = CUTOFF_TIME_RE.exec(String(cutoffTime || '').trim())
  if (!cutMatch) return null
  const startMs = parseLocalWallClockMs(startsAt)
  if (!Number.isFinite(startMs)) return null
  const endMs = parseLocalWallClockMs(endsAt)
  const isSingleSession = !Number.isFinite(endMs) || (endMs - startMs) <= 24 * 3_600_000
  if (!isSingleSession) return null

  const doorsMs = parseLocalWallClockMs(doorsOpenAt)
  const hasEarlierDoors = Number.isFinite(doorsMs) && doorsMs < startMs
  const anchorMs = hasEarlierDoors ? doorsMs : startMs
  const anchorDate = new Date(anchorMs)
  const cutHour = Number(cutMatch[1])
  const cutMin = Number(cutMatch[2])
  let candidateMs = Date.UTC(anchorDate.getUTCFullYear(), anchorDate.getUTCMonth(), anchorDate.getUTCDate(), cutHour, cutMin, 0)
  const rolledToNextDay = candidateMs < anchorMs
  if (rolledToNextDay) candidateMs += 24 * 3_600_000

  if (Number.isFinite(endMs) && candidateMs >= endMs) {
    return rolledToNextDay
      ? 'This cutoff is earlier than the event start time, so it falls after the event ends and will not block re-entry. Pick a time between start and end (or set Doors open).'
      : 'This cutoff is at or after the event end time, so it will not block re-entry during the event.'
  }
  if (!Number.isFinite(endMs) && !hasEarlierDoors && rolledToNextDay) {
    return 'This cutoff is earlier than the event start time, so it will apply the next morning.'
  }
  return null
}

export default function ReEntrySettings({
  form,
  updateField,
  formErrors = {},
  disabled = false,
  timezone = 'Pacific/Guam',
  savedMode = 'off',
  isLiveEvent = false,
  startsAt = '',
  endsAt = '',
  doorsOpenAt = '',
}) {
  const groupId = useId()
  const mode = form.re_entry_mode || 'off'
  const showRules = mode === 'exit_scan' || mode === 'cooldown'
  const switchingOffMidEvent = isLiveEvent && savedMode !== 'off' && mode === 'off'
  const cutoffWarning = showRules ? getCutoffScheduleWarning({ cutoffTime: form.re_entry_cutoff_time, startsAt, endsAt, doorsOpenAt }) : null

  const handleModeChange = nextMode => {
    updateField('re_entry_mode', nextMode)
    if (nextMode === 'cooldown' && !form.re_entry_cooldown_minutes) {
      updateField('re_entry_cooldown_minutes', '15')
    }
  }

  return (
    <div className="space-y-4 rounded-xl border border-neutral-200 bg-neutral-50/70 p-4">
      <div>
        <h3 id={`${groupId}-heading`} className="text-base font-semibold text-neutral-950">Re-entry policy</h3>
        <p className="mt-1 text-sm text-neutral-700">
          Control whether guests can leave and come back. Leave Off for standard one-time check-in.
        </p>
      </div>

      <fieldset aria-labelledby={`${groupId}-heading`} disabled={disabled} className="space-y-2">
        <legend className="sr-only">Re-entry mode</legend>
        {RE_ENTRY_MODES.map(option => (
          <label
            key={option.value}
            className={`flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border-2 bg-white px-3.5 py-3 text-neutral-950 focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-brand-800 ${
              mode === option.value ? 'border-brand-800 bg-brand-50/60' : 'border-neutral-300 hover:border-neutral-400'
            }`}
          >
            <input
              type="radio"
              name="re_entry_mode"
              value={option.value}
              checked={mode === option.value}
              onChange={() => handleModeChange(option.value)}
              className="mt-1 h-5 w-5 shrink-0 accent-brand-800"
            />
            <span className="min-w-0">
              <span className="block text-sm font-bold text-neutral-950">{option.label}</span>
              <span className="mt-0.5 block text-sm text-neutral-700">{option.help}</span>
            </span>
          </label>
        ))}
      </fieldset>

      {switchingOffMidEvent && (
        <div role="alert" className="flex items-start gap-2.5 rounded-xl border border-amber-300 bg-amber-50 p-3 text-sm text-amber-950">
          <AlertTriangle aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
          <p>
            <strong>Warning: switching re-entry to Off while this event is live</strong> will strand guests who already stepped out — their tickets will be blocked from scanning back in.
          </p>
        </div>
      )}

      {showRules && (
        <div className="grid grid-cols-1 gap-4 pt-1 sm:grid-cols-2">
          {mode === 'cooldown' && (
            <div className="sm:col-span-2">
              <label htmlFor="re_entry_cooldown_minutes" className="mb-1 block text-sm font-medium text-neutral-800">
                Cool-down minutes <span className="text-red-600">*</span>
              </label>
              <input
                id="re_entry_cooldown_minutes"
                type="number"
                min="1"
                max="1440"
                step="1"
                value={form.re_entry_cooldown_minutes}
                onChange={event => updateField('re_entry_cooldown_minutes', event.target.value)}
                aria-invalid={Boolean(formErrors.re_entry_cooldown_minutes)}
                aria-describedby={`re_entry_cooldown_minutes-help${formErrors.re_entry_cooldown_minutes ? ' re_entry_cooldown_minutes-error' : ''}`}
                className={`input ${formErrors.re_entry_cooldown_minutes ? 'input-error' : ''}`}
                placeholder="e.g., 15"
                disabled={disabled}
              />
              <p id="re_entry_cooldown_minutes-help" className="mt-1 text-xs text-neutral-600">
                Wait time before the same ticket can scan in again. Stops quick passbacks without an exit gate.
              </p>
              {formErrors.re_entry_cooldown_minutes && (
                <p id="re_entry_cooldown_minutes-error" className="mt-1 text-sm text-red-600">{formErrors.re_entry_cooldown_minutes}</p>
              )}
            </div>
          )}

          <div>
            <label htmlFor="re_entry_max_count" className="mb-1 block text-sm font-medium text-neutral-800">
              Max re-entries per ticket (optional)
            </label>
            <input
              id="re_entry_max_count"
              type="number"
              min="1"
              max="1000"
              step="1"
              value={form.re_entry_max_count}
              onChange={event => updateField('re_entry_max_count', event.target.value)}
              aria-invalid={Boolean(formErrors.re_entry_max_count)}
              aria-describedby={`re_entry_max_count-help${formErrors.re_entry_max_count ? ' re_entry_max_count-error' : ''}`}
              className={`input ${formErrors.re_entry_max_count ? 'input-error' : ''}`}
              placeholder="Unlimited"
              disabled={disabled}
            />
            <p id="re_entry_max_count-help" className="mt-1 text-xs text-neutral-600">
              Leave blank for unlimited. For example, 2 allows first entry plus 2 re-entries per day.
            </p>
            {formErrors.re_entry_max_count && (
              <p id="re_entry_max_count-error" className="mt-1 text-sm text-red-600">{formErrors.re_entry_max_count}</p>
            )}
          </div>

          <div>
            <label htmlFor="re_entry_cutoff_time" className="mb-1 block text-sm font-medium text-neutral-800">
              Daily re-entry cutoff time (optional)
            </label>
            <input
              id="re_entry_cutoff_time"
              type="time"
              value={form.re_entry_cutoff_time}
              onChange={event => updateField('re_entry_cutoff_time', event.target.value)}
              aria-invalid={Boolean(formErrors.re_entry_cutoff_time)}
              aria-describedby={`re_entry_cutoff_time-help${formErrors.re_entry_cutoff_time ? ' re_entry_cutoff_time-error' : ''}`}
              className={`input ${formErrors.re_entry_cutoff_time ? 'input-error' : ''}`}
              disabled={disabled}
            />
            <p id="re_entry_cutoff_time-help" className="mt-1 text-xs text-neutral-600">
              Event time zone ({timezone}). Applies each day of the event; guests who left cannot re-enter after this time, while first-time arrivals can still enter.
            </p>
            {cutoffWarning && (
              <p role="alert" className="mt-1.5 flex items-start gap-1.5 rounded-lg border border-amber-300 bg-amber-50 px-2.5 py-2 text-xs text-amber-950">
                <AlertTriangle aria-hidden="true" className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-700" />
                <span>{cutoffWarning}</span>
              </p>
            )}
            {formErrors.re_entry_cutoff_time && (
              <p id="re_entry_cutoff_time-error" className="mt-1 text-sm text-red-600">{formErrors.re_entry_cutoff_time}</p>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

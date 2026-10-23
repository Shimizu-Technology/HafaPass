import { useId } from 'react'
import { roleDescription, roleLabel } from '../../utils/roles'

// Radio cards: every option shows its one-line description, so the choice
// is understood before it is made. Use where a role is picked for someone new.
export function RoleRadioGroup({ legend, roles, value, onChange, disabled = false, name, action }) {
  const fallbackName = useId()
  return (
    <fieldset disabled={disabled} className="min-w-0">
      <legend className={`${action ? 'w-full ' : ''}text-sm font-medium text-neutral-900`}>{action ? <span className="flex min-h-11 flex-wrap items-center justify-between gap-x-3">{legend}{action}</span> : legend}</legend>
      <div className="mt-2 grid gap-2 sm:grid-cols-2">
        {roles.map(role => (
          <label key={role} className={`flex min-h-11 cursor-pointer gap-3 rounded-xl border p-3 transition-colors duration-150 ease-out-strong ${value === role ? 'border-brand-600 bg-brand-50' : 'border-neutral-200 bg-white [@media(hover:hover)]:hover:border-neutral-300'}`}>
            <input type="radio" name={name || fallbackName} value={role} checked={value === role} onChange={() => onChange(role)} className="mt-1 h-4 w-4 shrink-0 accent-brand-600" />
            <span className="min-w-0">
              <span className="block text-sm font-semibold text-neutral-900">{roleLabel(role)}</span>
              <span className="block text-sm text-content-muted">{roleDescription(role)}</span>
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  )
}

// A compact select for changing an existing person's role; the selected
// role's description sits underneath and is announced with the control.
export function RoleSelect({ label, roles, value, onChange, disabled = false, className = '', action }) {
  const descriptionId = useId()
  return (
    <div className={`min-w-0 ${className}`}>
      <select aria-label={label} aria-describedby={descriptionId} disabled={disabled} value={value} onChange={event => onChange(event.target.value)} className="input min-h-11 !py-2 text-sm">
        {roles.map(role => <option key={role} value={role}>{roleLabel(role)}</option>)}
      </select>
      <p id={descriptionId} className="mt-1 text-xs text-content-muted">{roleDescription(value)}</p>
      {action}
    </div>
  )
}

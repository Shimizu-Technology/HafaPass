import { useEffect, useId, useState } from 'react'
import { Check, X } from 'lucide-react'
import Dialog from '../Dialog'
import roleMatrix from '../../generated/roleMatrix.json'

export function CompareRolesButton({ onClick }) {
  return <button type="button" onClick={onClick} aria-haspopup="dialog" className="min-h-11 shrink-0 text-sm font-semibold text-brand-700 underline underline-offset-2">Compare roles</button>
}

function Permission({ value }) {
  const Icon = value === 'No' ? X : Check
  return <span className="inline-flex items-start gap-1.5"><Icon aria-hidden="true" className={`mt-0.5 h-4 w-4 shrink-0 ${value === 'No' ? 'text-neutral-500' : 'text-emerald-700'}`} /><span>{value}</span></span>
}

export default function RoleComparison({ onClose, initialRole = 'manager' }) {
  const titleId = useId()
  const [desktop, setDesktop] = useState(() => window.matchMedia?.('(min-width: 1024px)').matches || false)
  useEffect(() => {
    const media = window.matchMedia?.('(min-width: 1024px)')
    if (!media) return undefined
    const changed = () => setDesktop(media.matches)
    media.addEventListener('change', changed)
    return () => media.removeEventListener('change', changed)
  }, [])
  const [selectedRole, setSelectedRole] = useState(roleMatrix.roles.some(role => role.key === initialRole) ? initialRole : 'manager')
  return (
    <Dialog labelledBy={titleId} onClose={onClose} className="max-w-7xl">
      <div className="sticky top-0 z-10 flex items-start justify-between gap-4 bg-white pb-3">
        <h2 id={titleId} className="text-xl font-semibold text-neutral-900">Compare roles</h2>
        <button type="button" onClick={onClose} className="btn-secondary min-h-11 shrink-0 !px-3 !py-2 text-sm">Close</button>
      </div>
      <p className="mt-3 text-sm text-neutral-700">Choose the access each teammate needs.</p>
      <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-neutral-700" aria-label="Role access notes">
        {Object.entries(roleMatrix.notes).filter(([key]) => key !== 'scope').map(([key, note]) => <li key={key}>{note}</li>)}
      </ul>

      <div tabIndex={desktop ? 0 : -1} role="region" aria-label="Role comparison table" className="mt-5 hidden max-h-[65vh] overflow-auto lg:block">
        <table className="min-w-[960px] w-full table-fixed border-collapse text-left text-sm">
          <caption className="sr-only">Organization role permissions</caption>
          <thead className="sticky top-0 z-10 bg-neutral-100">
            <tr>
              <th scope="col" className="sticky left-0 z-20 w-[28%] bg-neutral-100 rounded-tl-lg p-3 font-semibold text-neutral-900">What they can do</th>
              {roleMatrix.roles.map(role => <th key={role.key} scope="col" className="p-2 font-semibold text-neutral-900 [overflow-wrap:anywhere]">{role.label}</th>)}
            </tr>
          </thead>
          <tbody>
            {roleMatrix.rows.map(row => (
              <tr key={row.key} className="border-b border-neutral-200 align-top">
                <th scope="row" className="sticky left-0 bg-white p-3 font-medium text-neutral-900">
                  {row.label}
                  {row.note && <span className="mt-1 block text-xs font-normal text-content-muted">{row.note}</span>}
                </th>
                {roleMatrix.roles.map(role => <td key={role.key} className="p-2 pt-3 text-neutral-700 [overflow-wrap:anywhere]"><Permission value={row.values[role.key]} /></td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="mt-5 lg:hidden" aria-label="Role permissions">
        <label className="block text-sm font-semibold text-neutral-900">Role
          <select disabled={desktop} className="input mt-2 min-h-11" value={selectedRole} onChange={event => setSelectedRole(event.target.value)}>
            {roleMatrix.roles.map(role => <option key={role.key} value={role.key}>{role.label}</option>)}
          </select>
        </label>
        {['Can', "Can't"].map(group => <section key={group} className="mt-5">
          <h3 className="font-semibold text-neutral-900">{group}</h3>
          <ul className="mt-2 divide-y divide-neutral-100">
            {roleMatrix.rows.filter(row => (row.values[selectedRole] !== 'No') === (group === 'Can')).map(row => <li key={row.key} className="flex gap-2 py-3 text-sm text-neutral-900">
              {group === 'Can' ? <Check aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-emerald-700" /> : <X aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0 text-neutral-500" />}
              <div><span>{row.label}</span>
                {!['Yes', 'No'].includes(row.values[selectedRole]) && <p className="mt-1 text-xs font-medium text-neutral-700">{row.values[selectedRole] === 'Assigned events' ? 'Assigned events only' : row.values[selectedRole]}</p>}
                {row.note && ({ manager: ['manage_events', 'staff'], marketer: ['content', 'marketing'], owner: ['organization'] }[selectedRole] || []).includes(row.key) && <p className="mt-1 text-xs text-content-muted">{row.note}</p>}
              </div>
            </li>)}
          </ul>
        </section>)}
      </div>
    </Dialog>
  )
}

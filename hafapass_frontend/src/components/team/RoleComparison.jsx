import { useId } from 'react'
import Dialog from '../Dialog'
import roleMatrix from '../../generated/roleMatrix.json'

export function CompareRolesButton({ onClick }) {
  return <button type="button" onClick={onClick} aria-haspopup="dialog" className="min-h-11 shrink-0 text-sm font-semibold text-brand-700 underline underline-offset-2">Compare roles</button>
}

export default function RoleComparison({ onClose }) {
  const titleId = useId()
  return (
    <Dialog labelledBy={titleId} onClose={onClose} className="max-w-7xl">
      <div className="sticky top-0 z-10 flex items-start justify-between gap-4 bg-white pb-3">
        <h2 id={titleId} className="text-xl font-semibold text-neutral-900">Compare roles</h2>
        <button type="button" onClick={onClose} className="btn-secondary min-h-11 shrink-0 !px-3 !py-2 text-sm">Close</button>
      </div>
      <p className="mt-3 text-sm text-neutral-700">Choose the access each teammate needs. These are organization roles; event assignments add access to one event.</p>
      <p className="mt-2 text-sm text-neutral-700">{roleMatrix.notes.scope}</p>

      <div className="mt-5 hidden lg:block">
        <table className="w-full table-fixed border-collapse text-left text-sm">
          <caption className="sr-only">Organization role permissions</caption>
          <thead className="sticky top-14 bg-neutral-100">
            <tr>
              <th scope="col" className="w-[28%] rounded-tl-lg p-3 font-semibold text-neutral-900">What they can do</th>
              {roleMatrix.roles.map(role => <th key={role.key} scope="col" className="p-2 font-semibold text-neutral-900 [overflow-wrap:anywhere]">{role.label}</th>)}
            </tr>
          </thead>
          <tbody>
            {roleMatrix.rows.map(row => (
              <tr key={row.key} className="border-b border-neutral-200 align-top">
                <th scope="row" className="p-3 font-medium text-neutral-900">
                  {row.label}
                  {row.note && <span className="mt-1 block text-xs font-normal text-content-muted">{row.note}</span>}
                </th>
                {roleMatrix.roles.map(role => <td key={role.key} className="p-2 pt-3 text-neutral-700 [overflow-wrap:anywhere]">{row.values[role.key]}</td>)}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="mt-5 space-y-3 lg:hidden" aria-label="Stacked role comparison">
        {roleMatrix.rows.map(row => (
          <section key={row.key} className="rounded-xl border border-neutral-200 p-3">
            <h3 className="font-semibold text-neutral-900">{row.label}</h3>
            {row.note && <p className="mt-1 text-xs text-content-muted">{row.note}</p>}
            <dl className="mt-3 space-y-2 text-sm">
              {roleMatrix.roles.map(role => <div key={role.key} className="grid grid-cols-2 gap-3">
                <dt className="font-medium text-neutral-900">{role.label}</dt>
                <dd className="text-neutral-700">{row.values[role.key]}</dd>
              </div>)}
            </dl>
          </section>
        ))}
      </div>

      <ul className="mt-5 list-disc space-y-2 pl-5 text-sm text-neutral-700" aria-label="Role access notes">
        {Object.entries(roleMatrix.notes).filter(([key]) => key !== 'scope').map(([key, note]) => <li key={key}>{note}</li>)}
      </ul>
    </Dialog>
  )
}

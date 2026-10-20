// Ranked horizontal bars for one measure across a few categories (ticket
// types, sales channels, traffic sources). Every row prints its value, so the
// list doubles as its own table: bars are decoration for screen readers.
export default function BarList({ rows, label, formatValue = String, emptyText = 'Nothing to show yet.' }) {
  const max = Math.max(0, ...rows.map(row => row.value))
  if (!rows.length || max <= 0) return <p className="rounded-xl bg-neutral-50 px-4 py-6 text-center text-sm text-neutral-600">{emptyText}</p>
  return (
    <ul aria-label={label} className="space-y-3">
      {rows.map(row => {
        const share = row.value > 0 ? Math.max(1, (row.value / max) * 100) : 0
        return (
          <li key={row.key} className="min-w-0">
            <div className="flex items-baseline justify-between gap-3 text-sm">
              <span className="min-w-0 truncate font-medium text-neutral-900" title={row.label}>{row.label}</span>
              <span className="shrink-0 text-right tabular-nums">
                <span className="font-semibold text-neutral-950">{formatValue(row.value)}</span>
                {row.detail && <span className="text-neutral-600"> · {row.detail}</span>}
              </span>
            </div>
            <div aria-hidden="true" className="mt-1.5 h-2.5 w-full">
              {share > 0 && <div className="h-full rounded-r bg-brand-500" style={{ width: `${share}%` }} />}
            </div>
          </li>
        )
      })}
    </ul>
  )
}

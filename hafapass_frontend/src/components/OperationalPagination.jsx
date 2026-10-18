export default function OperationalPagination({ meta, page, onPage, busy = false, label = 'Result pages' }) {
  if (!meta || (meta.total_pages <= 1 && page === 1)) return null
  return <nav aria-label={label} className="my-5 flex flex-wrap items-center justify-center gap-3">
    <button type="button" disabled={busy || page <= 1} onClick={() => onPage(page - 1)} className="btn-secondary disabled:opacity-50">Previous</button>
    <span role="status" className="text-sm text-neutral-700">Page {page} of {Math.max(meta.total_pages, page)} · {meta.total_count} results</span>
    <button type="button" disabled={busy || page >= meta.total_pages} onClick={() => onPage(page + 1)} className="btn-secondary disabled:opacity-50">Next</button>
  </nav>
}

export default function FormErrorSummary({ errors, title = 'Check the event details' }) {
  const entries = Object.entries(errors).filter(([, message]) => message)
  if (!entries.length) return null
  return <div role="alert" className="mb-6 rounded-xl border border-red-300 bg-red-50 p-4 text-sm text-red-800">
    <h2 className="font-semibold">{title}</h2>
    <ul className="mt-2 list-disc space-y-1 pl-5">
      {entries.map(([field, message]) => <li key={field}><a href={`#${field}`} className="font-medium underline underline-offset-2" onClick={event => {
        event.preventDefault()
        document.getElementById(field)?.focus()
      }}>{message}</a></li>)}
    </ul>
  </div>
}

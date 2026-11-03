// Shown when /config didn't answer, so a feature's state is unknown rather
// than off. Ops screens are English-only, like the rest of the dashboard.
export default function CapabilityCheckFailed({ feature, onRetry }) {
  return (
    <div className="mx-auto max-w-xl p-8">
      <p role="alert" className="text-neutral-700">We couldn&apos;t check whether {feature} is turned on. Check your connection and try again.</p>
      <button type="button" className="btn-secondary mt-4 min-h-11" onClick={onRetry}>Try again</button>
    </div>
  )
}

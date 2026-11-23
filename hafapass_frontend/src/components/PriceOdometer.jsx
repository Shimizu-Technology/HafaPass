import usePrefersReducedMotion from '../hooks/usePrefersReducedMotion'

const DIGITS = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']

/**
 * Rolling tabular-numeral price odometer for ticket totals (Option C).
 * Pure CSS transform digit reels (composite-only); keeps exact plain text for
 * screen readers and renders static text under prefers-reduced-motion.
 */
export default function PriceOdometer({ value }) {
  const reducedMotion = usePrefersReducedMotion()
  const text = String(value ?? '')

  if (reducedMotion) {
    return <span className="tabular-nums">{text}</span>
  }

  return (
    <span className="price-odometer inline-flex items-baseline tabular-nums" data-testid="price-odometer">
      <span className="sr-only">{text}</span>
      <span aria-hidden="true" className="inline-flex items-baseline">
        {Array.from(text).map((char, index) => {
          const digit = char >= '0' && char <= '9' ? Number(char) : null
          if (digit === null) {
            return <span key={`s-${index}`}>{char}</span>
          }
          return (
            <span key={`d-${text.length - index}`} className="odometer-slot">
              <span
                className="odometer-reel"
                style={{ transform: `translate3d(0, ${-digit * 10}%, 0)` }}
              >
                {DIGITS.map(d => (
                  <span key={d} className="odometer-digit">{d}</span>
                ))}
              </span>
            </span>
          )
        })}
      </span>
    </span>
  )
}

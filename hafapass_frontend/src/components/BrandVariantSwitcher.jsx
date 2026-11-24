import { BRAND_VARIANTS } from '../utils/brandVariants'

/**
 * Compact preview-only switcher for the HåfaPass brand-ticket cover variants
 * (?brand=1|2|3). Rendered only when VITE_HAFAPASS_DEMO_DATA=1, positioned in
 * flow at the top of the hero so it stays out of the way of the ticket deck
 * and clear of Netlify's bottom preview drawer.
 */
export default function BrandVariantSwitcher({ activeVariant, onSelect }) {
  return (
    <div className="mx-auto mb-4 flex w-full max-w-6xl justify-center px-4 sm:mb-5 sm:justify-start sm:px-6 lg:px-8">
      <nav
        aria-label="Brand cover variants"
        data-testid="brand-variant-switcher"
        className="brand-switcher surface-dark inline-flex max-w-full items-center gap-1 rounded-2xl p-1 text-white"
      >
        <span className="hidden select-none pl-2.5 pr-1 text-[11px] font-semibold uppercase tracking-[0.12em] text-brand-300 sm:inline">
          Cover
        </span>
        {BRAND_VARIANTS.map(variant => {
          const active = variant.id === activeVariant
          return (
            <button
              key={variant.id}
              type="button"
              aria-current={active ? 'true' : undefined}
              aria-label={`Brand cover ${variant.id}: ${variant.name}`}
              onClick={() => onSelect(variant.id)}
              className={`inline-flex min-h-11 min-w-[44px] items-center justify-center gap-1.5 rounded-xl px-3 py-1.5 text-xs font-semibold transition-[background-color,color,transform] duration-150 ease-out-strong active:scale-[0.97] ${
                active
                  ? 'bg-white text-brand-950 shadow-soft'
                  : 'text-white/90 hover:bg-white/15 hover:text-white'
              }`}
            >
              <span className={`font-display text-xs font-bold leading-none ${active ? 'text-brand-800' : 'text-brand-300'}`}>
                {variant.id}
              </span>
              <span className="whitespace-nowrap">
                <span className="sm:hidden">{variant.shortLabel}</span>
                <span className="hidden sm:inline">{variant.name}</span>
              </span>
            </button>
          )
        })}
      </nav>
    </div>
  )
}

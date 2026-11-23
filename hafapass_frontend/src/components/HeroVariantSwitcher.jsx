import { HERO_VARIANTS } from '../utils/heroVariants'

/**
 * Preview-only floating hero variant switcher (rendered only when
 * VITE_HAFAPASS_DEMO_DATA=1). Sticky at the top of the hero below the navbar so
 * it stays effortlessly tappable on iPhone/desktop without colliding with the
 * Netlify deploy-preview Collaborate drawer at the bottom edge.
 */
export default function HeroVariantSwitcher({ activeVariant, onSelect }) {
  const current = HERO_VARIANTS.find(variant => variant.id === activeVariant) || HERO_VARIANTS[0]

  return (
    <div className="hero-switcher-wrap sticky z-30 mx-auto mb-5 flex w-full max-w-6xl justify-center px-3 sm:mb-6 sm:px-6 lg:px-8">
      <nav
        aria-label="Hero design variants"
        data-testid="hero-variant-switcher"
        className="hero-switcher surface-dark flex w-full max-w-[26.5rem] flex-col items-center rounded-2xl p-1.5 text-white sm:w-fit sm:max-w-full"
      >
        <div className="mb-1 flex w-full items-center justify-between gap-2 px-2 text-[11px] leading-tight text-brand-200 sm:hidden">
          <span className="font-semibold uppercase tracking-[0.12em] text-brand-300">Hero {current.id}</span>
          <span className="truncate font-medium text-white">{current.name}</span>
        </div>
        <div className="grid w-full grid-cols-4 gap-1 sm:flex sm:w-auto sm:items-center sm:gap-1">
          <span className="hidden select-none pl-2.5 pr-1 text-[11px] font-semibold uppercase tracking-[0.12em] text-brand-300 sm:inline">
            Hero
          </span>
          {HERO_VARIANTS.map(variant => {
            const active = variant.id === activeVariant
            return (
              <button
                key={variant.id}
                type="button"
                aria-current={active ? 'true' : undefined}
                aria-label={`Hero ${variant.id}: ${variant.name}`}
                onClick={() => onSelect(variant.id)}
                className={`hero-switcher-btn flex min-h-11 min-w-[44px] flex-col items-center justify-center rounded-xl px-2 py-1 text-center transition-[background-color,color,transform] duration-150 ease-out-strong active:scale-[0.97] sm:flex-row sm:gap-1.5 sm:px-3 ${
                  active
                    ? 'bg-white text-brand-950 shadow-soft'
                    : 'text-white/90 hover:bg-white/15 hover:text-white'
                }`}
              >
                <span className={`font-display text-xs font-bold leading-none ${active ? 'text-brand-950' : 'text-brand-300'}`}>
                  {variant.id}
                </span>
                <span className={`mt-0.5 max-w-full truncate text-[10px] font-semibold leading-tight sm:mt-0 sm:text-xs ${active ? 'text-brand-950' : 'text-white/95'}`}>
                  <span className="sm:hidden">{variant.shortLabel}</span>
                  <span className="hidden sm:inline">{variant.name}</span>
                </span>
              </button>
            )
          })}
        </div>
      </nav>
    </div>
  )
}

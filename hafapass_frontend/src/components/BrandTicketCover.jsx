import HafaPassMark from './HafaPassMark'
import { DEFAULT_BRAND_VARIANT } from '../utils/brandVariants'

// Precomputed fine guilloché security-pattern rosette (18 rotated ellipses) for Variant 2.
const GUILLOCHE_ANGLES = Array.from({ length: 18 }, (_, idx) => idx * 10)

/**
 * Shared top-art frame for the HåfaPass default deck ticket.
 * All 3 variants follow the exact 16:9 poster grid of the event covers:
 * - Top-left compact pill badge at left 5/6 (≈6%) and top 10.5%
 * - Title block vertically centered around ~46.5% of the art height, matching
 *   the event covers' poster title band within a few pixels across viewports
 * - Crisp inline SVG/CSS only, real HåfaPass tokens/fonts, and static under
 *   prefers-reduced-motion.
 */
function PosterBrandCover() {
  return (
    <div
      data-testid="brand-art-frame"
      data-brand-variant="1"
      className="relative aspect-video overflow-hidden bg-gradient-to-br from-[#032827] via-[#085856] to-[#0d9e96] text-white"
    >
      <svg
        aria-hidden="true"
        viewBox="0 0 1600 900"
        className="pointer-events-none absolute inset-0 h-full w-full"
        preserveAspectRatio="xMidYMid slice"
      >
        <defs>
          <radialGradient id="brand-v1-glow" cx="78%" cy="46%" r="48%">
            <stop offset="0%" stopColor="#53f5df" stopOpacity="0.18" />
            <stop offset="65%" stopColor="#0d9e96" stopOpacity="0.04" />
            <stop offset="100%" stopColor="#032827" stopOpacity="0" />
          </radialGradient>
        </defs>
        <rect width="1600" height="900" fill="url(#brand-v1-glow)" />
        {/* Concentric target-ring motif echoing the featured event posters, with subtle ticket notch mark */}
        <g opacity="0.16" stroke="#53f5df" strokeWidth="2.2" fill="none">
          <circle cx="1230" cy="450" r="340" />
          <circle cx="1230" cy="450" r="240" />
          <circle cx="1230" cy="450" r="140" />
          <line x1="890" y1="450" x2="1570" y2="450" />
          <line x1="1230" y1="110" x2="1230" y2="790" />
        </g>
        <g transform="translate(1158 378) scale(6)" opacity="0.16" stroke="#91feeb" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" fill="none">
          <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z" />
          <path d="M13 5v2" />
          <path d="M13 17v2" />
          <path d="M13 11v2" />
        </g>
        {/* Lagoon horizon contour */}
        <path d="M0 735 Q420 655 860 725 T1600 685 L1600 900 L0 900 Z" fill="#021c1b" opacity="0.52" />
      </svg>

      {/* Top-left pill badge — same position & compact scale as event posters */}
      <div className="pointer-events-none absolute left-5 top-[10.5%] z-10 sm:left-6">
        <span
          data-testid="brand-art-pill"
          className="inline-flex items-center rounded-full bg-gradient-to-r from-[#c9362e] to-[#e35d52] px-2.5 py-[4px] text-[10px] font-bold uppercase leading-none tracking-[0.14em] text-white shadow-soft sm:px-3 sm:py-[5px] sm:text-[10.5px]"
        >
          HåfaPass · Guam
        </span>
      </div>

      {/* Poster-style vertically centered title block */}
      <div
        data-testid="brand-art-title-block"
        className="absolute inset-x-0 top-[50%] z-10 -translate-y-1/2 px-5 sm:px-6"
      >
        <p className="font-display text-[1.45rem] font-extrabold uppercase leading-[1.04] tracking-[-0.025em] text-white sm:text-[1.72rem]">
          <span className="block">Your pass to</span>
          <span className="block text-brand-300">what’s on</span>
        </p>
        <p className="mt-1.5 max-w-[82%] truncate text-[11px] font-medium leading-snug text-brand-100/95 sm:mt-2 sm:text-[12px]">
          Concerts · Sports · Food · Community
        </p>
        <div aria-hidden="true" className="mt-2.5 h-[1.5px] w-24 rounded-full bg-brand-300/45 sm:mt-3 sm:w-28" />
      </div>
    </div>
  )
}

function MarkCenteredBrandCover() {
  return (
    <div
      data-testid="brand-art-frame"
      data-brand-variant="2"
      className="relative aspect-video overflow-hidden bg-gradient-to-br from-[#021f1e] via-[#063f3d] to-[#0a6b67] text-white"
    >
      {/* Soft lagoon halo behind the centered mark; whisper-quiet breath respects reduced motion */}
      <div
        aria-hidden="true"
        className="brand-cover-glow pointer-events-none absolute inset-0"
        style={{
          background:
            'radial-gradient(ellipse 56% 64% at 50% 48%, rgba(83, 245, 223, 0.2), rgba(13, 158, 150, 0.08) 48%, transparent 76%)',
        }}
      />

      {/* Printed-ticket guilloché security linework & fine pass border */}
      <svg
        aria-hidden="true"
        viewBox="0 0 1600 900"
        className="pointer-events-none absolute inset-0 h-full w-full"
        preserveAspectRatio="xMidYMid slice"
      >
        <g stroke="#53f5df" fill="none" opacity="0.15" strokeWidth="1.4">
          {GUILLOCHE_ANGLES.map(deg => (
            <ellipse
              key={deg}
              cx="800"
              cy="455"
              rx="395"
              ry="142"
              transform={`rotate(${deg} 800 455)`}
            />
          ))}
        </g>
        {/* Outer security wave ribbons along top and bottom */}
        <g stroke="#91feeb" fill="none" opacity="0.15" strokeWidth="1.45">
          <path d="M-40 120 Q160 72 360 120 T760 120 T1160 120 T1640 120" />
          <path d="M-40 138 Q160 90 360 138 T760 138 T1160 138 T1640 138" opacity="0.6" />
          <path d="M-40 772 Q160 724 360 772 T760 772 T1160 772 T1640 772" />
          <path d="M-40 790 Q160 742 360 790 T760 790 T1160 790 T1640 790" opacity="0.6" />
        </g>
        {/* Subtle inner hairline pass frame & corner ticks */}
        <rect
          x="52"
          y="46"
          width="1496"
          height="808"
          rx="28"
          fill="none"
          stroke="#53f5df"
          strokeOpacity="0.16"
          strokeWidth="1.5"
        />
        <g stroke="#53f5df" strokeOpacity="0.34" strokeWidth="2.5" strokeLinecap="round">
          <path d="M84 824 h24 M84 824 v-24" />
          <path d="M1516 824 h-24 M1516 824 v-24" />
          <path d="M1516 76 h-24 M1516 76 v24" />
        </g>
      </svg>

      {/* Top-left pill badge — same position & compact scale as event posters */}
      <div className="pointer-events-none absolute left-5 top-[10.5%] z-10 sm:left-6">
        <span
          data-testid="brand-art-pill"
          className="inline-flex items-center rounded-full border border-brand-300/35 bg-brand-950/65 px-2.5 py-[4px] text-[10px] font-bold uppercase leading-none tracking-[0.14em] text-brand-200 sm:px-3 sm:py-[5px] sm:text-[10.5px]"
        >
          Guam · Digital pass
        </span>
      </div>

      {/* Large centered HåfaPass brand mark + wordmark + one-line tagline */}
      <div
        data-testid="brand-art-title-block"
        className="absolute inset-x-0 top-[50%] z-10 flex -translate-y-1/2 flex-col items-center px-5 text-center sm:px-6"
      >
        <div className="flex items-center justify-center gap-2.5 sm:gap-3">
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-brand-700/90 ring-1 ring-brand-300/40 shadow-[0_8px_22px_rgba(2,28,27,0.45)] sm:h-11 sm:w-11">
            <HafaPassMark className="h-5 w-5 text-white sm:h-6 sm:w-6" />
          </span>
          <span className="font-display text-[1.95rem] font-bold leading-none tracking-[-0.03em] text-white sm:text-[2.25rem]">
            Håfa<span className="text-brand-300">Pass</span>
          </span>
        </div>
        <p className="mt-2 max-w-[88%] truncate text-[11.5px] font-medium leading-snug text-brand-100/90 sm:mt-2.5 sm:text-[12.5px]">
          Guam’s pass for live events &amp; local nights
        </p>
      </div>
    </div>
  )
}

function GuamBrandCover() {
  return (
    <div
      data-testid="brand-art-frame"
      data-brand-variant="3"
      className="relative aspect-video overflow-hidden text-white"
      style={{
        background:
          'linear-gradient(122deg, #032827 0%, #074446 44%, #11585c 68%, #7c3837 88%, #b94a3e 100%)',
      }}
    >
      {/* Dusk-over-lagoon sunset sky + minimal Chamorro latte-stone headland silhouette */}
      <svg
        aria-hidden="true"
        viewBox="0 0 1600 900"
        className="pointer-events-none absolute inset-0 h-full w-full"
        preserveAspectRatio="xMidYMid slice"
      >
        <defs>
          <radialGradient id="guam-sun-glow" cx="77%" cy="54%" r="44%">
            <stop offset="0%" stopColor="#fdba74" stopOpacity="0.46" />
            <stop offset="38%" stopColor="#f0564a" stopOpacity="0.22" />
            <stop offset="72%" stopColor="#0d9e96" stopOpacity="0.06" />
            <stop offset="100%" stopColor="#032827" stopOpacity="0" />
          </radialGradient>
          <linearGradient id="guam-sun-disc" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#fde68a" stopOpacity="0.88" />
            <stop offset="100%" stopColor="#f0564a" stopOpacity="0.58" />
          </linearGradient>
          <linearGradient id="guam-lagoon" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="#021f1e" stopOpacity="0.82" />
            <stop offset="68%" stopColor="#063938" stopOpacity="0.86" />
            <stop offset="100%" stopColor="#0b4647" stopOpacity="0.9" />
          </linearGradient>
        </defs>

        <rect width="1600" height="900" fill="url(#guam-sun-glow)" />

        {/* Setting sun disc resting gently over the lagoon */}
        <circle cx="1235" cy="520" r="142" fill="url(#guam-sun-disc)" opacity="0.55" />
        <circle cx="1235" cy="520" r="196" fill="none" stroke="#fdba74" strokeOpacity="0.2" strokeWidth="2" />

        {/* Distant reef & lagoon horizon layers */}
        <path d="M0 638 Q360 612 760 644 T1600 622 L1600 900 L0 900 Z" fill="#063b3c" opacity="0.62" />
        <path d="M0 704 Q430 668 920 712 T1600 688 L1600 900 L0 900 Z" fill="url(#guam-lagoon)" />

        {/* Subtle sunset shimmer lines across the water */}
        <g stroke="#fdba74" strokeLinecap="round" strokeWidth="3" opacity="0.28">
          <line x1="1125" y1="734" x2="1345" y2="734" />
          <line x1="1165" y1="762" x2="1305" y2="762" opacity="0.7" />
          <line x1="1195" y1="788" x2="1275" y2="788" opacity="0.45" />
        </g>

        {/* Continuous dark coastal headland sweeping into the right ridge carrying two authentic Chamorro latte stones */}
        <path d="M0 742 Q460 728 840 708 Q1120 652 1345 658 Q1485 662 1600 694 L1600 900 L0 900 Z" fill="#032221" opacity="0.92" />

        {/* Primary latte stone (haligi tapered pillar + flat-topped bowl tasa capstone) */}
        <g transform="translate(1225 656)">
          <path
            d="M-24 0 L-16 -124 L16 -124 L24 0 Z"
            fill="#042928"
            stroke="#91feeb"
            strokeOpacity="0.62"
            strokeWidth="2.4"
            strokeLinejoin="round"
          />
          <path
            d="M-50 -166 L50 -166 C50 -132 24 -120 0 -120 C-24 -120 -50 -132 -50 -166 Z"
            fill="#042928"
            stroke="#fde68a"
            strokeOpacity="0.78"
            strokeWidth="2.5"
            strokeLinejoin="round"
          />
        </g>

        {/* Companion smaller latte stone in perspective */}
        <g transform="translate(1352 666) scale(0.76)">
          <path
            d="M-24 0 L-16 -124 L16 -124 L24 0 Z"
            fill="#042928"
            stroke="#91feeb"
            strokeOpacity="0.5"
            strokeWidth="2.4"
            strokeLinejoin="round"
          />
          <path
            d="M-50 -166 L50 -166 C50 -132 24 -120 0 -120 C-24 -120 -50 -132 -50 -166 Z"
            fill="#042928"
            stroke="#fde68a"
            strokeOpacity="0.64"
            strokeWidth="2.5"
            strokeLinejoin="round"
          />
        </g>
      </svg>

      {/* Top-left pill badge — same position & compact scale as event posters */}
      <div className="pointer-events-none absolute left-5 top-[10.5%] z-10 sm:left-6">
        <span
          data-testid="brand-art-pill"
          className="inline-flex items-center rounded-full bg-gradient-to-r from-[#c9362e] to-[#f0564a] px-2.5 py-[4px] text-[10px] font-bold uppercase leading-none tracking-[0.14em] text-white shadow-soft sm:px-3 sm:py-[5px] sm:text-[10.5px]"
        >
          HåfaPass · Guam
        </span>
      </div>

      {/* Poster-style vertically centered title block */}
      <div
        data-testid="brand-art-title-block"
        className="absolute inset-x-0 top-[50%] z-10 -translate-y-1/2 px-5 sm:px-6"
      >
        <p className="font-display text-[1.45rem] font-extrabold uppercase leading-[1.03] tracking-[-0.025em] text-white sm:text-[1.72rem]">
          <span className="block">What’s on</span>
          <span className="block text-[#fdba74]">across Guam</span>
        </p>
        <p className="mt-1.5 max-w-[78%] truncate text-[11px] font-medium leading-snug text-brand-100/95 sm:mt-2 sm:text-[12px]">
          Music · Sports · Markets · Community
        </p>
        <div aria-hidden="true" className="mt-2.5 h-[1.5px] w-24 rounded-full bg-[#fdba74]/55 sm:mt-3 sm:w-28" />
      </div>
    </div>
  )
}

export default function BrandTicketCover({ variant = DEFAULT_BRAND_VARIANT }) {
  if (variant === 2) return <MarkCenteredBrandCover />
  if (variant === 3) return <GuamBrandCover />
  return <PosterBrandCover />
}

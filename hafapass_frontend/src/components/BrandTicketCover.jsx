import { useTranslation } from 'react-i18next'

export default function BrandTicketCover() {
  const { t } = useTranslation()
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
          {t('pass.home.brandArtBadge')}
        </span>
      </div>

      {/* Poster-style vertically centered title block */}
      <div
        data-testid="brand-art-title-block"
        className="absolute inset-x-0 top-[50%] z-10 -translate-y-1/2 px-5 sm:px-6"
      >
        <p className="font-display text-[1.45rem] font-extrabold uppercase leading-[1.04] tracking-[-0.025em] text-white sm:text-[1.72rem]">
          <span className="block">{t('pass.home.brandArtTitle')}</span>
          <span className="block text-brand-300">{t('pass.home.brandArtAccent')}</span>
        </p>
        <p className="mt-1.5 max-w-[82%] truncate text-[11px] font-medium leading-snug text-brand-100/95 sm:mt-2 sm:text-[12px]">
          {t('pass.home.brandArtCategories')}
        </p>
        <div aria-hidden="true" className="mt-2.5 h-[1.5px] w-24 rounded-full bg-brand-300/45 sm:mt-3 sm:w-28" />
      </div>
    </div>
  )
}


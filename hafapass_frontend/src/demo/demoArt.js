// Pure-ASCII SVG cover posters for preview-only demo events.
// Inlined as data:image/svg+xml;base64 URLs so they obey CSP img-src 'self' data:
// without adding static files to public/ or making external network requests.

function toSvgDataUrl(svg) {
  const compact = svg.replace(/\s+/g, ' ').trim()
  return `data:image/svg+xml;base64,${btoa(compact)}`
}

export const DEMO_EVENT_ART = {
  copa: toSvgDataUrl(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" width="1600" height="900">
      <defs>
        <linearGradient id="bg-copa" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#032827"/>
          <stop offset="55%" stop-color="#0b6563"/>
          <stop offset="100%" stop-color="#0d9e96"/>
        </linearGradient>
        <linearGradient id="ribbon-copa" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stop-color="#c9362e"/>
          <stop offset="100%" stop-color="#e35d52"/>
        </linearGradient>
      </defs>
      <rect width="1600" height="900" fill="url(#bg-copa)"/>
      <g opacity="0.14" stroke="#53f5df" stroke-width="2" fill="none">
        <circle cx="1220" cy="450" r="340"/>
        <circle cx="1220" cy="450" r="240"/>
        <circle cx="1220" cy="450" r="140"/>
        <line x1="880" y1="450" x2="1560" y2="450"/>
        <line x1="1220" y1="110" x2="1220" y2="790"/>
      </g>
      <path d="M0 730 Q420 650 860 720 T1600 680 L1600 900 L0 900 Z" fill="#021c1b" opacity="0.55"/>
      <rect x="96" y="108" width="232" height="44" rx="22" fill="url(#ribbon-copa)"/>
      <text x="212" y="137" text-anchor="middle" fill="#ffffff" font-family="system-ui, -apple-system, sans-serif" font-size="20" font-weight="700" letter-spacing="3">GUAM OPEN 2027</text>
      <text x="96" y="340" fill="#ffffff" font-family="system-ui, -apple-system, sans-serif" font-size="108" font-weight="800" letter-spacing="-2">COPA DE</text>
      <text x="96" y="458" fill="#53f5df" font-family="system-ui, -apple-system, sans-serif" font-size="108" font-weight="800" letter-spacing="-2">MARIANAS</text>
      <text x="96" y="540" fill="#d8f5f1" font-family="system-ui, -apple-system, sans-serif" font-size="34" font-weight="600">UOG Calvo Field House  |  Sat, Jan 30, 2027</text>
      <rect x="96" y="610" width="460" height="2" fill="#53f5df" opacity="0.45"/>
      <text x="96" y="662" fill="#b7e7e1" font-family="system-ui, -apple-system, sans-serif" font-size="24" font-weight="500">Fictional demo event artwork  |  HafaPass Preview</text>
    </svg>
  `),

  fdNight1: toSvgDataUrl(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" width="1600" height="900">
      <defs>
        <linearGradient id="bg-fd1" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#3a0d12"/>
          <stop offset="55%" stop-color="#8c1d24"/>
          <stop offset="100%" stop-color="#c9362e"/>
        </linearGradient>
      </defs>
      <rect width="1600" height="900" fill="url(#bg-fd1)"/>
      <g opacity="0.16" stroke="#fde68a" stroke-width="4" fill="none">
        <rect x="980" y="130" width="520" height="640" rx="18"/>
        <circle cx="1240" cy="450" r="130"/>
        <line x1="980" y1="450" x2="1500" y2="450"/>
        <path d="M1080 130 A160 160 0 0 0 1400 130"/>
        <path d="M1080 770 A160 160 0 0 1 1400 770"/>
      </g>
      <rect x="96" y="112" width="290" height="44" rx="22" fill="#fbbf24"/>
      <text x="241" y="141" text-anchor="middle" fill="#2a0a0d" font-family="system-ui, -apple-system, sans-serif" font-size="20" font-weight="800" letter-spacing="2">2-NIGHT SERIES  |  NIGHT 1</text>
      <text x="96" y="340" fill="#ffffff" font-family="system-ui, -apple-system, sans-serif" font-size="94" font-weight="800" letter-spacing="-2">FD ALUMNI</text>
      <text x="96" y="448" fill="#fde68a" font-family="system-ui, -apple-system, sans-serif" font-size="94" font-weight="800" letter-spacing="-2">BASKETBALL</text>
      <text x="96" y="534" fill="#fee2e2" font-family="system-ui, -apple-system, sans-serif" font-size="34" font-weight="600">Opening Tip-Off  |  Fri, Feb 12, 2027</text>
      <text x="96" y="646" fill="#fecaca" font-family="system-ui, -apple-system, sans-serif" font-size="24" font-weight="500">Phoenix Center Gym, Mangilao  |  Demo Preview</text>
    </svg>
  `),

  fdNight2: toSvgDataUrl(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" width="1600" height="900">
      <defs>
        <linearGradient id="bg-fd2" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#1c1917"/>
          <stop offset="55%" stop-color="#7f1d1d"/>
          <stop offset="100%" stop-color="#b45309"/>
        </linearGradient>
      </defs>
      <rect width="1600" height="900" fill="url(#bg-fd2)"/>
      <g opacity="0.18" stroke="#fef08a" stroke-width="3" fill="none">
        <polygon points="1240,160 1320,380 1540,380 1365,515 1430,730 1240,600 1050,730 1115,515 940,380 1160,380"/>
      </g>
      <rect x="96" y="112" width="310" height="44" rx="22" fill="#f59e0b"/>
      <text x="251" y="141" text-anchor="middle" fill="#1c1917" font-family="system-ui, -apple-system, sans-serif" font-size="20" font-weight="800" letter-spacing="2">CHAMPIONSHIP  |  NIGHT 2</text>
      <text x="96" y="340" fill="#ffffff" font-family="system-ui, -apple-system, sans-serif" font-size="94" font-weight="800" letter-spacing="-2">FD ALUMNI</text>
      <text x="96" y="448" fill="#fef08a" font-family="system-ui, -apple-system, sans-serif" font-size="94" font-weight="800" letter-spacing="-2">FINALS NIGHT</text>
      <text x="96" y="534" fill="#fef3c7" font-family="system-ui, -apple-system, sans-serif" font-size="34" font-weight="600">Bracket Finals &amp; Awards  |  Sat, Feb 13, 2027</text>
      <text x="96" y="646" fill="#fde68a" font-family="system-ui, -apple-system, sans-serif" font-size="24" font-weight="500">Phoenix Center Gym, Mangilao  |  Demo Preview</text>
    </svg>
  `),

  tumonAcoustic: toSvgDataUrl(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" width="1600" height="900">
      <defs>
        <linearGradient id="bg-tumon" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#1e1b4b"/>
          <stop offset="50%" stop-color="#312e81"/>
          <stop offset="100%" stop-color="#0f766e"/>
        </linearGradient>
      </defs>
      <rect width="1600" height="900" fill="url(#bg-tumon)"/>
      <circle cx="1220" cy="360" r="210" fill="#f97316" opacity="0.24"/>
      <circle cx="1220" cy="360" r="140" fill="#fb923c" opacity="0.3"/>
      <path d="M0 640 Q320 560 640 640 T1280 620 T1600 660 L1600 900 L0 900 Z" fill="#0c4a6e" opacity="0.5"/>
      <path d="M0 730 Q360 670 720 730 T1440 720 L1600 740 L1600 900 L0 900 Z" fill="#032827" opacity="0.72"/>
      <rect x="96" y="112" width="260" height="44" rx="22" fill="#fdba74"/>
      <text x="226" y="141" text-anchor="middle" fill="#1e1b4b" font-family="system-ui, -apple-system, sans-serif" font-size="20" font-weight="800" letter-spacing="2">SUNSET CONCERT</text>
      <text x="96" y="340" fill="#ffffff" font-family="system-ui, -apple-system, sans-serif" font-size="96" font-weight="800" letter-spacing="-2">TUMON BAY</text>
      <text x="96" y="448" fill="#fdba74" font-family="system-ui, -apple-system, sans-serif" font-size="88" font-weight="800" letter-spacing="-2">ACOUSTIC SESSIONS</text>
      <text x="96" y="534" fill="#e0e7ff" font-family="system-ui, -apple-system, sans-serif" font-size="34" font-weight="600">Starfruit Lane Pavilion  |  Sat, Feb 20, 2027</text>
      <text x="96" y="646" fill="#c7d2fe" font-family="system-ui, -apple-system, sans-serif" font-size="24" font-weight="500">Sold out waitlist preview  |  Demo Preview</text>
    </svg>
  `),

  nightMarket: toSvgDataUrl(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 900" width="1600" height="900">
      <defs>
        <linearGradient id="bg-market" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stop-color="#064e3b"/>
          <stop offset="55%" stop-color="#0b6563"/>
          <stop offset="100%" stop-color="#115e59"/>
        </linearGradient>
      </defs>
      <rect width="1600" height="900" fill="url(#bg-market)"/>
      <g opacity="0.24" fill="#fde68a">
        <circle cx="1040" cy="240" r="36"/>
        <circle cx="1180" cy="285" r="30"/>
        <circle cx="1320" cy="245" r="38"/>
        <circle cx="1450" cy="295" r="28"/>
      </g>
      <path d="M920 220 Q1180 330 1560 250" stroke="#fde68a" stroke-width="4" fill="none" opacity="0.45"/>
      <rect x="96" y="112" width="310" height="44" rx="22" fill="#53f5df"/>
      <text x="251" y="141" text-anchor="middle" fill="#032827" font-family="system-ui, -apple-system, sans-serif" font-size="20" font-weight="800" letter-spacing="2">UPCOMING PRE-LAUNCH</text>
      <text x="96" y="340" fill="#ffffff" font-family="system-ui, -apple-system, sans-serif" font-size="90" font-weight="800" letter-spacing="-2">GUAM NIGHT MARKET</text>
      <text x="96" y="448" fill="#53f5df" font-family="system-ui, -apple-system, sans-serif" font-size="84" font-weight="800" letter-spacing="-2">&amp; CRAFT FAIR</text>
      <text x="96" y="534" fill="#d1fae5" font-family="system-ui, -apple-system, sans-serif" font-size="34" font-weight="600">Pelican Row Plaza, Hagatna  |  Sat, Mar 6, 2027</text>
      <text x="96" y="646" fill="#a7f3d0" font-family="system-ui, -apple-system, sans-serif" font-size="24" font-weight="500">Early Bird tickets open Feb 15, 2027  |  Demo Preview</text>
    </svg>
  `),
}

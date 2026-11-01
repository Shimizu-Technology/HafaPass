import colors from 'tailwindcss/colors'

/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  // Shared semantic variants must retain their complete component rules even
  // when a variant has no literal consumer in the current source scan.
  safelist: ['btn-primary', 'btn-teal', 'btn-danger', 'btn-secondary', 'btn-ghost'],
  // HåfaPass has one light theme. Without this, a stray dark: utility would
  // follow the phone's dark mode and put dark surfaces inside light pages.
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        brand: {
          50:  '#effefb',
          100: '#c8fff5',
          200: '#91feeb',
          300: '#53f5df',
          400: '#20e0cc',
          500: '#0d9e96',  // warmer, more vibrant teal
          600: '#087e7a',
          700: '#0b6563',
          800: '#0e504f',
          900: '#104342',
          950: '#032827',
        },
        accent: {
          50:  '#fff5f4',
          100: '#ffe2df',
          200: '#ffcbc5',
          300: '#ffa89f',
          400: '#ff7a6e',
          500: '#f0564a',  // slightly brighter coral
          600: '#dd3d33',
          700: '#ba3028',
          800: '#9a2c26',
          900: '#802b27',
        },
        neutral: {
          50:  '#f8fafc',
          100: '#f1f5f9',
          200: '#e2e8f0',
          300: '#cbd5e1',
          400: '#94a3b8',
          500: '#64748b',
          600: '#475569',
          700: '#334155',
          800: '#1e293b',
          900: '#0f172a',
          950: '#020617',
        },
        surface: {
          DEFAULT: '#f8fafb',
          raised: '#ffffff',
          overlay: 'rgba(255, 255, 255, 0.8)',
        },
        // Roles keep readable UI colors independent from decorative brand shades.
        content: {
          DEFAULT: '#0f172a',
          muted: '#475569',
          inverse: '#ffffff',
          'inverse-muted': '#cbd5e1',
        },
        action: {
          DEFAULT: '#c9362e',
          hover: '#ad2b24',
          teal: '#0b6563',
          'teal-hover': '#0e504f',
          danger: '#b91c1c',
          'danger-hover': '#991b1b',
        },
        focus: '#087e7a',
        // Focus indicator on brand-950 surfaces (see .surface-dark in index.css).
        'focus-on-dark': '#53f5df',
        // Status roles. Use these instead of raw emerald/amber/red/sky so
        // buyer messages share one palette.
        success: colors.emerald,
        warning: colors.amber,
        danger: colors.red,
        info: colors.sky,
      },
      fontFamily: {
        sans: ['"Plus Jakarta Sans Variable"', 'system-ui', '-apple-system', 'sans-serif'],
        display: ['"Space Grotesk Variable"', '"Plus Jakarta Sans Variable"', 'system-ui', 'sans-serif'],
      },
      transitionTimingFunction: {
        // Strong ease-out for UI feedback: fast start, gentle settle.
        'out-strong': 'cubic-bezier(0.23, 1, 0.32, 1)',
      },
      boxShadow: {
        'soft': '0 1px 3px rgba(0,0,0,0.04), 0 1px 2px rgba(0,0,0,0.06)',
        'card': '0 1px 3px rgba(0,0,0,0.04), 0 4px 12px rgba(0,0,0,0.03)',
        'card-hover': '0 4px 16px rgba(0,0,0,0.08), 0 1px 3px rgba(0,0,0,0.04)',
        'glow-brand': '0 4px 24px rgba(13,158,150,0.15)',
        'glow-accent': '0 4px 24px rgba(240,86,74,0.2)',
        'float': '0 8px 32px rgba(0,0,0,0.08), 0 2px 8px rgba(0,0,0,0.04)',
      },
    },
  },
  future: { hoverOnlyWhenSupported: true },
  plugins: [],
}

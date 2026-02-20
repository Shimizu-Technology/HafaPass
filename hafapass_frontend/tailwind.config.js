/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        brand: {
          50:  '#f0fdfc',
          100: '#ccfbf6',
          200: '#9af5ed',
          300: '#5fe9df',
          400: '#2dd4c8',
          500: '#0e7c7b',  // warm ocean teal — Tumon Bay
          600: '#0a6362',
          700: '#0a5c5b',
          800: '#0c4a49',
          900: '#0e3d3c',
          950: '#042525',
        },
        accent: {
          50:  '#fef3f2',
          100: '#ffe1df',
          200: '#ffc9c5',
          300: '#ffa39d',
          400: '#fc7168',
          500: '#e85a4f',  // coral-red — sunset + Ambros harmony
          600: '#d64545',
          700: '#b33a3a',
          800: '#943434',
          900: '#7c3232',
        },
        neutral: {
          50:  '#fafaf9',
          100: '#f5f5f4',
          200: '#e7e5e4',
          300: '#d6d3d1',
          400: '#a8a29e',
          500: '#78716c',
          600: '#57534e',
          700: '#44403c',
          800: '#292524',
          900: '#1c1917',
          950: '#0c0a09',
        },
      },
      fontFamily: {
        sans: ['"Plus Jakarta Sans"', 'system-ui', '-apple-system', 'sans-serif'],
        display: ['"Plus Jakarta Sans"', 'system-ui', '-apple-system', 'sans-serif'],
      },
      animation: {
        'fade-in': 'fadeIn 0.5s ease-out',
        'fade-up': 'fadeUp 0.6s cubic-bezier(0.22, 1, 0.36, 1)',
        'shimmer': 'shimmer 2s linear infinite',
      },
      keyframes: {
        fadeIn: {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        fadeUp: {
          '0%': { opacity: '0', transform: 'translateY(20px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        shimmer: {
          '0%': { transform: 'translateX(-100%)' },
          '100%': { transform: 'translateX(100%)' },
        },
      },
    },
  },
  plugins: [],
}

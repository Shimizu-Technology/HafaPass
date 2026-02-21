import { useTranslation } from 'react-i18next'
import { useState, useRef, useEffect } from 'react'
import { Globe, ChevronDown } from 'lucide-react'

const LANGUAGES = [
  { code: 'en', label: 'English', short: 'EN' },
  { code: 'ch', label: 'CHamoru', short: 'CH' },
  { code: 'ja', label: '日本語', short: 'JP' }
]

export default function LanguageSwitcher({ isDarkMode = false }) {
  const { i18n } = useTranslation()
  const [open, setOpen] = useState(false)
  const ref = useRef(null)

  const currentLang = LANGUAGES.find(l => l.code === i18n.language) || LANGUAGES[0]

  useEffect(() => {
    const handleClickOutside = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false)
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  const handleChange = (code) => {
    i18n.changeLanguage(code)
    setOpen(false)
  }

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen(!open)}
        className={`flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-sm font-medium transition-colors ${
          isDarkMode
            ? 'text-neutral-300 hover:text-white hover:bg-white/10'
            : 'text-neutral-500 hover:text-neutral-900 hover:bg-neutral-100/80'
        }`}
        aria-label="Change language"
      >
        <Globe className="w-4 h-4" />
        <span>{currentLang.short}</span>
        <ChevronDown className={`w-3 h-3 transition-transform ${open ? 'rotate-180' : ''}`} />
      </button>

      {open && (
        <div className="absolute right-0 top-full mt-1 bg-white rounded-xl shadow-lg border border-neutral-200 py-1 min-w-[140px] z-50">
          {LANGUAGES.map(lang => (
            <button
              key={lang.code}
              onClick={() => handleChange(lang.code)}
              className={`w-full text-left px-4 py-2 text-sm transition-colors ${
                lang.code === i18n.language
                  ? 'text-brand-600 bg-brand-50 font-medium'
                  : 'text-neutral-700 hover:bg-neutral-50'
              }`}
            >
              <span className="font-medium">{lang.short}</span>
              <span className="ml-2 text-neutral-500">{lang.label}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

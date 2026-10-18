import { useTranslation } from 'react-i18next'
import { useState, useRef, useEffect, useId } from 'react'
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
  const trigger = useRef(null)
  const id = useId()
  const currentLang = LANGUAGES.find(l => l.code === i18n.language?.split('-')[0]) || LANGUAGES[0]

  useEffect(() => {
    const outside = event => { if (!ref.current?.contains(event.target)) setOpen(false) }
    document.addEventListener('pointerdown', outside)
    return () => document.removeEventListener('pointerdown', outside)
  }, [])
  const close = () => { setOpen(false); trigger.current?.focus() }

  return <div ref={ref} className="relative" onBlur={event => {
    if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false)
  }} onKeyDown={event => {
    if (event.key === 'Escape' && open) { event.preventDefault(); event.stopPropagation(); close() }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    event.preventDefault()
    if (!open) { setOpen(true); return }
    const options = [...ref.current.querySelectorAll('[data-language]')]
    const index = options.indexOf(document.activeElement)
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1
      : index < 0 ? (event.key === 'ArrowUp' ? options.length - 1 : 0)
      : (index + (event.key === 'ArrowUp' ? -1 : 1) + options.length) % options.length
    options[next]?.focus()
  }}>
    <button ref={trigger} type="button" onClick={() => setOpen(value => !value)}
      className={`flex min-h-11 items-center gap-1.5 rounded-lg px-3 text-sm font-medium ${isDarkMode ? 'text-neutral-200 hover:bg-white/10' : 'text-neutral-700 hover:bg-neutral-100'}`}
      aria-label={`Change language, ${currentLang.label}`} aria-expanded={open} aria-controls={id}>
      <Globe className="h-4 w-4" aria-hidden="true" /><span>{currentLang.short}</span>
      <ChevronDown className="h-3 w-3" aria-hidden="true" />
    </button>
    {open && <div id={id} role="group" aria-label="Available languages" className="absolute right-0 top-full z-50 mt-1 min-w-[160px] rounded-xl border border-neutral-200 bg-white py-1 shadow-lg">
      {LANGUAGES.map(lang => <button key={lang.code} type="button" data-language={lang.code}
        aria-pressed={lang.code === currentLang.code} lang={lang.code}
        onClick={() => { i18n.changeLanguage(lang.code); close() }}
        className={`flex min-h-11 w-full items-center gap-2 px-4 py-2 text-left text-sm ${lang.code === currentLang.code ? 'bg-brand-50 font-semibold text-brand-800' : 'text-neutral-700 hover:bg-neutral-50'}`}>
        <span>{lang.short}</span><span>{lang.label}</span>
      </button>)}
    </div>}
  </div>
}

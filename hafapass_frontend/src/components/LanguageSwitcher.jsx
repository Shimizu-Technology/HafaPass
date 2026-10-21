import { useTranslation } from 'react-i18next'
import { useState, useRef, useEffect, useId } from 'react'
import { Globe, ChevronDown, Check } from 'lucide-react'
import { getEnabledLanguages, languageFor } from '../utils/locale'

export default function LanguageSwitcher({ isDarkMode = false }) {
  const { t, i18n } = useTranslation()
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  const trigger = useRef(null)
  const id = useId()
  const currentLang = languageFor(i18n.language)
  const languages = getEnabledLanguages()

  useEffect(() => {
    const outside = event => { if (!ref.current?.contains(event.target)) setOpen(false) }
    document.addEventListener('pointerdown', outside)
    return () => document.removeEventListener('pointerdown', outside)
  }, [])
  const close = () => { setOpen(false); trigger.current?.focus() }
  // Nothing to choose until a second language is enabled (VITE_ENABLED_LOCALES).
  if (languages.length < 2) return null

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
      className={`flex min-h-11 items-center gap-1.5 rounded-lg px-3 text-sm font-medium transition-colors duration-150 ease-out-strong ${isDarkMode ? 'text-neutral-200 hover:bg-white/10' : 'text-neutral-700 hover:bg-neutral-100'}`}
      aria-label={t('language.change', { language: currentLang.label, defaultValue: 'Change language, {{language}}' })} aria-expanded={open} aria-controls={id}>
      <Globe className="h-4 w-4" aria-hidden="true" /><span lang={currentLang.html}>{currentLang.short}</span>
      <ChevronDown className="h-3 w-3" aria-hidden="true" />
    </button>
    {open && <div id={id} role="group" aria-label={t('language.available', { defaultValue: 'Available languages' })} className="absolute right-0 top-full z-50 mt-1 max-h-[min(24rem,calc(100dvh-6rem))] w-56 max-w-[calc(100vw-2rem)] overflow-y-auto overscroll-contain rounded-xl border border-neutral-200 bg-white py-1 shadow-lg">
      {languages.map(lang => {
        const selected = lang.code === currentLang.code
        return <button key={lang.code} type="button" data-language={lang.code}
          aria-pressed={selected} lang={lang.html}
          onClick={() => { i18n.changeLanguage(lang.code); close() }}
          className={`flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left text-sm transition-colors duration-150 ease-out-strong ${selected ? 'bg-brand-50 font-semibold text-brand-800' : 'text-neutral-700 hover:bg-neutral-50'}`}>
          <span className="min-w-0 flex-1">
            <span className="block">{lang.label}</span>
            {lang.label !== lang.englishName && <span lang="en" className="block text-xs font-normal text-neutral-500">{lang.englishName}</span>}
          </span>
          {selected && <Check className="h-4 w-4 shrink-0" aria-hidden="true" />}
        </button>
      })}
    </div>}
  </div>
}

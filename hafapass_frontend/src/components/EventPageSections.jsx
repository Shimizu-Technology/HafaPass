import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { X, ChevronLeft, ChevronRight, Play, Globe, Instagram, Facebook, Youtube, Music2, Link2 } from 'lucide-react'
import { safeLink, videoEmbed } from '../utils/eventPageDesign'

const linkIcons = {
  website: Globe,
  instagram: Instagram,
  facebook: Facebook,
  tiktok: Music2,
  youtube: Youtube,
  other: Link2,
}

function Gallery({ photos }) {
  const { t } = useTranslation()
  const [active, setActive] = useState(-1)
  const closeRef = useRef(null)
  const returnRef = useRef(null)
  const touch = useRef(null)
  const open = active >= 0
  useEffect(() => {
    if (!open) return undefined
    closeRef.current?.focus()
    const onKey = (event) => {
      if (event.key === 'Escape') setActive(-1)
      if (event.key === 'ArrowRight') setActive((index) => (index + 1) % photos.length)
      if (event.key === 'ArrowLeft') setActive((index) => (index - 1 + photos.length) % photos.length)
      if (event.key === 'Tab') {
        const controls = [...document.querySelectorAll('[data-gallery-dialog] button')]
        const index = controls.indexOf(document.activeElement)
        if (index === -1) {
          event.preventDefault()
          controls[0]?.focus()
        }
        if (event.shiftKey && index === 0) {
          event.preventDefault()
          controls.at(-1)?.focus()
        }
        if (!event.shiftKey && index === controls.length - 1) {
          event.preventDefault()
          controls[0]?.focus()
        }
      }
    }
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('keydown', onKey)
      returnRef.current?.focus()
    }
  }, [open, photos.length])
  if (!photos?.length) return null
  return (
    <>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {photos.map((photo, index) => (
          <button
            key={`${photo.url}-${index}`}
            type="button"
            className="overflow-hidden rounded-xl focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-700"
            onClick={(event) => {
              returnRef.current = event.currentTarget
              setActive(index)
            }}
            aria-label={t('buyer.EventDetail.openPhoto', { number: index + 1 })}
          >
            <img
              src={photo.url}
              alt={photo.alt}
              loading="lazy"
              width="480"
              height="320"
              className="aspect-[3/2] w-full object-cover"
            />
          </button>
        ))}
      </div>
      {active >= 0 && (
        <div
          data-gallery-dialog
          role="dialog"
          aria-modal="true"
          aria-label={t('buyer.EventDetail.photoGallery')}
          className="fixed inset-0 z-[70] flex flex-col items-center justify-center bg-black/95 p-4 text-white"
          onTouchStart={(event) => {
            touch.current = event.touches[0].clientX
          }}
          onTouchEnd={(event) => {
            if (touch.current === null) return
            const delta = event.changedTouches[0].clientX - touch.current
            if (Math.abs(delta) > 50)
              setActive((index) => (index + (delta < 0 ? 1 : photos.length - 1)) % photos.length)
            touch.current = null
          }}
        >
          <button
            ref={closeRef}
            type="button"
            onClick={() => setActive(-1)}
            className="absolute right-4 top-4 rounded-lg p-3 focus-visible:outline-2 focus-visible:outline-white"
            aria-label={t('buyer.EventDetail.closePhoto')}
          >
            <X />
          </button>
          <img
            src={photos[active].url}
            alt={photos[active].alt}
            width="1200"
            height="800"
            className="max-h-[75vh] max-w-full object-contain"
          />
          {photos[active].caption && <p className="mt-3 max-w-xl text-center text-sm">{photos[active].caption}</p>}
          <div className="mt-4 flex gap-8">
            <button
              type="button"
              className="rounded-lg p-3 focus-visible:outline-2 focus-visible:outline-white"
              aria-label={t('buyer.EventDetail.previousPhoto')}
              onClick={() => setActive((index) => (index - 1 + photos.length) % photos.length)}
            >
              <ChevronLeft />
            </button>
            <span className="self-center">
              {active + 1} / {photos.length}
            </span>
            <button
              type="button"
              className="rounded-lg p-3 focus-visible:outline-2 focus-visible:outline-white"
              aria-label={t('buyer.EventDetail.nextPhoto')}
              onClick={() => setActive((index) => (index + 1) % photos.length)}
            >
              <ChevronRight />
            </button>
          </div>
        </div>
      )}
    </>
  )
}

function Video({ url }) {
  const { t } = useTranslation()
  const [loaded, setLoaded] = useState(false)
  const embed = videoEmbed(url)
  if (!embed) return null
  return loaded ? (
    <iframe
      title={t('buyer.EventDetail.eventVideo')}
      src={embed}
      allow="accelerometer; autoplay; encrypted-media; picture-in-picture"
      allowFullScreen
      loading="lazy"
      className="aspect-video w-full rounded-xl border-0"
    />
  ) : (
    <button
      type="button"
      onClick={() => setLoaded(true)}
      className="flex aspect-video w-full items-center justify-center gap-3 rounded-xl bg-neutral-900 text-white"
    >
      <Play aria-hidden="true" />
      {t('buyer.EventDetail.playVideo')}
    </button>
  )
}

export default function EventPageSections({ design }) {
  const { t } = useTranslation()
  return (design?.sections || [])
    .filter((section) => section.enabled)
    .map((section) => {
      const items = section.items || []
      if (section.type !== 'video' && section.type !== 'gallery' && !items.length) return null
      if (section.type === 'gallery' && !design.gallery?.length) return null
      const title = t(`buyer.EventDetail.design.${section.type}`)
      return (
        <section key={section.type} className="mb-8" aria-label={title}>
          <h2 className="event-heading mb-3 text-lg font-semibold">{title}</h2>
          {section.type === 'gallery' && <Gallery photos={design.gallery} />}
          {section.type === 'video' && <Video url={section.url} />}
          {section.type === 'lineup' && (
            <div className="grid gap-3 sm:grid-cols-2">
              {items.map((item, index) => (
                <div key={index} className="flex min-w-0 items-center gap-3 rounded-xl border border-neutral-200 p-3">
                  {item.photo_url && (
                    <img
                      src={item.photo_url}
                      alt=""
                      loading="lazy"
                      width="64"
                      height="64"
                      className="h-16 w-16 rounded-lg object-cover"
                    />
                  )}
                  <div className="min-w-0">
                    <p className="font-semibold break-words">
                      {item.url && safeLink(item.url) ? (
                        <a
                          href={safeLink(item.url)}
                          rel="noopener noreferrer nofollow"
                          target="_blank"
                          className="event-link underline"
                        >
                          {item.name}
                        </a>
                      ) : (
                        item.name
                      )}
                    </p>
                    {item.role && <p className="text-sm text-neutral-600">{item.role}</p>}
                  </div>
                </div>
              ))}
            </div>
          )}
          {section.type === 'schedule' && (
            <ol className="space-y-2">
              {items.map((item, index) => (
                <li key={index} className="flex gap-4 rounded-xl border border-neutral-200 p-3">
                  <time className="font-semibold event-link">{item.time}</time>
                  <div>
                    <p className="font-semibold">{item.title}</p>
                    {item.note && <p className="text-sm text-neutral-600">{item.note}</p>}
                  </div>
                </li>
              ))}
            </ol>
          )}
          {section.type === 'faq' && (
            <div className="space-y-2">
              {items.map((item, index) => (
                <details key={index} className="rounded-xl border border-neutral-200 p-4">
                  <summary className="cursor-pointer font-semibold">{item.question}</summary>
                  <p className="mt-2 whitespace-pre-wrap text-neutral-600">{item.answer}</p>
                </details>
              ))}
            </div>
          )}
          {section.type === 'sponsors' && (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {items.map((item, index) => {
                const content = (
                  <>
                    <img
                      src={item.logo_url}
                      alt=""
                      loading="lazy"
                      width="160"
                      height="96"
                      className="mx-auto h-24 w-full object-contain"
                    />
                    <span className="mt-2 block text-center text-sm font-medium">{item.name}</span>
                  </>
                )
                return item.url && safeLink(item.url) ? (
                  <a
                    key={index}
                    href={safeLink(item.url)}
                    rel="noopener noreferrer nofollow"
                    target="_blank"
                    className="event-link rounded-xl border border-neutral-200 p-3"
                  >
                    {content}
                  </a>
                ) : (
                  <div key={index} className="rounded-xl border border-neutral-200 p-3">
                    {content}
                  </div>
                )
              })}
            </div>
          )}
          {section.type === 'links' && (
            <div className="flex flex-wrap gap-2">
              {items.map((item, index) => {
                const Icon = linkIcons[item.kind] || Link2
                return (
                  safeLink(item.url) && (
                    <a
                      key={index}
                      href={safeLink(item.url)}
                      target="_blank"
                      rel="noopener noreferrer nofollow"
                      className="event-link inline-flex min-h-11 items-center gap-2 rounded-xl border border-neutral-200 px-4 text-sm font-semibold"
                    >
                      <Icon aria-hidden="true" size={18} />
                      {item.label}
                    </a>
                  )
                )
              })}
            </div>
          )}
        </section>
      )
    })
}

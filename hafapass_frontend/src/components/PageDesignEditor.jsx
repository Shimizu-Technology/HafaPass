import { useState } from 'react'
import { ChevronDown, ChevronUp, Plus, Trash2 } from 'lucide-react'
import CoverImageUpload from './CoverImageUpload'
import EventDescription from './EventDescription'
import EventPageSections from './EventPageSections'
import TicketTypesSection from './TicketTypesSection'
import { AllInPriceNote, SellerLine } from './PriceDisclosure'
import { ACCENT_PRESETS, SECTION_TYPES, accentStyle, defaultDesign, focalPosition, normalizePageCustomization, approvedImageUrl } from '../utils/eventPageDesign'

const TITLES = {
  lineup: 'Lineup / performers / speakers',
  schedule: 'Schedule',
  faq: 'FAQ',
  sponsors: 'Sponsors / partners',
  video: 'Video',
  links: 'Links',
  gallery: 'Photo gallery',
}
const FIELDS = {
  lineup: [
    ['name', 'Name'],
    ['role', 'Role (optional)'],
    ['url', 'Link (optional)'],
  ],
  schedule: [
    ['time', 'Time'],
    ['title', 'Title'],
    ['note', 'Note (optional)'],
  ],
  faq: [
    ['question', 'Question'],
    ['answer', 'Answer'],
  ],
  sponsors: [
    ['name', 'Name'],
    ['url', 'Link (optional)'],
  ],
  links: [
    ['label', 'Label'],
    ['url', 'Website or social URL'],
    ['kind', 'Type: website, instagram, facebook, tiktok, youtube, other'],
  ],
}
const EMPTY = {
  lineup: { name: '' },
  schedule: { time: '', title: '' },
  faq: { question: '', answer: '' },
  sponsors: { name: '', logo_url: '' },
  links: { label: '', url: '', kind: 'website' },
}

function swapItems(items, first, second) {
  const next = [...items]
  const selected = next[first]
  next[first] = next[second]
  next[second] = selected
  return next
}

function ItemEditor({ type, item, onChange }) {
  return (
    <div className="grid gap-2 sm:grid-cols-2">
      {FIELDS[type].map(([field, label]) => (
        <label key={field} className="text-xs font-medium text-neutral-600">
          {label}
          {field === 'kind' ? (
            <select
              className="input mt-1 min-h-11"
              value={item[field] || 'website'}
              onChange={(event) => onChange({ ...item, [field]: event.target.value })}
            >
              {['website', 'instagram', 'facebook', 'tiktok', 'youtube', 'other'].map((kind) => (
                <option key={kind} value={kind}>
                  {kind}
                </option>
              ))}
            </select>
          ) : field === 'answer' || field === 'note' ? (
            <textarea
              className="input mt-1 min-h-11"
              rows="2"
              maxLength={field === 'answer' ? 1000 : 200}
              value={item[field] || ''}
              onChange={(event) => onChange({ ...item, [field]: event.target.value })}
            />
          ) : (
            <input
              className="input mt-1 min-h-11"
              maxLength={field.includes('url') ? 2048 : 200}
              value={item[field] || ''}
              onChange={(event) => {
                const next = { ...item, [field]: event.target.value }
                if (field === 'url' && type !== 'links' && !event.target.value.trim()) delete next.url
                onChange(next)
              }}
            />
          )}
        </label>
      ))}
    </div>
  )
}

export function DescriptionToolbar({ description, onDescriptionChange, onFormatChange }) {
  const insertMarkup = (marker) => {
    const textarea = document.getElementById('description')
    const start = textarea?.selectionStart ?? description.length
    const end = textarea?.selectionEnd ?? start
    const selected = description.slice(start, end) || 'text'
    const replacement =
      marker === 'link'
        ? `[${selected}](https://)`
        : marker === 'heading'
          ? `## ${selected}`
          : marker === 'list'
            ? `- ${selected}`
            : `${marker}${selected}${marker}`
    onDescriptionChange(description.slice(0, start) + replacement + description.slice(end))
    onFormatChange('markdown')
    requestAnimationFrame(() => textarea?.focus())
  }
  return (
    <div role="toolbar" aria-label="Description formatting" className="mb-2 flex flex-wrap gap-2">
      {[
        ['B', '**'],
        ['I', '*'],
        ['H', 'heading'],
        ['List', 'list'],
        ['Link', 'link'],
      ].map(([label, marker]) => (
        <button
          key={label}
          type="button"
          className="btn-secondary min-h-11 min-w-11"
          onClick={() => insertMarkup(marker)}
        >
          {label}
        </button>
      ))}
    </div>
  )
}

export default function PageDesignEditor({
  event,
  design,
  onChange,
  description,
  coverUrl,
  onCoverUploaded,
  eventId,
  disabled,
}) {
  const [previewWidth, setPreviewWidth] = useState('phone')
  const [previewOpen, setPreviewOpen] = useState(false)
  const page = normalizePageCustomization(design)
  const sections = page.sections
  const change = (patch) => onChange(previous => {
    const current = normalizePageCustomization(previous)
    return { ...current, ...(typeof patch === 'function' ? patch(current) : patch) }
  })
  const updateSection = (type, patch) =>
    change(current => ({
      sections: current.sections.map(section => section.type === type
        ? { ...section, ...(typeof patch === 'function' ? patch(section) : patch) } : section),
    }))
  const moveSection = (index, delta) => {
    const type = sections[index].type
    change(current => {
      const next = [...current.sections]
      const position = next.findIndex(section => section.type === type)
      if (position < 0 || position + delta < 0 || position + delta >= next.length) return {}
      const [section] = next.splice(position, 1)
      next.splice(position + delta, 0, section)
      return { sections: next }
    })
  }
  return (
    <section
      aria-labelledby="page-design-heading"
      className="space-y-6 rounded-2xl border border-neutral-200 p-4 sm:p-6"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id="page-design-heading" className="text-xl font-semibold">
            Page design
          </h2>
          <p className="mt-1 text-sm text-neutral-600">
            Make the page yours while HåfaPass keeps tickets and checkout consistent.
          </p>
        </div>
        <button type="button" className="btn-secondary min-h-11" onClick={() => onChange(previous => ({
          ...defaultDesign(),
          ...(normalizePageCustomization(previous).description_format === 'markdown' ? { description_format: 'markdown' } : {}),
        }))}>
          Reset to HåfaPass default look
        </button>
      </div>
      <div>
        <p className="mb-2 text-sm font-semibold">Accent color</p>
        <div className="flex flex-wrap gap-3">
          {ACCENT_PRESETS.map((color) => (
            <button
              key={color}
              type="button"
              className={`h-11 w-11 rounded-full border-2 ${page.accent === color ? 'ring-2 ring-offset-2 ring-neutral-900' : ''}`}
              style={{ backgroundColor: color }}
              aria-label={`Use ${color} accent`}
              aria-pressed={page.accent === color}
              onClick={() => change({ accent: color })}
            />
          ))}
          <label className="flex min-h-11 items-center gap-2 text-sm">
            Custom hex{' '}
            <input
              aria-label="Custom accent hex"
              aria-invalid={Boolean(page.accent && !/^#[0-9a-f]{6}$/i.test(page.accent))}
              className="input w-28"
              placeholder="#087e82"
              maxLength="7"
              value={page.accent || ''}
              onChange={(event) => change({ accent: event.target.value })}
            />
          </label>
        </div>
        {page.accent && !/^#[0-9a-f]{6}$/i.test(page.accent) && (
          <p role="alert" className="mt-2 text-sm text-red-700">
            Enter a six-digit hex color, such as #087e82.
          </p>
        )}
        <p className="mt-2 text-xs text-neutral-600">
          Text contrast adjusts automatically. Leave blank for HåfaPass colors.
        </p>
      </div>
      <div>
        <CoverImageUpload
          eventId={eventId}
          currentUrl={coverUrl}
          imageAssetHost={event.image_asset_host}
          onUploaded={onCoverUploaded}
          disabled={disabled}
          focalPoint={page.focal_point}
          onFocalChange={(point) => change({ focal_point: point })}
        />
        <p className="mt-2 text-xs text-neutral-600">
          Tap the cover to choose the focal point for phone and desktop crops.
        </p>
      </div>
      <div className="space-y-3">
        <h3 className="text-base font-semibold">Optional sections</h3>
        {sections.map((section, index) => (
          <div key={section.type} className="rounded-xl border border-neutral-200 p-3">
            <div className="flex flex-wrap items-center gap-2">
              <label className="flex min-h-11 flex-1 items-center gap-2 font-semibold">
                <input
                  type="checkbox"
                  checked={section.enabled}
                  onChange={(event) => updateSection(section.type, { enabled: event.target.checked })}
                />
                {TITLES[section.type]}
              </label>
              <button
                type="button"
                className="rounded-lg border p-2.5 disabled:opacity-40"
                aria-label={`Move ${TITLES[section.type]} up`}
                disabled={index === 0}
                onClick={() => moveSection(index, -1)}
              >
                <ChevronUp size={20} />
              </button>
              <button
                type="button"
                className="rounded-lg border p-2.5 disabled:opacity-40"
                aria-label={`Move ${TITLES[section.type]} down`}
                disabled={index === sections.length - 1}
                onClick={() => moveSection(index, 1)}
              >
                <ChevronDown size={20} />
              </button>
            </div>
            {section.enabled && (
              <div className="mt-3 space-y-3">
                {section.type === 'video' ? (
                  <label className="text-sm">
                    YouTube or Vimeo URL
                    <input
                      className="input mt-1"
                      value={section.url || ''}
                      onChange={(event) => updateSection(section.type, { url: event.target.value })}
                    />
                  </label>
                ) : section.type === 'gallery' ? (
                  <>
                    <p className="text-sm text-neutral-600">Up to 8 photos. Alt text is required.</p>
                    {page.gallery.map((photo, photoIndex) => (
                      <div key={photoIndex} className="rounded-lg bg-neutral-50 p-3">
                        {approvedImageUrl(photo.url, event.image_asset_host) && <img
                          src={photo.url}
                          alt=""
                          width="160"
                          height="100"
                          className="mb-2 h-24 w-40 rounded object-cover"
                        />}
                        <div className="grid gap-2 sm:grid-cols-2">
                          <label className="text-xs">
                            Alt text (required)
                            <input
                              className="input mt-1"
                              value={photo.alt}
                              aria-invalid={!photo.alt.trim()}
                              maxLength="200"
                              onChange={(event) =>
                                change(current => ({
                                  gallery: current.gallery.map((p, i) =>
                                    i === photoIndex ? { ...p, alt: event.target.value } : p
                                  ),
                                }))
                              }
                            />
                          </label>
                          <label className="text-xs">
                            Caption
                            <input
                              className="input mt-1"
                              value={photo.caption || ''}
                              maxLength="300"
                              onChange={(event) =>
                                change(current => ({
                                  gallery: current.gallery.map((p, i) =>
                                    i === photoIndex ? { ...p, caption: event.target.value } : p
                                  ),
                                }))
                              }
                            />
                          </label>
                        </div>
                        <div className="mt-2 flex gap-2">
                          <button
                            type="button"
                            className="btn-secondary"
                            disabled={photoIndex === 0}
                            onClick={() => {
                              change(current => ({ gallery: swapItems(current.gallery, photoIndex, photoIndex - 1) }))
                            }}
                          >
                            Up
                          </button>
                          <button
                            type="button"
                            className="btn-secondary"
                            disabled={photoIndex === page.gallery.length - 1}
                            onClick={() => {
                              change(current => ({ gallery: swapItems(current.gallery, photoIndex, photoIndex + 1) }))
                            }}
                          >
                            Down
                          </button>
                          <button
                            type="button"
                            className="btn-secondary"
                            onClick={() => change(current => ({ gallery: current.gallery.filter((_, i) => i !== photoIndex) }))}
                          >
                            Remove
                          </button>
                        </div>
                      </div>
                    ))}
                    {page.gallery.length < 8 && (
                      <CoverImageUpload
                        label="Gallery photo"
                        eventId={eventId}
                        currentUrl=""
                        onUploaded={(url) => change(current => ({ gallery: [...current.gallery, { url, alt: '' }] }))}
                        disabled={disabled}
                      />
                    )}
                  </>
                ) : (
                  <>
                    {section.items?.map((item, itemIndex) => (
                      <div key={itemIndex} className="rounded-lg bg-neutral-50 p-3">
                        <ItemEditor
                          type={section.type}
                          item={item}
                          onChange={(value) =>
                            updateSection(section.type, current => ({
                              items: current.items.map((row, i) => (i === itemIndex ? value : row)),
                            }))
                          }
                        />
                        <div className="mt-2 flex flex-wrap gap-2">
                          <button
                            type="button"
                            className="btn-secondary"
                            disabled={itemIndex === 0}
                            onClick={() => {
                              updateSection(section.type, current => ({ items: swapItems(current.items, itemIndex, itemIndex - 1) }))
                            }}
                          >
                            Up
                          </button>
                          <button
                            type="button"
                            className="btn-secondary"
                            disabled={itemIndex === section.items.length - 1}
                            onClick={() => {
                              updateSection(section.type, current => ({ items: swapItems(current.items, itemIndex, itemIndex + 1) }))
                            }}
                          >
                            Down
                          </button>
                          <button
                            type="button"
                            className="btn-secondary"
                            onClick={() =>
                              updateSection(section.type, current => ({ items: current.items.filter((_, i) => i !== itemIndex) }))
                            }
                          >
                            <Trash2 size={16} /> Remove
                          </button>
                        </div>
                        {['lineup', 'sponsors'].includes(section.type) && (
                          <CoverImageUpload
                            label={section.type === 'lineup' ? 'Performer photo' : 'Sponsor logo'}
                            eventId={eventId}
                            currentUrl={item.photo_url || item.logo_url || ''}
                            imageAssetHost={event.image_asset_host}
                            onUploaded={(url) =>
                              updateSection(section.type, current => ({
                                items: current.items.map((row, i) =>
                                  i === itemIndex
                                    ? { ...row, [section.type === 'lineup' ? 'photo_url' : 'logo_url']: url }
                                    : row
                                ),
                              }))
                            }
                            disabled={disabled}
                          />
                        )}
                      </div>
                    ))}
                    {section.items?.length < 20 && (
                      <button
                        type="button"
                        className="btn-secondary min-h-11"
                        onClick={() => updateSection(section.type, current => ({ items: [...current.items, { ...EMPTY[section.type] }] }))}
                      >
                        <Plus size={16} /> Add {section.type === 'faq' ? 'question' : 'item'}
                      </button>
                    )}
                  </>
                )}
              </div>
            )}
          </div>
        ))}
      </div>
      <div>
        <div className="mb-3 flex items-center justify-between gap-2">
          <h3 className="text-base font-semibold">Live page preview</h3>
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              className="btn-secondary min-h-11"
              aria-expanded={previewOpen}
              onClick={() => setPreviewOpen((value) => !value)}
            >
              {previewOpen ? 'Hide preview' : 'Show preview'}
            </button>
            <button
              type="button"
              aria-pressed={previewWidth === 'phone'}
              className="btn-secondary min-h-11"
              onClick={() => setPreviewWidth('phone')}
            >
              Phone
            </button>
            <button
              type="button"
              aria-pressed={previewWidth === 'desktop'}
              className="btn-secondary min-h-11"
              onClick={() => setPreviewWidth('desktop')}
            >
              Desktop
            </button>
          </div>
        </div>
        {previewOpen && (
          <div
            className={`mx-auto overflow-hidden rounded-2xl border border-neutral-200 bg-white ${accentStyle(page.accent) ? 'event-customized' : ''} ${previewWidth === 'phone' ? 'max-w-sm' : 'relative left-1/2 w-[min(1120px,calc(100vw-3rem))] max-w-none -translate-x-1/2'}`}
            style={accentStyle(page.accent)}
          >
            <div className="relative aspect-[16/9] bg-neutral-900">
              {approvedImageUrl(coverUrl, event.image_asset_host) && (
                <img
                  src={coverUrl}
                  alt=""
                  width="960"
                  height="540"
                  className="h-full w-full object-cover"
                  style={{ objectPosition: focalPosition(page) }}
                />
              )}
              <div className="absolute inset-0 flex items-end bg-gradient-to-t from-neutral-950/90 via-neutral-950/30 to-transparent p-4">
                <h4 className="text-xl font-bold text-white">{event?.title || 'Event title'}</h4>
              </div>
            </div>
            <div className="space-y-5 p-4">
              <div
                className={
                  previewWidth === 'desktop' ? 'space-y-5 sm:grid sm:grid-cols-3 sm:gap-5 sm:space-y-0' : 'space-y-5'
                }
              >
                <div
                  className={`rounded-xl border border-neutral-200 p-4 ${previewWidth === 'desktop' ? 'sm:order-2' : ''}`}
                  inert=""
                >
                  <TicketTypesSection ticketTypes={event?.ticket_types || []} onCheckout={() => {}} />
                  <div className="mt-3 border-t border-neutral-100 pt-3">
                    <AllInPriceNote
                      ticketTypes={event?.ticket_types || []}
                      includesProcessing={event?.service_fee_includes_processing === true}
                      platform={event?.seller?.ticketing_service}
                    />
                    <SellerLine seller={event?.seller} />
                  </div>
                </div>
                <div className={previewWidth === 'desktop' ? 'sm:order-1 sm:col-span-2' : ''}>
                  {description && (
                    <section>
                      <h5 className="event-heading mb-2 font-semibold">About</h5>
                      <EventDescription text={description} format={page.description_format} />
                    </section>
                  )}
                  <EventPageSections design={page} imageAssetHost={event.image_asset_host} />
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </section>
  )
}

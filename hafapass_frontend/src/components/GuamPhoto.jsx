import { useTranslation } from 'react-i18next'
import { guamPhotos } from '../config/photoCredits'

export default function GuamPhoto({ photo, priority = false, className = '', sizes = '(min-width: 1024px) 512px, (min-width: 640px) 90vw, 100vw' }) {
  const { t } = useTranslation()
  const { file, width, height } = guamPhotos[photo]
  const base = `/images/guam/${file}`
  return (
    <figure className={className}>
      <img src={`${base}-800.webp`} srcSet={`${base}-480.webp 480w, ${base}-800.webp 800w, ${base}-1280.webp 1280w`}
        sizes={sizes} width={width} height={height} alt={t(`publicPhotos.${photo}.alt`)}
        loading={priority ? 'eager' : 'lazy'} fetchpriority={priority ? 'high' : undefined}
        className="h-auto w-full rounded-2xl" />
      <figcaption className="mt-3 text-sm text-content-muted">{t(`publicPhotos.${photo}.caption`)}</figcaption>
    </figure>
  )
}

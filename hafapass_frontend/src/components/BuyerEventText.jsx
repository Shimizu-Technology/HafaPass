import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from './MachineTranslationNotice'

export default function BuyerEventText({ event, as: Heading = 'h4', className, description = false, linked = false }) {
  const content = useTranslatedContent(event)
  return <>
    <Heading className={className}>{content.title}</Heading>
    {description && content.short_description && <p className="mt-1 line-clamp-2 text-sm text-content-muted">{content.short_description}</p>}
    {content.notice && <MachineTranslationNotice {...content.notice} labelOnly={linked} className="mt-1" />}
  </>
}

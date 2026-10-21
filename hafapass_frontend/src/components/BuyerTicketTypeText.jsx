import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from './MachineTranslationNotice'

export default function BuyerTicketTypeText({ ticketType, showOriginal = false }) {
  const content = useTranslatedContent({
    ...ticketType,
    original_content: ticketType.original_content || (ticketType.machine_translated ? {
      name: ticketType.original_name, description: ticketType.original_description,
    } : null),
  }, ['name', 'description'])
  return <>
    <span className="text-neutral-800 font-medium text-sm">{showOriginal ? ticketType.original_name || content.name : content.name}</span>
    {content.notice && <MachineTranslationNotice {...content.notice} />}
  </>
}

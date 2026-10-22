import useTranslatedContent from '../hooks/useTranslatedContent'

export default function TranslatedTicketContent({ record, showOriginal, children }) {
  const content = useTranslatedContent(record, ['name', 'description'])
  return children(showOriginal ? {
    ...content, name: record.original_name || record.name,
    description: record.original_description ?? record.description,
  } : content)
}

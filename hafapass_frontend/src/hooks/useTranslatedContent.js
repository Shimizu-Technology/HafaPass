import { useState } from 'react'

// Event text from the API arrives in the visitor's language. When it was
// machine translated the API also sends the English original, so buyers can
// switch back to exactly what the organizer wrote.
//
//   const content = useTranslatedContent(event)
//   content.title / content.short_description / content.description
//   <MachineTranslationNotice {...content.notice} />
export default function useTranslatedContent(record, fields = ['title', 'short_description', 'description']) {
  const [showOriginal, setShowOriginal] = useState(false)
  const original = record?.original_content
  const translated = Boolean(record?.machine_translated && original)
  const content = Object.fromEntries(fields.map(field => [
    field, translated && showOriginal ? original[field] : record?.[field],
  ]))
  return {
    ...content,
    machineTranslated: translated,
    showingOriginal: translated && showOriginal,
    notice: translated ? { showingOriginal: showOriginal, onToggle: () => setShowOriginal(value => !value) } : null,
  }
}

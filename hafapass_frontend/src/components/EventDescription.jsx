import { Fragment } from 'react'
import { safeLink } from '../utils/eventPageDesign'

// This intentionally builds React nodes from a small subset. Source HTML is always text.
function inline(text) {
  const parts = []
  const pattern = /\[([^\]\n]+)\]\(([^)\s]+)\)|(\*\*|__)(.+?)\3|([*_])([^*_\n]+)\5/g
  let last = 0
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) parts.push(text.slice(last, match.index))
    if (match[1]) {
      const href = safeLink(match[2])
      parts.push(
        href ? (
          <a
            key={match.index}
            href={href}
            target="_blank"
            rel="noopener noreferrer nofollow"
            className="event-link underline"
          >
            {match[1]}
          </a>
        ) : (
          match[1]
        )
      )
    } else if (match[4]) parts.push(<strong key={match.index}>{match[4]}</strong>)
    else parts.push(<em key={match.index}>{match[6]}</em>)
    last = match.index + match[0].length
  }
  if (last < text.length) parts.push(text.slice(last))
  return parts
}

export default function EventDescription({ text, format = 'plain' }) {
  if (!text) return null
  if (format !== 'markdown') return <p className="text-neutral-600 leading-relaxed whitespace-pre-wrap">{text}</p>
  const lines = text.split('\n')
  const blocks = []
  for (let i = 0; i < lines.length; ) {
    const line = lines[i]
    if (!line.trim()) {
      i++
      continue
    }
    const heading = /^(#{2,3})\s+(.+)$/.exec(line)
    if (heading) {
      const Heading = heading[1].length === 2 ? 'h2' : 'h3'
      blocks.push(
        <Heading key={i} className="event-heading mb-2 mt-5 font-semibold">
          {inline(heading[2])}
        </Heading>
      )
      i++
      continue
    }
    const bullet = /^\s*[-*]\s+(.+)$/.exec(line)
    const numbered = /^\s*\d+\.\s+(.+)$/.exec(line)
    if (bullet || numbered) {
      const start = i
      const items = []
      const regex = bullet ? /^\s*[-*]\s+(.+)$/ : /^\s*\d+\.\s+(.+)$/
      while (i < lines.length && regex.test(lines[i])) {
        items.push(<li key={i}>{inline(regex.exec(lines[i])[1])}</li>)
        i++
      }
      const List = bullet ? 'ul' : 'ol'
      blocks.push(
        <List key={start} className={`${bullet ? 'list-disc' : 'list-decimal'} ml-6 mb-3 space-y-1 text-neutral-600`}>
          {items}
        </List>
      )
      continue
    }
    const start = i
    const paragraph = []
    while (i < lines.length && lines[i].trim() && !/^(#{2,3}\s|\s*[-*]\s|\s*\d+\.\s)/.test(lines[i])) {
      paragraph.push(
        <Fragment key={i}>
          {i > start && <br />}
          {inline(lines[i])}
        </Fragment>
      )
      i++
    }
    blocks.push(
      <p key={start} className="mb-3 leading-relaxed text-neutral-600">
        {paragraph}
      </p>
    )
  }
  return <div>{blocks}</div>
}

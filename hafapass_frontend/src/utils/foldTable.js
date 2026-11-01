// Table cells become labelled rows below md, so lists stay readable on a
// phone without sideways scrolling, and stay real tables for screen readers.
// Give each cell a data-label naming its column.
export const foldTable = 'w-full text-sm [&_thead]:sr-only md:[&_thead]:not-sr-only [&_th]:text-sm [&_th]:font-medium [&_th]:normal-case [&_th]:tracking-normal'
export const foldRow = 'block border-b border-neutral-100 px-4 py-3 last:border-b-0 md:table-row md:p-0'
export const foldCell = 'flex min-w-0 gap-3 py-1 [overflow-wrap:anywhere] [&>*]:min-w-0 before:w-24 before:shrink-0 before:text-sm before:font-medium before:text-content-muted before:content-[attr(data-label)] md:table-cell md:px-3 md:py-3 md:align-top md:before:content-none'

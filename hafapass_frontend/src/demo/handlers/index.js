// Demo handler registry. The adapter tries these in order BEFORE its built-in
// buyer routes; the first one that returns something other than `undefined`
// answers the request. To add a feature, create `./<feature>.js` exporting
// `handle(ctx)` and add ONE import + ONE list entry below (see ../README.md).
import * as baseline from './baseline'
import * as monitoring from './monitoring'

export const DEMO_HANDLERS = [
  monitoring,
  baseline,
]

import { DEMO_HANDLERS } from './index'

// Runs the registered handlers in order. A handler that throws is reported and
// skipped so one broken fixture cannot take the whole preview down.
export async function runDemoHandlers(ctx, handlers = DEMO_HANDLERS) {
  for (const handler of handlers) {
    if (typeof handler?.handle !== 'function') continue
    let result
    try { result = await handler.handle(ctx) } catch (error) {
      console.warn('[demo-api] handler failed', ctx.method.toUpperCase(), ctx.path, error)
      continue
    }
    // `undefined` or `null` means "not mine"; try the next handler.
    if (result != null) return result
  }
  return undefined
}

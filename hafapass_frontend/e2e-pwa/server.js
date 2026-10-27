// Static deploy fixture with real network faults, including worker/preload
// fetches (Playwright page routing cannot reliably intercept those).
import http from 'node:http'
import process from 'node:process'
import { readFile } from 'node:fs/promises'
import { resolve, extname } from 'node:path'

const root = resolve('tmp/pwa-deploy')
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.txt': 'text/plain', '.xml': 'application/xml', '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.png': 'image/png' }
let frozenWorker
let apiFixtures = {}
process.on('message', message => {
  if ('worker' in message) frozenWorker = message.worker
  if (message.api) apiFixtures = { ...apiFixtures, ...message.api }
  process.send('configured')
})
http.createServer(async (request, response) => {
  const path = new URL(request.url, 'http://127.0.0.1').pathname
  response.setHeader('Cache-Control', 'no-store')
  if (path.startsWith('/api/v1/')) {
    let body = ''
    for await (const chunk of request) body += chunk
    process.send({ type: 'api-request', path, method: request.method, body: body ? JSON.parse(body) : null })
    response.setHeader('Content-Type', 'application/json')
    response.end(JSON.stringify(apiFixtures[path] || {}))
    return
  }
  if (path === '/sw.js' && frozenWorker) {
    response.setHeader('Content-Type', 'text/javascript')
    response.end(frozenWorker)
    return
  }
  if (path === '/network-error') { request.socket.destroy(); return }
  if (path === '/server-error') { response.writeHead(503); response.end('Unavailable'); return }
  if (path.startsWith('/timeout-')) {
    // Never send headers. Closing the context/server cleans the held socket.
    return
  }
  try {
    const file = resolve(root, `.${decodeURIComponent(path === '/' ? '/index.html' : path)}`)
    if (!file.startsWith(root + '/')) { response.writeHead(403); response.end(); return }
    let body
    let type = types[extname(file)]
    try { body = await readFile(file) }
    catch {
      if (/^\/(?:assets\/|api|robots\.txt$|sitemap\.xml$)/.test(path)) {
        response.writeHead(404); response.end('Not found'); return
      }
      body = await readFile(resolve(root, 'index.html'))
      type = 'text/html'
    }
    response.setHeader('Content-Type', type || 'application/octet-stream')
    response.end(body)
  } catch { response.writeHead(500); response.end() }
}).listen(5234, '127.0.0.1')

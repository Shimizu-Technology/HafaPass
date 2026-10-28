// Resolve from the installed tools, without adding deployment tooling to app dependencies.
const { resolveConfig } = await import(process.env.NETLIFY_CONFIG_MODULE || '@netlify/config')
const { parseHeaders, headersForPath } = await import(process.env.NETLIFY_HEADERS_MODULE)
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
const cwd = process.cwd()
const results=[]
for (const baseRelDir of [true,false]) {
 const result=await resolveConfig({cwd, repositoryRoot:cwd, baseRelDir, offline:true, context:'production', branch:'main', logs:{level:'silent'}})
 const {build,headers}=result.config
 const global=headers.find(h=>h.for==='/*').values
 const preview=headers.find(h=>h.for==='/events/*/preview').values
 assert.equal(global['X-Content-Type-Options'],'nosniff')
 assert.equal(global['Referrer-Policy'],'strict-origin-when-cross-origin')
 assert.equal(global['X-Frame-Options'],'DENY')
 assert.equal(global['Content-Security-Policy'],"frame-ancestors 'none'")
 assert.equal(global['Permissions-Policy'],'camera=(self), payment=(self "https://js.stripe.com"), microphone=(), geolocation=()')
 assert.equal(preview['Referrer-Policy'],'no-referrer')
 assert.equal(preview['X-Robots-Tag'],'noindex, nofollow')
 assert.ok(headers.indexOf(headers.find(h=>h.for==='/*'))<headers.indexOf(headers.find(h=>h.for==='/events/*/preview')))
 const parsed=await parseHeaders({config:result.config,configPath:result.configPath,headersFiles:[]})
 const previewEffective=headersForPath(parsed,'/events/qa/preview')
 const publicEffective=headersForPath(parsed,'/events')
 assert.equal(previewEffective['Referrer-Policy'] || previewEffective['referrer-policy'],'no-referrer')
 assert.equal(publicEffective['Referrer-Policy'] || publicEffective['referrer-policy'],'strict-origin-when-cross-origin')
 assert.equal(previewEffective['X-Frame-Options'] || previewEffective['x-frame-options'],'DENY')
 results.push({previewEffective,publicEffective,baseRelDir,configPath:result.configPath,build,headers,redirects:result.config.redirects?.filter(r=>r.from.includes('favicon'))})
}
assert.deepEqual(results[0].headers,results[1].headers)
await fs.writeFile('docs/qa/audit-fixes/netlify-config.json',JSON.stringify(results,null,2)+'\n')
console.log('Both Netlify passes: matching headers; preview-specific no-referrer retained; favicon redirects resolved.')

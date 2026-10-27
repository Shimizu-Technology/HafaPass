import { chromium, webkit } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
const phase = process.env.QA_PHASE || 'after'
const base = 'http://127.0.0.1:5233'
const output = new URL(`../../../docs/qa/pass-direction/${phase}/`, import.meta.url).pathname
await fs.mkdir(output, { recursive: true })
const event = { id: 601, slug: 'community-night', title: 'Guam Community Night', status: 'published', starts_at: '2099-11-20T08:00:00Z', timezone: 'Pacific/Guam', venue_name: 'Community Hall', venue_city: 'Hagåtña', purchasable: true, category: 'concert', ticket_types: [{ id: 10, name: 'General admission', price_cents: 2500, all_in_price_cents: 2725, service_fee_cents: 225, quantity_remaining: 20, on_sale: true }] }
const events = [event, { ...event, id: 602, slug: 'food-fair', title: 'An Evening of Food, Music and Stories with Our Neighbors in Mongmong-Toto-Maite', category: 'festival', cover_image_url: 'https://art.example.test/uploads/poster.jpg', image_asset_host: 'art.example.test', ticket_types: [{ id: 11, price_cents: 0, quantity_remaining: 20, on_sale: true }] }, { ...event, id: 603, slug: 'workshop', title: 'Weekend printmaking workshop', category: 'workshop', venue_name: 'Mongmong-Toto-Maite Community Center' }]
const config = { payment_mode: 'simulate', service_fee_percent: '5.0', service_fee_flat_cents: 100, processing_fee_bearer: 'platform', payout_schedule_text: 'within 3 business days after your event', support_email: 'public-pages-qa@example.test', support_phone: '+1 (671) 555-0100', launch_capabilities: {} }
const ticket = { id: 601, status: 'issued', admission_allowed: true, scan_credential: 'synthetic-pass-direction-qa', wallet_availability: {}, event, ticket_type: { name: 'General admission' } }
const sizes = [[375,812],[390,844],[768,1024],[1280,800],[1440,900]]
const report = []
for (const [engine, browserType] of [['chromium', chromium], ...(phase === 'after' ? [['webkit', webkit]] : [])]) {
 const browser = await browserType.launch()
 try {
 const context = await browser.newContext({ reducedMotion: 'reduce', hasTouch: true })
 const page = await context.newPage()
 let inventory = []
 let publicConfig = config
 const json = (route, data) => route.fulfill({ contentType: 'application/json', body: JSON.stringify(data) })
 await page.addInitScript(() => { sessionStorage.setItem('hafapass:order-access:601', 'synthetic-guest'); window.qaCLS = 0; window.qaShifts=[]; if (PerformanceObserver.supportedEntryTypes.includes('layout-shift')) new PerformanceObserver(list => { for (const e of list.getEntries()) { if (!e.hadRecentInput) { window.qaCLS += e.value; window.qaShifts.push({value:e.value,sources:e.sources.map(s=>({node:s.node?.outerHTML?.slice(0,100),before:s.previousRect.toJSON(),after:s.currentRect.toJSON()}))}) } } }).observe({type:'layout-shift',buffered:true}) })
 await page.route('**/api/v1/**', route => { const path = new URL(route.request().url()).pathname; return json(route, path.endsWith('/health') ? {status:'ok'} : path.endsWith('/config') ? publicConfig : path.endsWith('/tickets/display-qa') ? ticket : path.endsWith('/events/community-night') ? event : path.endsWith('/events') ? {events:inventory,meta:{current_page:1,total_pages:1,total_count:inventory.length}} : path.endsWith('/event_categories') ? {categories:[]} : {}) })
 await page.route('https://art.example.test/**', route => route.fulfill({ path: 'public/og-host.jpg', contentType:'image/jpeg' }))
 for (const [width,height] of sizes) {
  await page.setViewportSize({width,height})
  for (const [name,path,populated] of [['home-empty','/',false],['home-populated','/',true],['host','/host',true],['events','/events',true],['event','/events/community-night',true],['ticket','/tickets/display-qa?order=601',true]]) {
   inventory = populated ? events : []
   await page.goto(`${base}${path}`)
   await page.locator('h1').waitFor()
   if (name === 'events') {
    await page.waitForFunction(count=>document.querySelectorAll('.event-card').length===count,inventory.length)
    await page.locator('main [role="status"][aria-label]').waitFor({state:'detached'})
   }
   if (name === 'host') await page.getByLabel('Ticket price', {exact:true}).waitFor()
   if (name.startsWith('home')) await page.getByText(populated ? 'Guam Community Night' : 'The first events go on sale soon.',{exact:true}).first().waitFor()
   await page.evaluate(() => document.fonts.ready)
   await page.locator('.hero-ticket').evaluateAll(elements => Promise.all(elements.flatMap(el => el.getAnimations().map(a => a.finished.catch(() => {})))))
   let ledeLines
   if (phase === 'after') {
    if (name.startsWith('home') || name === 'host') {
     assert.equal(await page.locator('h1').evaluate(el => getComputedStyle(el).textWrap), 'balance')
     assert.equal(await page.locator('.public-intros p').first().evaluate(el => getComputedStyle(el).textWrap), 'pretty')
    }
    if (name.startsWith('home')) {
     ledeLines = await page.locator('.public-intros section p').first().evaluate(el => {
      const text = el.firstChild
      const lines = new Map()
      for (const match of text.textContent.matchAll(/\S+/g)) {
       const range = document.createRange()
       range.setStart(text, match.index); range.setEnd(text, match.index + match[0].length)
       const top = Math.round(range.getBoundingClientRect().top)
       lines.set(top, [...(lines.get(top) || []), match[0]])
      }
      return [...lines.values()]
     })
     if ([375,390,768].includes(width) && ledeLines.length > 1) assert.ok(ledeLines.at(-1).length > 1, `${engine} ${width} lede orphan: ${JSON.stringify(ledeLines)}`)
    }
    if (name === 'home-empty') {
     assert.equal(await page.getByRole('heading', {name:'Events are coming soon', exact:true}).count(), 0)
     assert.equal(await page.getByText('No events are listed yet. Check back soon.', {exact:true}).count(), 0)
     assert.equal(await page.getByRole('search').count(), 0)
     assert.equal(await page.getByRole('combobox').count(), 0)
     const stock = page.locator('.home-ticket-empty')
     const inset = await stock.evaluate(el => el.querySelector('svg').getBoundingClientRect().top - el.getBoundingClientRect().top)
     assert.ok(inset <= 32, `${engine} ${width} empty message top inset ${inset}`)
    }
    if (name === 'home-populated') {
     const art = page.locator('.event-card').nth(1).locator('img')
     assert.equal(await art.count(), 1)
     const date = page.locator('.event-card').first().locator('time')
     assert.equal(await date.evaluate(el => getComputedStyle(el).color), 'rgb(255, 255, 255)')
     assert.equal(await date.evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(14, 80, 79)')
     assert.equal((await date.boundingBox()).height, (await art.boundingBox()).height)
    }
    if (name === 'host') {
     assert.match(await page.getByRole('link', {name:config.support_email, exact:true}).getAttribute('href'), /^mailto:public-pages-qa@example.test/)
     assert.equal(await page.getByRole('link', {name:config.support_phone, exact:true}).getAttribute('href'), 'tel:+16715550100')
     assert.equal(await page.getByText('Your event. Your people. We’ll help you get them in.', {exact:true}).count(), 0)
    }
    if (name === 'ticket') {
     assert.equal(await page.locator('header').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(3, 40, 39)')
     if (width < 640) {
      const gap = await page.locator('.ticket').evaluate(el => el.getBoundingClientRect().top - document.querySelector('header').getBoundingClientRect().bottom)
      assert.ok(gap >= 24 && gap <= 32, `${engine} ${width} ticket header gap ${gap}`)
     }
    }
   }
   await page.screenshot({path:`${output}${engine === 'webkit' ? 'webkit-' : ''}${width}-${name}.png`,fullPage:true})
   if (phase === 'after') {
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${engine} ${name} ${width} overflow`)
    const axe = await new AxeBuilder({page}).withTags(['wcag2a','wcag2aa']).analyze()
    assert.deepEqual(axe.violations.map(v=>({id:v.id,nodes:v.nodes.map(n=>n.target)})), [], `${engine} ${name} ${width} axe`)
    const cls = await page.evaluate(() => window.qaCLS)
    assert.ok(cls < .1, `${engine} ${name} ${width} CLS ${cls}: ${JSON.stringify(await page.evaluate(() => window.qaShifts))}`)
    report.push({engine,name,width,cls,axe:0,...(ledeLines ? {ledeLines} : {})})
   }
  }
 }
 if (phase === 'after') {
  await page.setViewportSize({width:390,height:844})
  inventory=events
  await page.goto(base)
  const when=page.getByLabel('When',{exact:true}), where=page.getByLabel('Where',{exact:true})
  await when.selectOption('weekend'); await where.selectOption('Hagåtña')
  const search=page.getByRole('searchbox',{name:'Event or venue'})
  await search.fill('Music & food')
  // WebKit on macOS uses Option-Tab for traversal that includes buttons/links.
  const nextKey=engine==='webkit'?'Alt+Tab':'Tab'
  const previousKey=engine==='webkit'?'Alt+Shift+Tab':'Shift+Tab'
  await when.focus();await page.keyboard.press(previousKey);await page.keyboard.press(nextKey)
  const controls=[when,where,search,page.getByRole('button',{name:'Search',exact:true})]
  for (const [index,locator] of controls.entries()) {
   assert.ok((await locator.boundingBox()).height>=44,`${engine} ${await locator.getAttribute('id')} touch target`)
   assert.ok(await locator.evaluate(el=>el===document.activeElement&&el.matches(':focus-visible')),`${engine} keyboard focus`)
   assert.ok(await locator.evaluate(el=>getComputedStyle(el).boxShadow!=='none'||getComputedStyle(el).outlineStyle!=='none'))
   if(index<controls.length-1) await page.keyboard.press(nextKey)
  }
  await page.screenshot({path:`${output}${engine}-390-controls-focus.png`,fullPage:true})
  await page.keyboard.press('Enter'); await page.waitForURL('**/events?**')
  const query=new URL(page.url()).searchParams
  assert.equal(query.get('search'),'Music & food');assert.equal(query.get('date'),'weekend');assert.equal(query.get('village'),'Hagåtña')
  await page.goto(base);const cards=page.locator('.event-card');await cards.first().waitFor()
  await cards.first().focus();assert.ok(await cards.first().evaluate(el=>getComputedStyle(el).outlineStyle==='solid'&&getComputedStyle(el).maskImage==='none'))
  await page.locator('.event-track').screenshot({path:`${output}${engine}-390-event-card-row.png`})
  if(engine==='chromium') {
   await page.locator('.event-track').scrollIntoViewIfNeeded()
   const rect=await page.locator('.event-track').boundingBox();const x=rect.x+rect.width*.85,y=Math.max(rect.y+80,80)
   const cdp=await context.newCDPSession(page)
   await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x,y}]})
   for(let step=1;step<=10;step++) await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:x-step*23,y}]})
   await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]})
   await page.waitForFunction(()=>document.querySelector('.event-track').scrollLeft>100)
   await cdp.detach()
  }
  await cards.first().focus();await page.keyboard.press('Enter');await page.waitForURL('**/events/community-night')
  await page.goto(base+'/host');await page.getByRole('button',{name:'$59',exact:true}).click()
  assert.equal(await page.getByLabel('Ticket price',{exact:true}).inputValue(),'59')
  assert.ok((await page.getByRole('region',{name:'Buyer pays the fee',exact:true}).textContent()).includes('$62.95'))
  assert.ok((await page.getByRole('region',{name:'You absorb the fee',exact:true}).textContent()).includes('$55.05'))
  await page.getByLabel('Ticket price',{exact:true}).fill('0')
  assert.ok((await page.getByRole('region',{name:'Buyer pays the fee',exact:true}).textContent()).includes('$0.00'))
  await page.getByLabel('Ticket price',{exact:true}).fill('invalid');assert.equal(await page.getByLabel('Ticket price',{exact:true}).getAttribute('aria-invalid'),'true')
  const faq=page.locator('summary').filter({hasText:'Does my door staff need an app?'})
  await faq.focus();await page.keyboard.press('Enter');assert.equal(await faq.locator('..').getAttribute('open'),'')
  assert.match(await page.getByRole('link',{name:'Talk to us about your event'}).getAttribute('href'),/^mailto:public-pages-qa@example.test/)
  await page.goto(base);await page.locator('.hero-ticket').waitFor()
  const motion=await page.locator('.hero-ticket').evaluate(el=>({name:getComputedStyle(el).animationName,keyframes:el.getAnimations().flatMap(a=>a.effect.getKeyframes())}))
  assert.equal(motion.name,'ticket-fade');assert.ok(motion.keyframes.every(k=>!k.transform||k.transform==='none'))
  await page.locator('.hero-ticket').evaluate(el=>Promise.all(el.getAnimations().map(a=>a.finished)))
  assert.equal(await page.locator('.hero-ticket').evaluate(el=>getComputedStyle(el).opacity),'1')
  await page.emulateMedia({reducedMotion:'no-preference'});await page.reload();await page.locator('.hero-ticket').waitFor()
  await page.locator('.hero-ticket').evaluate(el=>{window.qaHeroFrames=el.getAnimations().flatMap(a=>a.effect.getKeyframes());return Promise.all(el.getAnimations().map(a=>a.finished))})
  assert.ok(await page.evaluate(()=>window.qaHeroFrames.some(k=>k.transform?.includes('12px'))))
  await page.screenshot({path:`${output}${engine}-390-motion-settled.png`,fullPage:true})
  publicConfig = {...config, support_email:'', support_phone:''}
  await page.goto(base+'/host')
  await page.getByLabel('Ticket price', {exact:true}).waitFor()
  await page.waitForFunction(() => !document.querySelector('a[href^="mailto:"]') && !document.querySelector('a[href^="tel:"]'))
  assert.equal(await page.locator('h3').filter({hasText:'Contact support'}).count(), 0)
  const columns = await page.locator('#local-help-heading').evaluate(el => getComputedStyle(el.parentElement.parentElement).gridTemplateColumns)
  assert.equal(columns.split(' ').length, 1, `${engine} unconfigured help uses one column`)
  publicConfig = config
  process.stdout.write(`${engine}: search filters, keyboard focus/navigation, calculator presets/free/validation, FAQ, support and motion passed` + '\n')
 }
 if (engine === 'chromium' && phase === 'before') {
  await page.goto('http://127.0.0.1:5234/hafapass-home-directions.html')
  await page.screenshot({path:`${output}approved-directions.png`,fullPage:true})
 }
 await context.close()
 } finally { await browser.close() }
}
await fs.writeFile(`${output}results.json`, JSON.stringify(report,null,2))
process.stdout.write(`${phase} QA: ${report.length} page/dimension checks passed` + '\n')

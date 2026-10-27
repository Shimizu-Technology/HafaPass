import {chromium} from '@playwright/test'
import assert from 'node:assert/strict'
const browser=await chromium.launch()
try {
 const page=await browser.newPage({viewport:{width:390,height:844},reducedMotion:'reduce'})
 const preflight=await page.request.get('http://localhost:3066/api/v1/events?q=Guam%20community%20night')
 const matches=(await preflight.json()).events
 assert.deepEqual(matches.map(event=>event.venue_city).sort(),['Hagåtña','Yigo'].sort())
 await page.goto('http://localhost:5236')
 await page.getByRole('searchbox',{name:'Event or venue'}).fill('Guam community night')
 await page.getByLabel('Where',{exact:true}).selectOption('Hagåtña')
 const response=page.waitForResponse(r=>r.url().includes('/api/v1/events?')&&new URL(r.url()).searchParams.get('q')==='Guam community night'&&new URL(r.url()).searchParams.get('village')==='Hagåtña')
 await page.getByRole('button',{name:'Search',exact:true}).click()
 const result=await response
 assert.deepEqual((await result.json()).events.map(event=>event.venue_city),['Hagåtña'])
 await page.getByRole('textbox',{name:'Search events and venues'}).waitFor()
 await page.waitForURL('**/events?**')
 const cards=page.locator('.event-card');await cards.first().waitFor()
 await page.waitForFunction(()=>document.querySelectorAll('.event-card').length===1)
 assert.equal(await cards.count(),1)
 await cards.first().click()
 await page.getByRole('heading',{name:'Guam community night',exact:true}).waitFor()
 await page.getByRole('button',{name:'Increase quantity for General admission',exact:true}).click()
 await page.getByRole('button',{name:/Buy Tickets/}).click()
 await page.waitForURL('**/checkout/guam-community-night')
 await page.getByLabel('Full Name').waitFor()
 await page.reload();await page.getByLabel('Full Name').waitFor()
 process.stdout.write('Real Rails fixture flow passed: matching-title fixtures in Hagåtña and Yigo → Home search + village=Hagåtña → one matching event → quantity → guest checkout; checkout survives reload. No order/payment submitted.' + '\n')
} finally {await browser.close()}

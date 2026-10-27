import {chromium} from '@playwright/test'
import assert from 'node:assert/strict'
const browser=await chromium.launch()
try {
 const page=await browser.newPage({viewport:{width:390,height:844},reducedMotion:'reduce'})
 await page.goto('http://localhost:5233')
 await page.getByRole('searchbox',{name:'Event or venue'}).fill('Guam community night')
 await page.getByLabel('Where',{exact:true}).selectOption('Hagåtña')
 const response=page.waitForResponse(r=>r.url().includes('/api/v1/events?')&&new URL(r.url()).searchParams.get('q')==='Guam community night')
 await page.getByRole('button',{name:'Search',exact:true}).click()
 await response
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
 console.log('Real Rails fixture flow passed: Home search + village → one matching event → quantity → guest checkout; checkout survives reload. No order/payment submitted.')
} finally {await browser.close()}

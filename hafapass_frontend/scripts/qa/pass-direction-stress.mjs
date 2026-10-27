import {chromium} from '@playwright/test'
import assert from 'node:assert/strict'
const browser=await chromium.launch()
try{
 const page=await browser.newPage({viewport:{width:375,height:812},reducedMotion:'reduce'})
 const event={id:1,slug:'long',title:'MongmongTotoMaiteCommunityArtsAndCultureNight: An Evening of Music, Family Recipes and Stories from Three Generations 🌺',starts_at:'2099-11-20T08:00:00Z',timezone:'Pacific/Guam',venue_name:'Mongmong-Toto-Maite Community Center and Outdoor Performance Grounds',ticket_types:[{price_cents:999999,all_in_price_cents:1050999,service_fee_cents:51000,quantity_remaining:1,on_sale:true}]}
 await page.route('**/api/v1/**',r=>r.fulfill({json:r.request().url().endsWith('/events')?{events:[event,{...event,id:2,slug:'short',title:'Go',venue_name:null,ticket_types:[{price_cents:0,quantity_remaining:1,on_sale:true}]}]}:{service_fee_percent:'5',service_fee_flat_cents:100,processing_fee_bearer:'platform'}}))
 for(const path of ['/','/host']){
  await page.goto('http://127.0.0.1:5233'+path);await page.locator(path==='/'?'.event-card':'input').first().waitFor()
  if(path==='/host'){await page.getByLabel('Ticket price',{exact:true}).fill('10000');await page.getByLabel('Tickets',{exact:true}).fill('1000');assert.ok((await page.getByRole('region',{name:'Buyer pays the fee',exact:true}).textContent()).includes('$10,501,000.00'))}
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),path+' overflow')
  await page.evaluate(()=>window.scrollTo(0,0));await page.locator('.hero-ticket').evaluateAll(els=>Promise.all(els.flatMap(el=>el.getAnimations().map(a=>a.finished.catch(()=>{})))))
  await page.screenshot({path:new URL(`../../../docs/qa/pass-direction/after/375-${path==='/'?'home':'host'}-worst-case.png`,import.meta.url).pathname,fullPage:true})
  await page.addStyleTag({content:'html {font-size:200%}'});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),path+' 200% text overflow')
 }
 process.stdout.write('Stress passed at 375px and 200% text: long compound title, emoji, long/missing venue, one-word title, free and high prices, 1000 tickets. No document overflow.' + '\n')
}finally{await browser.close()}

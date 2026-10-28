// Browser-only component contracts. No Clerk service or credentials are used.
import { chromium, webkit } from '@playwright/test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import { prepare } from './buyer-pages-fixtures.mjs'
const root = new URL('../../../docs/qa/audit-fixes/', import.meta.url).pathname
const results=[]
for (const [engine,type] of [['chromium',chromium],['webkit',webkit]]) {
 const browser=await type.launch()
 try {
  for (const width of [390,1024,1280]) for (const scene of ['sign-in','sign-up','admin-nav','organizer-nav']) {
   const context=await browser.newContext({viewport:{width,height:width===390?844:width===1024?768:800}, reducedMotion:'reduce'})
   try {
    const page=await context.newPage()
    page.setDefaultTimeout(15000)
    page.setDefaultNavigationTimeout(30000)
    page.on('pageerror', error=>console.log('pageerror',error.message))
    await prepare(page)
    await page.route('**/node_modules/.vite/deps/@clerk_clerk-react.js*', async route=>{
     const url=route.request().url()
     if(url.includes('qa-original')) return route.continue()
     return route.fulfill({contentType:'text/javascript',body:`
      export * from '${url}&qa-original=1';
      import React from '/node_modules/.vite/deps/react.js';
      import {clerkAppearance,clerkLocalization} from '/src/config/clerkAppearance.js';
      const h=React.createElement;
      export const SignedIn=({children})=>children;
      export const UserButton=()=>h('button',{className:'h-11 w-11 rounded-full bg-brand-700 text-white','aria-label':'Account options'},'QA');
      const Widget=({up,signInUrl,signUpUrl})=>h('section',{className:'w-full max-w-md rounded-xl border border-neutral-200 bg-white px-6 py-8 text-center'},
       h('h1',{className:'font-display text-2xl font-bold'},clerkLocalization[up?'signUp':'signIn'].start.title),
       h('p',{className:'mt-3 text-sm text-neutral-600'},clerkLocalization[up?'signUp':'signIn'].start.subtitle),
       h('form',{className:'my-6 text-left',onSubmit:e=>e.preventDefault()},
        h('label',{htmlFor:'qa-email',className:'block text-sm font-medium'},'Email address'),
        h('input',{id:'qa-email',type:'email',className:'input mt-2',placeholder:'you@example.test'}),
        h('button',{className:'btn-primary mt-4 w-full'},'Continue')),
       h('div',{className:clerkAppearance.elements.footerAction+' text-sm leading-5'},
        h('span',{},up?'Already have an account?':"Don't have an account?"),
        h('a',{href:up?signInUrl:signUpUrl,className:clerkAppearance.elements.footerActionLink},up?'Sign in':'Sign up')),
       h('p',{className:'mt-6 text-xs text-neutral-500'},'Secured by Clerk'),
       h('p',{className:'mt-2 text-xs text-neutral-500'},'Synthetic component contract fixture'));
      export const SignIn=props=>h(Widget,{...props,up:false});
      export const SignUp=props=>h(Widget,{...props,up:true});
     `})
    })
    if(scene.endsWith('nav')) {
     await page.route('**/src/components/Navbar.jsx*',async route=>{
      const response=await route.fetch();let body=await response.text()
      assert.match(body,/isSignedIn: false,\s*clerkEnabled: false/)
      body=body.replace(/isSignedIn: false,\s*clerkEnabled: false/,'isSignedIn: true, isLoaded: true, userId: "qa-user", sessionId: "qa-session", clerkEnabled: true')
      await route.fulfill({response,body})
     })
     await page.route('**/api/v1/me',route=>route.fulfill({json:{clerk_id:'qa-user',role:scene==='admin-nav'?'admin':'organizer',workspace:{scanner:true,organizer:true}}}))
    } else {
     await page.route('**/src/pages/Sign*Page.jsx*',async route=>{
      const response=await route.fetch()
      await route.fulfill({response,body:(await response.text()).replace('const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY;','const clerkPubKey = "synthetic-contract";')})
     })
    }
    await page.goto('http://localhost:5241/'+(scene.endsWith('nav')?'events':scene+'?returnTo=%2Fmy-tickets'))
    if(scene.endsWith('nav')) {
     await page.evaluate(async()=>{const {setAuthTokenGetter}=await import('/src/api/client.js');setAuthTokenGetter(async()=> 'synthetic-token',{userId:'qa-user',sessionId:'qa-session',ready:true})})
     if(width<1280) await page.getByRole('button',{name:'Toggle menu'}).click()
     await page.getByRole('link',{name:scene==='admin-nav'?'Admin':'Dashboard',exact:true}).waitFor()
     if(width===1024) assert.equal(await page.getByRole('navigation',{name:'Primary navigation',exact:true}).isVisible(),false)
     if(width===1280) assert.equal(await page.locator('header').evaluate(el=>el.getBoundingClientRect().height),65)
    } else {
     await page.getByRole('heading',{name:scene==='sign-in'?'Sign in to HåfaPass':'Create your HåfaPass account'}).waitFor()
     const link=page.locator('main a').last()
     assert.match(await link.getAttribute('href'),/returnTo=%2Fmy-tickets/)
     const rect=await link.boundingBox();assert.ok(rect.height>=44 && rect.width>=44)
     const sentence=await link.locator('..').locator('span').boundingBox()
     assert.ok(Math.abs(sentence.y+sentence.height/2-(rect.y+rect.height/2))<2,'footer sentence/link centered')
     assert.equal(await page.locator('main').getByText('Secured by Clerk').count(),1)
    }
    await page.evaluate(()=>document.fonts.ready)
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth))
    await page.screenshot({path:`${root}after/${engine}-${width}-${scene}-contract.png`,fullPage:true})
    results.push({engine,width,scene,result:'passed',boundary:'synthetic SDK component, real application modules/styles; not live Clerk'})
    console.log(engine,width,scene,'passed')
   } finally {await context.close()}
  }
 } finally {await browser.close();await fs.writeFile(root+'contract-results.json',JSON.stringify(results,null,2)+'\n')}
}

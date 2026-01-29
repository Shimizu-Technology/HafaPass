// Test Browserbase with HafaPass via ngrok
import Browserbase from '@browserbasehq/sdk';
import { chromium } from 'playwright-core';

const BROWSERBASE_API_KEY = process.env.BROWSERBASE_API_KEY;
const BROWSERBASE_PROJECT_ID = process.env.BROWSERBASE_PROJECT_ID;

const TEST_URL = process.argv[2] || 'https://example.com';

async function main() {
  console.log('🚀 Starting Browserbase HafaPass test...');
  console.log(`🌐 Target URL: ${TEST_URL}`);
  
  const bb = new Browserbase({ apiKey: BROWSERBASE_API_KEY });
  
  console.log('📡 Creating browser session...');
  const session = await bb.sessions.create({
    projectId: BROWSERBASE_PROJECT_ID,
  });
  console.log(`✅ Session created: ${session.id}`);
  
  console.log('🔌 Connecting to browser...');
  const browser = await chromium.connectOverCDP(session.connectUrl);
  const context = browser.contexts()[0];
  const page = context.pages()[0];
  
  // Set extra headers to bypass ngrok interstitial
  await page.setExtraHTTPHeaders({
    'ngrok-skip-browser-warning': 'true'
  });
  
  // Set viewport to desktop
  await page.setViewportSize({ width: 1280, height: 800 });
  
  console.log('🌐 Navigating to page...');
  await page.goto(TEST_URL, { waitUntil: 'networkidle', timeout: 30000 });
  
  // Check if we're on ngrok warning page and click through
  const pageContent = await page.content();
  if (pageContent.includes('ngrok-free.dev') && pageContent.includes('Visit Site')) {
    console.log('🔓 Clicking through ngrok interstitial...');
    await page.click('button:has-text("Visit Site")').catch(() => {});
    await page.waitForLoadState('networkidle');
  }
  
  const title = await page.title();
  console.log(`📄 Page title: ${title}`);
  
  // Take desktop screenshot
  console.log('📸 Taking desktop screenshot...');
  await page.screenshot({ path: 'screenshots/hafapass-desktop.png', fullPage: false });
  console.log('✅ Desktop screenshot saved');
  
  // Test mobile viewport
  console.log('📱 Switching to mobile viewport...');
  await page.setViewportSize({ width: 375, height: 667 });
  await page.waitForTimeout(1000);
  
  console.log('📸 Taking mobile screenshot...');
  await page.screenshot({ path: 'screenshots/hafapass-mobile.png', fullPage: false });
  console.log('✅ Mobile screenshot saved');
  
  // Get page content summary
  const h1Text = await page.locator('h1').first().textContent().catch(() => 'No H1 found');
  console.log(`📝 Main heading: ${h1Text}`);
  
  // Check for key HafaPass elements
  const hasNavbar = await page.locator('nav').count() > 0;
  const hasFooter = await page.locator('footer').count() > 0;
  console.log(`🧭 Navbar: ${hasNavbar ? '✅' : '❌'}`);
  console.log(`🦶 Footer: ${hasFooter ? '✅' : '❌'}`);
  
  await browser.close();
  
  console.log('');
  console.log('🎉 Test complete! Results:');
  console.log('   - Desktop: screenshots/hafapass-desktop.png');
  console.log('   - Mobile:  screenshots/hafapass-mobile.png');
}

main().catch(err => {
  console.error('❌ Error:', err.message);
  process.exit(1);
});

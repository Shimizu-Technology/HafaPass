// Quick Browserbase test - navigate to a page and take a screenshot
import Browserbase from '@browserbasehq/sdk';
import { chromium } from 'playwright-core';
import fs from 'fs';

const BROWSERBASE_API_KEY = process.env.BROWSERBASE_API_KEY;
const BROWSERBASE_PROJECT_ID = process.env.BROWSERBASE_PROJECT_ID;

async function main() {
  console.log('🚀 Starting Browserbase test...');
  
  // Create a Browserbase client
  const bb = new Browserbase({ apiKey: BROWSERBASE_API_KEY });
  
  // Create a session
  console.log('📡 Creating browser session...');
  const session = await bb.sessions.create({
    projectId: BROWSERBASE_PROJECT_ID,
  });
  console.log(`✅ Session created: ${session.id}`);
  
  // Connect with Playwright
  console.log('🔌 Connecting to browser...');
  const browser = await chromium.connectOverCDP(session.connectUrl);
  const context = browser.contexts()[0];
  const page = context.pages()[0];
  
  // Navigate to a test page
  console.log('🌐 Navigating to example.com...');
  await page.goto('https://example.com');
  console.log(`📄 Page title: ${await page.title()}`);
  
  // Take a screenshot
  console.log('📸 Taking screenshot...');
  await page.screenshot({ path: 'screenshots/browserbase-test.png' });
  console.log('✅ Screenshot saved to screenshots/browserbase-test.png');
  
  // Close
  await browser.close();
  console.log('🎉 Test complete!');
}

main().catch(err => {
  console.error('❌ Error:', err.message);
  process.exit(1);
});

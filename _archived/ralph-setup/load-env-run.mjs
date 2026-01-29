// Helper to load .env and run the test script
import { readFileSync } from 'fs';
import { execSync } from 'child_process';

// Parse .env file
const envContent = readFileSync('.env', 'utf8');
const envVars = {};
envContent.split('\n').forEach(line => {
  line = line.trim();
  if (!line || line.startsWith('#')) return;
  const idx = line.indexOf('=');
  if (idx === -1) return;
  const key = line.substring(0, idx);
  let value = line.substring(idx + 1);
  // Remove surrounding quotes if present
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    value = value.slice(1, -1);
  }
  envVars[key] = value;
});

// Get the URL argument
const url = process.argv[2] || 'https://example.com';

// Run the test script with environment
const env = { ...process.env, ...envVars };
try {
  const result = execSync(`node test-browserbase-hafapass.mjs "${url}"`, {
    env,
    stdio: 'inherit',
    timeout: 60000
  });
} catch (err) {
  process.exit(err.status || 1);
}

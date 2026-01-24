#!/bin/bash
# =============================================================================
# HafaPass Autonomous Testing Startup Script
# =============================================================================
# This script starts all required services for Ralph's autonomous testing:
# 1. Rails API server (port 3000)
# 2. Vite frontend server (port 5173)
# 3. ngrok tunnels to expose both
# 4. Ralph loop
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  HafaPass Autonomous Testing Setup    ${NC}"
echo -e "${BLUE}========================================${NC}"

# Check for required environment variables
if [ -z "$BROWSERBASE_API_KEY" ]; then
    echo -e "${RED}Error: BROWSERBASE_API_KEY not set${NC}"
    echo "Get your API key from https://browserbase.com/dashboard"
    echo "Then run: export BROWSERBASE_API_KEY=your_key"
    exit 1
fi

if [ -z "$BROWSERBASE_PROJECT_ID" ]; then
    echo -e "${RED}Error: BROWSERBASE_PROJECT_ID not set${NC}"
    echo "Get your project ID from https://browserbase.com/dashboard"
    echo "Then run: export BROWSERBASE_PROJECT_ID=your_project_id"
    exit 1
fi

# Check for ngrok
if ! command -v ngrok &> /dev/null; then
    echo -e "${YELLOW}ngrok not found. Installing...${NC}"
    brew install ngrok
fi

# Check if ngrok is authenticated
if ! ngrok config check &> /dev/null 2>&1; then
    echo -e "${YELLOW}ngrok not authenticated.${NC}"
    echo "Run: ngrok config add-authtoken YOUR_TOKEN"
    echo "Get your token from https://dashboard.ngrok.com/get-started/your-authtoken"
    exit 1
fi

# Function to cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}Shutting down services...${NC}"
    kill $(jobs -p) 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

# Start Rails API
echo -e "${GREEN}Starting Rails API server...${NC}"
cd hafapass_api
bundle exec rails s -p 3000 &
RAILS_PID=$!
cd ..

# Wait for Rails to start
sleep 3

# Start Vite frontend
echo -e "${GREEN}Starting Vite frontend server...${NC}"
cd hafapass_frontend
npm run dev -- --port 5173 &
VITE_PID=$!
cd ..

# Wait for Vite to start
sleep 3

# Start ngrok tunnels
echo -e "${GREEN}Starting ngrok tunnels...${NC}"

# Create ngrok config for multiple tunnels
cat > /tmp/ngrok-hafapass.yml << EOF
version: "2"
tunnels:
  api:
    addr: 3000
    proto: http
  frontend:
    addr: 5173
    proto: http
EOF

ngrok start --all --config /tmp/ngrok-hafapass.yml &
NGROK_PID=$!

# Wait for ngrok to establish tunnels
sleep 5

# Get ngrok URLs
echo -e "${BLUE}Fetching ngrok tunnel URLs...${NC}"
NGROK_API_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"https://[^"]*' | grep 3000 | cut -d'"' -f4 || echo "")
NGROK_FRONTEND_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"https://[^"]*' | grep 5173 | cut -d'"' -f4 || echo "")

if [ -z "$NGROK_API_URL" ] || [ -z "$NGROK_FRONTEND_URL" ]; then
    # Try alternative parsing
    TUNNELS=$(curl -s http://localhost:4040/api/tunnels)
    echo -e "${YELLOW}Raw tunnels response:${NC}"
    echo "$TUNNELS" | head -c 500
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Services Ready!                      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Rails API:     http://localhost:3000"
echo -e "Vite Frontend: http://localhost:5173"
echo -e ""
echo -e "ngrok API URL:      ${NGROK_API_URL:-'Check http://localhost:4040'}"
echo -e "ngrok Frontend URL: ${NGROK_FRONTEND_URL:-'Check http://localhost:4040'}"
echo -e ""
echo -e "${YELLOW}View ngrok dashboard: http://localhost:4040${NC}"
echo -e ""
echo -e "${BLUE}To start Ralph, open a new terminal and run:${NC}"
echo -e "  cd $(pwd) && ./ralph.sh"
echo -e ""
echo -e "${YELLOW}Press Ctrl+C to stop all services${NC}"

# Wait for any process to exit
wait

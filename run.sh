#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
else
  echo -e "${RED}Error: .env file not found!${NC}"
  echo "Please create a .env file with ZONE_ID and API_TOKEN"
  echo "Copy .env.example to .env and fill in your values"
  exit 1
fi

# Check required environment variables
if [ -z "$ZONE_ID" ] || [ -z "$API_TOKEN" ]; then
  echo -e "${RED}Error: ZONE_ID and API_TOKEN must be set in .env file${NC}"
  exit 1
fi

# Function to extract domain from URL
get_domain_from_url() {
  echo "$1" | sed -E 's|https?://([^/]+).*|\1|'
}

# Function to extract path from URL
get_path_from_url() {
  echo "$1" | sed -E 's|https?://[^/]+(/.*)?|\1|' | sed 's|^$|/|'
}

# Function to generate Cloudflare rule from redirect config
generate_pattern_rule() {
  local description="$1"
  local from="$2"
  local to="$3"
  local status="$4"
  local preserve_query="$5"
  local type="${6:-path}"
  
  if [ "$type" = "subdomain" ]; then
    # Handle subdomain redirects
    local from_domain="${from%%/*}"
    local to_domain="${to%%/*}"
    
    echo '{
      "description": "'"$description"'",
      "enabled": true,
      "expression": "(http.host eq \"'"$from_domain"'\")",
      "action": "redirect",
      "action_parameters": {
        "from_value": {
          "status_code": '"$status"',
          "target_url": {
            "expression": "concat(\"https://'"$to_domain"'\", http.request.uri.path)"
          },
          "preserve_query_string": '"$preserve_query"'
        }
      }
    }'
  else
    # Handle path-based redirects with wildcards
    local from_path="${from%\*}"
    from_path="${from_path%/}"
    
    if [[ "$from" == *"*" ]]; then
      # Calculate substring position (length of path including leading /)
      local substring_pos=$((${#from_path} + 1))
      
      # Extract base domain for the target
      local target_domain=""
      if [[ "$to" == http* ]]; then
        target_domain=$(get_domain_from_url "$to")
      else
        # If no domain specified, we'll need to construct it
        target_domain="\${http.host}"
      fi
      
      echo '{
        "description": "'"$description"'",
        "enabled": true,
        "expression": "starts_with(http.request.uri.path, \"'"$from_path"'/\")",
        "action": "redirect",
        "action_parameters": {
          "from_value": {
            "status_code": '"$status"',
            "target_url": {
              "expression": "concat(\"https://\", http.host, \"/\", substring(http.request.uri.path, '"$substring_pos"'))"
            },
            "preserve_query_string": '"$preserve_query"'
          }
        }
      }'
    else
      # Exact path match
      local target_url="$to"
      if [[ "$to" != http* ]]; then
        target_url="https://\${http.host}$to"
      fi
      
      echo '{
        "description": "'"$description"'",
        "enabled": true,
        "expression": "(http.request.uri.path eq \"'"$from_path"'\")",
        "action": "redirect",
        "action_parameters": {
          "from_value": {
            "status_code": '"$status"',
            "target_url": {
              "value": "'"$target_url"'"
            },
            "preserve_query_string": '"$preserve_query"'
          }
        }
      }'
    fi
  fi
}

# Function to generate rule for CSV one-to-one redirects
generate_csv_rule() {
  local old_url="$1"
  local new_url="$2"
  local status="$3"
  local preserve_query="$4"
  
  local old_domain=$(get_domain_from_url "$old_url")
  local old_path=$(get_path_from_url "$old_url")
  local description="Redirect $old_path to $new_url"
  
  echo '{
    "description": "'"$description"'",
    "enabled": true,
    "expression": "(http.host eq \"'"$old_domain"'\" and http.request.uri.path eq \"'"$old_path"'\")",
    "action": "redirect",
    "action_parameters": {
      "from_value": {
        "status_code": '"$status"',
        "target_url": {
          "value": "'"$new_url"'"
        },
        "preserve_query_string": '"$preserve_query"'
      }
    }
  }'
}

echo -e "${YELLOW}Cloudflare Redirect Manager${NC}"
echo "============================"
echo ""

# Check for existing ruleset
echo "Checking for existing redirect ruleset..."
RULESET_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
  --header "Authorization: Bearer $API_TOKEN" | \
  jq -r '.result[] | select(.phase == "http_request_dynamic_redirect") | .id')

# Initialize rules array
RULES="["
RULE_COUNT=0

# Process pattern-based redirects if file exists
if [ -f redirectPatterns.json ]; then
  echo -e "${GREEN}✓${NC} Found redirectPatterns.json"
  
  PATTERN_COUNT=$(jq '.redirects | length' redirectPatterns.json)
  echo "  Processing $PATTERN_COUNT pattern redirects..."
  
  for i in $(seq 0 $((PATTERN_COUNT - 1))); do
    REDIRECT=$(jq -r ".redirects[$i]" redirectPatterns.json)
    
    description=$(echo "$REDIRECT" | jq -r '.description')
    from=$(echo "$REDIRECT" | jq -r '.from')
    to=$(echo "$REDIRECT" | jq -r '.to')
    status=$(echo "$REDIRECT" | jq -r '.status')
    preserve_query=$(echo "$REDIRECT" | jq -r '.preserve_query')
    type=$(echo "$REDIRECT" | jq -r '.type // "path"')
    
    RULE=$(generate_pattern_rule "$description" "$from" "$to" "$status" "$preserve_query" "$type")
    
    if [ $RULE_COUNT -gt 0 ]; then
      RULES="$RULES,"
    fi
    RULES="$RULES$RULE"
    RULE_COUNT=$((RULE_COUNT + 1))
  done
else
  echo -e "${YELLOW}!${NC} No redirectPatterns.json found"
fi

# Process CSV one-to-one redirects if file exists
if [ -f redirects.csv ]; then
  echo -e "${GREEN}✓${NC} Found redirects.csv"
  
  CSV_COUNT=$(tail -n +2 redirects.csv | wc -l | tr -d ' ')
  echo "  Processing $CSV_COUNT one-to-one redirects..."
  
  # Read CSV file (skip header)
  tail -n +2 redirects.csv | while IFS=, read -r old_url new_url status preserve_query
  do
    # Remove any quotes and whitespace
    old_url=$(echo "$old_url" | tr -d '"' | xargs)
    new_url=$(echo "$new_url" | tr -d '"' | xargs)
    status=$(echo "$status" | tr -d '"' | xargs)
    preserve_query=$(echo "$preserve_query" | tr -d '"' | xargs)
    
    # Default values if not specified
    status=${status:-301}
    preserve_query=${preserve_query:-true}
    
    RULE=$(generate_csv_rule "$old_url" "$new_url" "$status" "$preserve_query")
    
    if [ $RULE_COUNT -gt 0 ]; then
      RULES="$RULES,"
    fi
    RULES="$RULES$RULE"
    RULE_COUNT=$((RULE_COUNT + 1))
  done
else
  echo -e "${YELLOW}!${NC} No redirects.csv found"
fi

RULES="$RULES]"

# Check if we have any rules to apply
if [ $RULE_COUNT -eq 0 ]; then
  echo ""
  echo -e "${RED}Error: No redirect rules found!${NC}"
  echo "Please create either:"
  echo "  - redirectPatterns.json for pattern-based redirects"
  echo "  - redirects.csv for one-to-one redirects"
  exit 1
fi

echo ""
echo "Total rules to apply: $RULE_COUNT"
echo ""

# Create or update ruleset
if [ -z "$RULESET_ID" ]; then
  echo "Creating new redirect ruleset..."
  
  RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets" \
    --request POST \
    --header "Authorization: Bearer $API_TOKEN" \
    --header "Content-Type: application/json" \
    --data '{
      "name": "default",
      "description": "Bulk 301 Redirects",
      "kind": "zone",
      "phase": "http_request_dynamic_redirect",
      "rules": '"$RULES"'
    }')
else
  echo "Updating existing redirect ruleset (ID: $RULESET_ID)..."
  
  RESPONSE=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RULESET_ID" \
    --request PUT \
    --header "Authorization: Bearer $API_TOKEN" \
    --header "Content-Type: application/json" \
    --data '{
      "name": "default",
      "description": "Bulk 301 Redirects",
      "kind": "zone",
      "phase": "http_request_dynamic_redirect",
      "rules": '"$RULES"'
    }')
fi

# Check if successful
SUCCESS=$(echo "$RESPONSE" | jq -r '.success')

if [ "$SUCCESS" = "true" ]; then
  echo -e "${GREEN}✅ Success! Redirect rules have been configured.${NC}"
  echo ""
  
  if [ -f redirectPatterns.json ]; then
    echo "Pattern redirects:"
    jq -r '.redirects[] | "  • \(.from) → \(.to) (HTTP \(.status))"' redirectPatterns.json
  fi
  
  if [ -f redirects.csv ]; then
    echo ""
    echo "One-to-one redirects:"
    tail -n +2 redirects.csv | while IFS=, read -r old_url new_url status preserve_query
    do
      echo "  • $old_url → $new_url (HTTP ${status:-301})"
    done
  fi
else
  echo ""
  echo -e "${RED}❌ Error configuring redirect rules:${NC}"
  echo "$RESPONSE" | jq '.'
fi
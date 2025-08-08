# How to Bulk 301 Redirects with Cloudflare

- ✅ Bulk redirect management via Cloudflare API
- ✅ Pattern-based redirects with wildcards (`/old/*` → `/new/*`)
- ✅ Subdomain redirects (both pattern-based and CSV)
- ✅ One-to-one URL mappings via CSV (supports subdomains)
- ✅ Preserves existing redirect rules
- ✅ Supports 301, 302, 307, 308 status codes
- ✅ Optional query string preservation


## Watch the video

![cloudflareredirectsinbulk301](https://github.com/user-attachments/assets/b7eef5b6-3517-4b7c-b4f7-8e6023cd4088)



## Requirements

- Cloudflare account with API access
- `jq` installed for JSON processing
- `curl` for API requests
- Bash shell

## Important Notes

- Your domain must be proxied through Cloudflare (orange cloud ON) for redirects to work
- Redirects won't work if your DNS record points directly to another service (e.g., Hashnode, Vercel)
- Free Cloudflare plans support up to 10 redirect rules

## 1. Rename the `.env.example` file to just `.env`

## 2. Get your Cloudflare Zone ID

1. Log into your Cloudflare dashboard
2. Select your domain (e.g., devinschumacher.com)
3. On the right sidebar under "API" section, you'll see "Zone ID"
4. Add it to the `.env` file

## 3. Create a Cloudflare API Token:

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Use "Custom token" and click "Get started"
4. Configure the token:
  - **Token name**: "301 Redirects"
  - **Permissions**: 
    - Zone / Single Redirect / Edit
    - Zone → Read
  - **Zone Resources**: 
    - Include → Specific zone → your domain
5. Click "Continue to summary" → "Create Token"
6. Copy the token (save it securely - you won't see it again!)
7. Add it to the `.env` file

## 4. Configure Redirects

Two types of redirects are supported:

1. Pattern-based redirects (redirectPatterns.json)
2. One-to-one redirects (redirects.csv)

### Wildcard redirects

**Fill out the `redirectPatterns.json` file if you want to use this:**
```json
{
"redirects": [
  {
    "description": "Redirect /old-path/* to /new-path/*",
    "from": "/old-path/*",
    "to": "/new-path/$1",
    "status": 301,
    "preserve_query": true
  }
]
}
```

### One-to-one redirects
For exact URL mappings (including subdomains):
```csv
old_url,new_url,status,preserve_query
https://example.com/old-page,https://example.com/new-page,301,true
https://blog.example.com/post,https://example.com/blog/post,301,true
https://old.example.com/,https://example.com/,301,false
```

## 5. Run the Script

```bash
chmod +x run.sh
./run.sh
```

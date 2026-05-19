# Copy to config.ps1 (gitignored) and fill in your own values.
# Source this file in your PowerShell $PROFILE so all hook scripts pick up the values:
#   . "$env:USERPROFILE\.claude\hooks\config.ps1"

# === ntfy server ===
$env:NTFY_SERVER_URL     = 'http://YOUR_SERVER_IP:PORT'          # e.g. http://10.0.0.1:5034
$env:NTFY_SERVER_HOSTPORT = 'YOUR_SERVER_IP:PORT'                # without scheme
$env:NTFY_USER           = 'YOUR_USERNAME'                       # ntfy account user
$env:NTFY_PASSWORD       = 'YOUR_PASSWORD'                       # ntfy account password
$env:NTFY_TOKEN          = 'YOUR_NTFY_ACCESS_TOKEN'              # access token (preferred over user/pass for Bearer)

# === Topic naming ===
# All slots derive from this prefix: <PREFIX>-1, <PREFIX>-2, ..., <PREFIX>-9
$env:NTFY_TOPIC_PREFIX   = 'myhost-cc-slot'

# Legacy outbox topic (optional) — used as default fallback when ntfy-stop.ps1 can't match a slot.
# Subscribe to this on your phone if you also want "everything that wasn't routable" to land somewhere.
$env:NTFY_LEGACY_TOPIC   = 'myhost-cc-legacy'

# === Optional: PowerShell proxy (only if your ntfy server is unreachable without proxy) ===
# $env:HTTPS_PROXY = 'http://127.0.0.1:7890'
# $env:HTTP_PROXY  = 'http://127.0.0.1:7890'

Write-Host "[config] Loaded: server=$env:NTFY_SERVER_HOSTPORT user=$env:NTFY_USER topic_prefix=$env:NTFY_TOPIC_PREFIX"

# Hermes Agent: operator steps

`modules/services/hermes/` runs Hermes Agent as the `hermes` user, plus
Hindsight (memory) and SearXNG (search). Everything below happens outside the
repo: secrets, accounts, and the logins Hermes keeps in its own state
(`/var/lib/hermes`).

## 1. Secrets (before merging: the build fails without them)

Add to `hosts/arbiter/secrets.yaml` with `sops`:

| Key | Value |
|---|---|
| `hermes/email-address` | The agent's own Gmail address (step 2) |
| `hermes/email-app-password` | That account's app password |
| `hermes/email-allowed-users` | Comma-separated addresses that may talk to it, e.g. `you@example.com,other@example.com` |
| `hermes/dashboard-password` | Password for the dashboard login `admin` (web UI, Desktop's Remote mode) |
| `hermes/dashboard-auth-secret` | `openssl rand -base64 32` (signs dashboard sessions) |
| `hindsight/claude-token` | `claude setup-token` on any machine logged in to the Max account |
| `searxng/secret-key` | `openssl rand -hex 32` |

## 2. Gmail account

A new Google account used only by the agent, because Hermes gets full IMAP
access to it. Turn on 2-step verification, then create an app password
(Google Account → Security → App passwords). Only mail that Gmail itself
authenticated (`Authentication-Results` from `mx.google.com`) from an address
on the whitelist gets an answer; everything else is ignored silently.

## 3. TEMPLAR

Hindsight's embeddings come from Ollama on TEMPLAR, which already accepts
ARBITER for ContextForge. Pull the model once:

```sh
ollama pull qwen3-embedding:0.6b
```

Hindsight won't start until TEMPLAR answers (it retries every minute). Don't
change the model once memories exist: the vector size is fixed by the first
one.

## 4. Logins, as `hermes`

```sh
ssh hermes@arbiter
claude                 # /login with the Max account (for the Claude plugin)
agy                    # sign in with the Google AI Pro account
hermes model           # pick each provider and sign in:
                       #   Claude Subscription DirectSDK (uses the claude login above)
                       #   Antigravity subscription (uses the agy login)
                       #   ChatGPT / Codex: device code, open the URL anywhere
                       #   xAI Grok OAuth: device code
                       #   Ollama: models are listed from TEMPLAR
                       # then make Claude the default model
hermes memory status   # Hindsight should show "available" and active
```

The ChatGPT and Grok sign-ins use device codes, so no SSH tunnel is needed.
For any flow that wants a `localhost` callback, see Hermes'
"OAuth over SSH" guide (`ssh -L <port>:127.0.0.1:<port> hermes@arbiter`).

**Grok:** xAI documents the OAuth path for SuperGrok and X Premium+ only. If
chat with Grok returns HTTP 403 after a good login, plain Premium isn't
entitled: remove it (`hermes auth list`, then `hermes auth remove xai-oauth <n>`).

Afterwards, as admin: `sudo systemctl restart hermes-agent hermes-backend`.

## 5. Clients

- **Web:** `https://hermes.<domain>` (LAN and WireGuard), login `admin` and the
  dashboard password.
- **Hermes Desktop:** Settings → Gateways → Add → **SSH**: host `arbiter`,
  user `hermes`, your SSH key. That mode has every screen. The fallback is
  **Remote gateway** with `https://hermes.<domain>` and the dashboard login.
- **Official mobile app (beta):** not documented yet; it is said to connect
  to your own gateway. Try `https://hermes.<domain>` over WireGuard. If it
  needs anything on the host, it needs a change here.
- **E-mail:** write to the agent's Gmail address from a whitelisted address.

## Notes

- The browser profile (`/var/lib/hermes/browser-profile`) persists. Anything
  it is logged in to can be used by every whitelisted sender.
- Both Claude paths (Hermes' plugin and Hindsight) drive the Claude Code CLI
  on the Max subscription's Agent SDK allowance. Hindsight logs a warning
  that automated use of a subscription "may conflict with Anthropic's terms".
- Plugins are pinned in the module to the commits Hermes' plugin catalog
  reviewed. When bumping the `hermes-agent` input, check
  `plugin-catalog/{hindsight,claude-subscription-directsdk,antigravity-subscription-directsdk}.yaml`
  for new SHAs.

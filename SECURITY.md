# Security

This plugin controls physical hardware on your local network and stores a
credential on disk. This document covers the threat model, what's already
mitigated, what's an inherent limitation of the Hue v1 API rather than a bug
here, and how to report a vulnerability.

## Reporting a vulnerability

Please **do not** open a public issue for a security report. Instead, use
GitHub's private disclosure: this repo's **Security** tab → **Report a
vulnerability** (GitHub Security Advisories). If that's unavailable to you,
open an issue asking to be pointed to a contact rather than describing the
problem publicly.

When reporting, **never paste the contents of `~/.local/state/omarchy/hue.json`**
into an issue, advisory, log, or screen recording. That file's `username`
field is a long-lived bearer token that grants full control of your bridge —
treat it like a password. If you're filing a bug and think the state file is
relevant, describe its shape (which keys are present) rather than its values.

## What's already mitigated

- **The bridge token never leaves your machine.** `hue.py` only talks to
  `http://<your bridge IP>/...` on the local network and, for discovery
  only, `https://discovery.meethue.com/` (no bridge credential is ever sent
  there). Nothing is transmitted to any third-party service.
- **Credential storage:** the paired bridge IP + token live at
  `~/.local/state/omarchy/hue.json`, written with `0600` permissions and its
  parent directory forced to `0700`, so other local users on a shared
  machine can't read it.
- **No shell injection:** every subprocess invocation (both the QML→Python
  boundary and `hue.py`'s own `avahi-browse` call) uses an argument list,
  never a shell string. User-controlled values are never interpolated into a
  shell command.
- **No `eval`/`exec`/dynamic code loading** anywhere in the Python or QML.
- **Path/identifier validation:** room and light identifiers, and the bridge
  IP used for pairing, are validated (`valid_id`/`valid_ip` in `hue.py`)
  before being interpolated into a request URL, rather than trusted as
  opaque strings. This is defense-in-depth — the QML UI only ever sources
  these values from the bridge's own status response — but it protects
  anyone who invokes `hue.py` directly from the CLI too.
- **No remote content is rendered.** The UI never loads an `Image` or other
  resource from a URL; colours and text are the only bridge-derived content
  displayed, so there's no path for a malicious bridge response to reach a
  network fetch or script execution in the UI layer.
- **CI runs on `pull_request`, not `pull_request_target`,** with no
  repository secrets and read-only default permissions — a malicious PR
  cannot exfiltrate secrets or gain write access through CI. See
  [CONTRIBUTING.md](CONTRIBUTING.md) for why this matters and why it must
  stay that way.

## Known limitations (inherent to the Hue v1 local API, not fixable here)

- **Bridge traffic is plaintext HTTP.** The Hue Bridge's local v1 API does
  not offer TLS with a browser/client-trusted certificate. Anyone who can
  observe traffic on your local network can see (but not usefully replay
  cross-session, since the token is bound to your bridge) the commands sent
  to your bridge. This is true of every Hue v1 integration, not specific to
  this plugin.
- **No cryptographic bridge identity.** Pairing trusts whatever device
  answers `GET /api/config` on a discovered IP with a `bridgeid` field.
  A hostile device on your LAN could in principle impersonate a bridge at
  discovery time. The impact is limited (worst case: your lights commands
  go to the impersonator instead of your real bridge, which is a privacy/
  availability nuisance, not remote code execution or credential theft
  beyond what a LAN attacker already has), and requires an attacker who is
  already on your local network. This is a property of the Hue v1 protocol
  itself.
- **Physical pairing window:** anyone with access to press your bridge's
  physical link button can pair a new client during the ~30 second window
  after pressing it — standard Hue behavior, not something a software
  client controls.

## Suggestions for further hardening (not yet implemented)

Ideas worth considering if this project grows a userbase — deliberately not
done unilaterally since each has a tradeoff:

- **Custom GitHub secret-scanning pattern** for the Hue bridge token shape,
  so a token accidentally pasted into an issue/PR gets flagged automatically.
- **Signed commits** required on `main`, if a second maintainer joins.
- **Pin GitHub Actions to a full commit SHA** (not just a version tag) in any
  workflow this repo adds, to resist upstream tag-mutation supply-chain
  attacks.
- Bridge IP **pinning/alerting** if the paired bridge's `bridgeid` changes
  unexpectedly between refreshes (would catch a mid-session impersonation
  swap, at the cost of extra complexity for a low-likelihood scenario).

If you think of others, open an issue (non-sensitive ones only — see
reporting above for actual vulnerabilities).

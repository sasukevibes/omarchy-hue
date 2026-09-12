# Contributing

Thanks for considering a contribution. A few ground rules that keep this
small plugin easy to trust and maintain.

## Pull requests only

`main` is protected: every change lands through a pull request with at least
one approving review — direct pushes aren't accepted, including from the
maintainer, except in narrow circumstances GitHub's branch protection allows
for repo admins. Fork, branch, open a PR.

## Before opening a PR

- Keep the backend (`hue.py`) dependency-free (Python 3 standard library
  only). This plugin's whole security story rests on having a tiny,
  readable surface area — a new dependency is a new supply chain to audit.
- If you touch anything that builds a URL or shell command from
  user/bridge-supplied input (`hue.py`'s `api`, `set_room`, `set_light`,
  `pair`, `bridge_config`, or the `valid_id`/`valid_ip` validators), explain
  in the PR description what input can reach that code path and why it's
  still safe. This is the single place a real vulnerability could hide.
- QML changes: never load an `Image` or other resource from a
  bridge-supplied or otherwise remote URL, and never add `eval`/dynamic code
  loading. Keep bridge data rendered as text/color only.
- Run `python3 -m py_compile hue.py` locally; CI checks this too.
- Match the existing code style (no comments explaining *what* code does,
  only non-obvious *why*; reuse the shared `qs.Ui` components already used
  throughout `HueControls.qml` rather than hand-rolling new widgets).

## CI and workflows

The `.github/workflows/ci.yml` syntax-check workflow runs on `pull_request`
with default (read-only) permissions and no repository secrets — intentional,
so a malicious PR can't use CI to exfiltrate secrets or push changes. Please
don't change its trigger to `pull_request_target`, don't give it write
permissions, and don't add secrets to it, without opening a separate
discussion first — that combination is a well-known supply-chain footgun
(a "pwn request") in public repos that build/run PR code.

## Reporting a security issue

Don't open a public issue — see [SECURITY.md](SECURITY.md) for private
disclosure instructions.

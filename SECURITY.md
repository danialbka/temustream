# Security policy

## Supported versions

Security fixes are made on the current default branch. Older source snapshots,
personal sideloads, and third-party builds are not supported unless a release
note says otherwise.

## Report a vulnerability privately

Use **Security > Report a vulnerability** on the GitHub repository when private
vulnerability reporting is available. If it is unavailable, open a public issue
that asks a maintainer for a private contact route, but do not include the
vulnerability details.

Include the affected commit or version, platform, impact, and a minimal way to
reproduce the problem. Use public-domain media and redact account tokens,
stream URLs, add-on URLs, device identifiers, server addresses, logs, and user
data. Please allow the maintainers time to confirm and coordinate a fix before
publishing details.

## Never commit or attach secrets

Do not commit or upload:

- Apple IDs, app-specific passwords, authentication keys, certificates,
  private keys, provisioning profiles, or device identifiers
- Stremio credentials, session tokens, add-on credentials, signed stream URLs,
  cookies, or account exports
- Convex or LiveKit server secrets, deployment credentials, `.env` files, or
  local Xcode signing configuration
- signed apps, IPAs, app containers, playback history, private crash logs, or
  Sideloadly snapshots

If a secret reaches a commit, issue, log, or chat, treat it as exposed. Revoke
or rotate it first. Removing the visible file is not enough because Git history
and caches may still contain it.

Run the repository gate before publishing a branch or release:

```sh
./scripts/public-release-check.sh --history
```

The scanner reports matching file paths without printing credential values. It
is a useful guardrail, not a substitute for GitHub secret scanning or a manual
review of release artifacts.

## Backend deployment warning

The Watch Together backend is disabled in the default app build. The included
Convex functions are a development starting point, not a hardened public
service. A public operator must add admission controls, rate limits, quotas,
record retention, abuse handling, monitoring, and an incident process before
enabling the endpoints for users.

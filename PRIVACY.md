# Privacy

Bunny has no first-party analytics, advertising SDK, or tracking domain.
The default build does not configure the optional Watch Together backend. The
app still makes network requests when you browse catalogs, connect services, or
play media, so the services you choose can receive data directly from your
device.

## Data kept on the device

Depending on the features you use, Bunny stores settings, installed
add-on URLs, a streaming-server URL, local profiles, library entries, playback
progress, and the last successful playback choice in the app container. Signed
iOS and watchOS builds store the Stremio session token in Keychain; simulator
builds use protected app storage instead. The standalone watch app keeps its
account library, progress, and installed add-ons in separate per-account
storage scopes.

Some stream URLs include short-lived access tokens. They should be treated as
sensitive even when they stop working later.

## Network connections

The app may connect to:

- Stremio account APIs when you sign in or synchronize your library and
  installed add-ons
- add-on manifests and their catalog, metadata, and stream endpoints
- poster, backdrop, subtitle, and trivia sources referenced by catalog data
- the loopback, private-network, or HTTPS streaming server you configure
- the media host behind a stream you choose
- a Convex and LiveKit deployment when an iOS build has Watch Together enabled

The standalone Apple Watch app makes its own account, add-on, streaming-server,
and media requests. It does not use WatchConnectivity, copy the iPhone app's
state, or join Watch Together rooms. Resolved media and conversion URLs stay in
memory; watch playback history stores the title, provider, catalog origin, and
time position instead.

Bunny's watch code does not log the components of resolved media URLs.
Apple's AVPlayer and CoreMedia diagnostics can still include a full asset URL in
device or simulator system logs. Streaming services should issue short-lived
URLs, and users should avoid sharing media playback logs.

Third-party services have their own retention, logging, and privacy practices.
Review an add-on or server before installing it. Do not enter a private manifest
URL into a build, screenshot, issue, or log that will be shared publicly.

## Watch Together operators

When configured, Watch Together sends the content identity, playback state,
room presence, and optional microphone audio needed for a room. It is designed
not to publish stream URLs, provider tokens, or Stremio credentials to other
room members. Voice chat remains off until a participant enables it.

Anyone operating the sample backend becomes responsible for its privacy policy,
retention and deletion process, security controls, and App Store privacy
answers. The checked-in privacy manifest describes the default build, where
those endpoints are empty. Update the manifest and App Store privacy details if
a distributed build collects data through a production backend.

## Deleting data

Signing out removes the locally stored Stremio session and switches the watch
back to its anonymous data scope. Uninstalling removes the app container, but
operating systems may retain Keychain items after an uninstall; sign out first
when possible. Revoking access with connected services may also be necessary
to end remote sessions. Backend operators must provide their own deletion
route for data stored in Convex or another hosted service.

## App Store review

Before submission, archive the exact release build and generate Xcode's privacy
report. Compare that report with this document and the answers in App Store
Connect. Dependency updates and newly configured services can change the
result.

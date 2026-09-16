# Direct network traffic

The Direct edition's Network tab shows measured download and upload traffic for
all apps on one selected interface, including traffic to devices on the local
network. It does not measure maximum connection capacity. The interface name and
sampling status remain visible, and unavailable readings use a dash rather than
a misleading zero. The unit picker stores Mbps or MB/s in the current app bundle's
preferences; Mbps is the default.

The local Swift 6 `Shared/NotchHubNetwork` package provides the passive counter
reader, interface selection, sample freshness and observable presentation state.
Only `NotchHubCore` links it. `NotchHubSafeFeatures` and the Lite executable retain
their existing dependency graph and entitlements.

Monitoring requires the Network content to be visible in the expanded ribbon.
Switching tabs, collapsing, content disappearance, sleep and shutdown stop it.
Waking resumes only an already-visible Network tab. The UI lifecycle gate makes
repeated callbacks idempotent; the shared monitor owns baseline resets and stale
reading expiry. No app-wide App Nap override, active test, connectivity probe,
outage history, packet capture or extra permission is added.

The Direct bundle ships the shared package's Apache 2.0 license and source/change
notice as `ThirdParty/InternetSpeedReader-LICENSE.txt` and
`ThirdParty/InternetSpeedReader-NOTICE.txt`; Lite bundles neither.

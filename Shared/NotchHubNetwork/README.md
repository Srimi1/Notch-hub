# NotchHubNetwork

`NotchHubNetwork` measures current receive and transmit traffic for one active
macOS network interface. It reads cumulative 64-bit kernel counters through
`NET_RT_IFLIST2`; it makes no outbound requests and does not run a capacity
speed test.

Create one `NetworkTrafficModel` on the main actor. Call `start()` only while
the Network UI is visible and `stop()` as soon as it is hidden. The model is
idempotent and exposes both a value snapshot and direct read-only properties:

```swift
@State private var traffic = NetworkTrafficModel()

Text(traffic.state.message)
Text(NetworkTrafficUnit.megabitsPerSecond.format(mbps: traffic.downloadMbps))
```

The first valid counter read establishes a baseline, so `state` remains
`.measuring` until a later read can form a trustworthy delta. A `.live` state
can contain measured zeroes. `.unavailable(message:)` means there is no current
trustworthy reading. `sourceError` retains typed diagnostic details while the
state message remains safe to display.

`NetworkTrafficMonitor` accepts public counter, path, time, and lifecycle
source protocols for deterministic tests. Production defaults use `sysctl`,
`NWPathMonitor`, `ContinuousClock`, and macOS workspace sleep/wake events.

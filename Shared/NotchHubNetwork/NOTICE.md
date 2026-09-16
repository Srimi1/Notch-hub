# Third-party notice

`NotchHubNetwork` incorporates and modifies portions of
[Internet-speed-reader](https://github.com/Srimi1/Internet-speed-reader),
retrieved from commit `c5e0f6276186aff6c298732358d11b9fffd54495`.

Copyright 2026 Srimi1 and Internet-speed-reader contributors.

The incorporated work is licensed under the Apache License, Version 2.0. A
copy of that license is included in [`LICENSE`](LICENSE). The adapted source
files carry notices identifying that they were changed for NotchHub.

NotchHub-specific changes include:

- packaging the passive reader as a Swift 6 SwiftPM library;
- preserving typed `sysctl` and parser failures instead of returning an empty result;
- accepting valid short address/multicast records while requiring every
  `RTM_IFINFO2` record to contain its full `if_msghdr2` header;
- exposing a bounded actor stream and an `@MainActor @Observable` model;
- observing the selected interface and sleep/wake lifecycle only while running;
- expiring stale values within three seconds and isolating rapid sampling sessions; and
- removing speed tests, history, outage detection, login-item code, and application UI.

This notice is informational and does not modify the Apache-2.0 license.

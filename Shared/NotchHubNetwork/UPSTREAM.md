# Upstream provenance

The passive counter reader, route-message parser, active-interface selection,
monotonic rate calculation, formatting rules, and monitor design were adapted
from Internet-speed-reader:

- Repository: <https://github.com/Srimi1/Internet-speed-reader>
- Revision: `c5e0f6276186aff6c298732358d11b9fffd54495`
- Revision date: 2026-09-05
- License: Apache License 2.0

Only passive traffic measurement was extracted. This package does not contain
the upstream speed-test engines, connectivity probes, outage history, login
item management, status-item UI, or application entry point.

The implementation is intentionally a modified derivative rather than a copied
SwiftPM target. Public names use the `NetworkTraffic` prefix, counter reads
throw typed errors, route parsing rejects malformed record declarations, the
monitor owns interface and lifecycle observation, and presentation state is
exposed through a NotchHub-specific observable model. See `NOTICE.md` for the
redistribution notice.

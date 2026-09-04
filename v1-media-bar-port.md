# V1 Media Bar Port Plan

## Goal

Restore the compact media bar behavior and visual proportions from NotchHub v0.6.0 inside V1 without increasing the current shallow notch panel size or reintroducing the oversized dashboard design.

## Workstreams

1. **Reference audit**
   - Inventory the exact v0.6.0 media row, collapsed playback wing, controls, empty states, data sources, resources, and required permissions.
   - Separate visual/interaction requirements from legacy implementation details that are unsafe under Swift 6.

2. **V1 media architecture**
   - Add a strict-concurrency-safe now-playing domain model and lifecycle-owned media presentation model.
   - Keep media availability limited to the Direct build unless a source is compatible with App Sandbox.
   - Route source failures into typed diagnostics and a useful unavailable state.

3. **Compact UI integration**
   - Match v0.6.0 artwork, title/artist hierarchy, and previous/play-next controls.
   - Preserve V1's 860 x 136 expanded footprint and shallow collapsed notch behavior.
   - Add a compact playback wing only when now-playing activity warrants it.

4. **Packaging and security**
   - Package only explicitly owned runtime resources and document any third-party component/license.
   - Validate subprocess paths, inputs, timeouts, descriptor ownership, and termination behavior.
   - Do not add credentials, network access, or broader entitlements.

5. **Verification**
   - Unit-test parsing, command routing, lifecycle, source failure/unavailable behavior, and compact layout state.
   - Build and visually smoke-test minimum and expanded states.
   - Run V1 quality gate, strict-concurrency checks, TSan adapter tests if subprocess code is used, and the root regression gate.

## Definition of Done

- Media bar closely matches v0.6.0 while fitting V1's current compact shell.
- Previous, play/pause, and next controls work or fail visibly and safely.
- No new SwiftFormat or SwiftLint findings; tests and builds pass.
- No new concurrency warnings, unsafe silent error handling, or unnecessary permissions.

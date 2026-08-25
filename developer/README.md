# developer

Build artefacts kept deliberately, outside the throwaway `dist/` directory that
every packaging run wipes.

## NotchHub-0.3.0-arm64.dmg

The 0.3.0 disk image as it was published to GitHub on 2026-08-25.

- SHA-256: `378c7eb87c50239cee4b51f96c1753eb34ac6368eb350eacb10e970c193931fa`
- Built from `e693e30` (tag `v0.3.0`)
- Signed `Apple Development: 917762034141 (XB7X3VP977)`, hardened runtime,
  timestamped. **Not notarized**, and **arm64 only** — those are the two things
  0.3.1 sets out to improve.

Kept for comparison and because the published release referenced this exact
image. Do not delete it when cleaning `dist/`.

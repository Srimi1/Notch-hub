# mediaremote-adapter (vendored)

Upstream: <https://github.com/ungive/mediaremote-adapter>
Version: **v0.7.6**
Tarball SHA-256: `0891554af8ee8fc1bb1d14ddf023f8e4ce3093387391122c865f7e02c2d1f3de`
License: BSD 3-Clause — see [LICENSE](LICENSE) and [ACKNOWLEDGMENTS.md](../../ACKNOWLEDGMENTS.md).

## Why this is here

macOS 15.4 slammed the door on the private `MediaRemote` framework: loading it
from inside a normal app returns nothing at all. Only processes whose bundle
identifier starts with `com.apple.` are still allowed in — and `/usr/bin/perl`
is one of them.

This project is the workaround. A Perl script runs under the Apple-signed perl
binary, dynamically loads a small helper framework, and prints now-playing
information as JSON. That is how NotchHub sees **any** player — YouTube Music in
a browser tab, an Electron client, a PWA — instead of only the two apps that
happen to expose an AppleScript dictionary.

The framework is **bundled, never linked**. NotchHub does not import it and does
not call `MediaRemote` itself; it only passes the framework's path to the script
as an argument.

## What is vendored

Only what the framework build needs:

- `bin/mediaremote-adapter.pl` — the script NotchHub invokes
- `include/` and `src/` — framework sources

That includes `src/test`, which looks droppable and is not: `src/adapter/test.m`
is part of the framework and imports `test/NowPlayingTest.h`, so removing the
directory fails the build with a missing header.

What is deliberately **not** built is the `MediaRemoteAdapterTestClient`
executable. The upstream `test` command answers "is the adapter still
functional?", but it does so by briefly publishing a fake now-playing entry that
other apps on the machine can see. NotchHub instead treats repeated adapter
crashes as "unavailable" and falls back to AppleScript, which costs nothing and
disturbs nobody. If a future macOS breaks `MediaRemote` in a way that fails
*silently* rather than loudly, build the test client and wire the `test` command
in — that is the tool for it.

## Building

`scripts/build-adapter.sh` compiles these sources into
`MediaRemoteAdapter.framework` with plain `clang` (universal `arm64` +
`x86_64`), so no CMake install is required. `scripts/build-app.sh` runs it and
drops the result into `NotchHub.app/Contents/Frameworks`, with the script in
`Contents/Resources`.

## Updating

```bash
curl -sSL -o mra.tar.gz https://github.com/ungive/mediaremote-adapter/archive/refs/tags/vX.Y.Z.tar.gz
shasum -a 256 mra.tar.gz            # record it above
mkdir mra && tar -xzf mra.tar.gz -C mra --strip-components=1
rm -rf Vendor/mediaremote-adapter/{bin,include,src}
cp -R mra/{bin,include,src} Vendor/mediaremote-adapter/
cp mra/LICENSE Vendor/mediaremote-adapter/LICENSE
./scripts/build-adapter.sh /tmp/adapter-check    # must succeed
```

Upstream warns that its API may break across minor revisions — re-read
`MediaRemoteAdapterSource.swift` against the new `stream` output before shipping
a bump.

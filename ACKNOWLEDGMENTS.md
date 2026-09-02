# Acknowledgments

NotchHub bundles third-party code and artwork. Their licenses are reproduced
with the material they cover.

## mediaremote-adapter

- Source: <https://github.com/ungive/mediaremote-adapter> (v0.7.6)
- Author: Jonas van den Berg and contributors
- License: BSD 3-Clause — [`Vendor/mediaremote-adapter/LICENSE`](Vendor/mediaremote-adapter/LICENSE)

Used to read system-wide now-playing information and send transport commands.
Since macOS 15.4 the private `MediaRemote` framework answers only processes
whose bundle identifier begins with `com.apple.`; this project works around that
by running its helper framework under `/usr/bin/perl`. It is what lets NotchHub
show and control players that expose no AppleScript interface, YouTube Music
among them.

The sources are vendored under [`Vendor/mediaremote-adapter`](Vendor/mediaremote-adapter/README.md)
and built into `NotchHub.app/Contents/Frameworks` at package time. NotchHub does
not link against the framework.

## Purge

- Source: <https://github.com/jithin-sabu/purge-app> (commit `dedb5936`)
- Author: Jithin Sabu
- License: MIT — [`Vendor/purge-app/LICENSE`](Vendor/purge-app/LICENSE)

The cache cleanup in the Focus panel is built on Purge's safety work: its
250-entry catalog of which cache folders are safe to clear and which are worth
checking first, the list of account and identity daemons whose caches must never
be touched, the never-delete paths, and the locations of the developer caches.

None of Purge's code is compiled or shipped here. The catalog was converted into
Swift tables by [`scripts/generate-cache-catalog.py`](scripts/generate-cache-catalog.py)
and the rules were rewritten to this project's file, concurrency, and testing
rules. [`Vendor/purge-app/README.md`](Vendor/purge-app/README.md) records exactly
what was taken and how to refresh it.

## Lottie

- Source: <https://github.com/airbnb/lottie-ios> (4.6.1)
- Author: Airbnb, Inc. and contributors
- License: Apache-2.0

NotchHub's only runtime dependency, and the reference player for the Bodymovin
JSON format. It is linked statically by SwiftPM, so no framework is embedded in
the app bundle. It is used for one thing: playing the animation below exactly as
its designer authored it, rather than approximating it in SwiftUI.

## "Astronaut and music"

- Source: <https://lottiefiles.com/free-animation/astronaut-and-music-LCnjoHn7f0>
- Author: Artemiy (<https://lottiefiles.com/artemiy>)
- Obtained from LottieFiles under its free-animation license

The astronaut in the Media panel. The animation is vendored verbatim at
[`Resources/Animations/astronaut-and-music.json`](Resources/Animations/astronaut-and-music.json)
and copied into `NotchHub.app/Contents/Resources/Animations` at package time.
NotchHub scales it and pauses it under Reduce Motion; nothing else about it is
altered.

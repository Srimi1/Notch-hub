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

# Acknowledgments

NotchHub bundles third-party code. Their licenses are reproduced with the code
they cover.

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

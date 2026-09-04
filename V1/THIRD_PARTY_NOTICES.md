# Third-Party Notices

## CodexBar

CodexBar is used as a public behavioral and performance reference. No CodexBar
runtime or source code is included in NotchHub V1.

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Sparkle

The direct-distribution build includes Sparkle for signed application updates.
The Direct bundle includes its license and bundled third-party notices as
`ThirdParty/Sparkle-LICENSE.txt`. The Lite edition does not include Sparkle.

## Lottie

The Direct edition links Lottie for iOS 4.6.1 statically to render the compact
Media bar's Bodymovin artwork. Copyright 2018 Airbnb, Inc. and contributors;
licensed under Apache License 2.0. The Direct bundle includes
`ThirdParty/Lottie-NOTICE.txt` and `ThirdParty/Lottie-LICENSE.txt`. The Lite
edition does not include Lottie or these notices. The pinned Lottie privacy
manifest is installed as `PrivacyInfo.xcprivacy` in the Direct app's Resources
directory and is absent from Lite.

## mediaremote-adapter

The Direct edition bundles mediaremote-adapter 0.7.6 as a helper framework and
Perl script. It is built from the repository's vendored source, invoked through
`/usr/bin/perl`, and is never linked into the NotchHub executable. Copyright
(c) 2025 Jonas van den Berg and contributors; licensed under the BSD 3-Clause
License. The Direct bundle includes the complete license as
`ThirdParty/MediaRemoteAdapter-LICENSE.txt` and attribution as
`ThirdParty/MediaRemoteAdapter-NOTICE.txt`. The Lite edition includes neither
the adapter nor these files.

## "Astronaut and music"

The Direct edition bundles the "Astronaut and music" animation by Artemiy from
LottieFiles under the Lottie Simple License (FL 9.13.21).
The unchanged Bodymovin JSON is stored as
`Animations/astronaut-and-music.json`; source and license attribution are in
`ThirdParty/Astronaut-and-Music-NOTICE.txt`, and the complete terms are in
`ThirdParty/Astronaut-and-Music-LICENSE.txt`. The Lite edition does not include
the artwork, license, or notice.

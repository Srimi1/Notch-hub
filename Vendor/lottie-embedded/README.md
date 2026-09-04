# Libraries Lottie embeds (licence notices)

Lottie ships as a single compilation unit, so three libraries are vendored
*inside* its own sources rather than declared as dependencies —
`Sources/Private/EmbeddedLibraries` in the lottie-ios checkout says why: the
package managers Lottie supports cannot express them as separate modules.

Linking Lottie statically therefore links these too, and NotchHub redistributes
them in every release image. Their notices are kept here because upstream
Lottie's own `LICENSE` is the bare Apache-2.0 text and does not mention them,
and because `.build/checkouts` is not committed.

| Library | Version | Licence | Notice |
| --- | --- | --- | --- |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | MIT — Thomas Zoechling and the ZIP Foundation project authors | [`ZIPFoundation-LICENSE.txt`](ZIPFoundation-LICENSE.txt) |
| [LRUCache](https://github.com/nicklockwood/LRUCache) | 1.0.4 | MIT — Nick Lockwood | [`LRUCache-LICENSE.txt`](LRUCache-LICENSE.txt) |
| [EpoxyCore](https://github.com/airbnb/epoxy-ios) | 0.11.0 | Apache-2.0 — Airbnb, Inc. | Same licence and same licensor as Lottie itself, so the `Lottie-LICENSE.txt` already in the image covers it |

Both MIT notices ship in the release image's `Licenses` folder. Verified
present by `verify_mounted_image` in [`scripts/build-dmg.sh`](../../scripts/build-dmg.sh).

To refresh after a Lottie bump: read the pinned versions from
`.build/checkouts/lottie-ios/Sources/Private/EmbeddedLibraries/*/README.md`,
then re-copy each upstream `LICENSE` at that tag.

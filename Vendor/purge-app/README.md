# Purge (safety rules, adapted)

Upstream: <https://github.com/jithin-sabu/purge-app>
Commit: `dedb5936efe8dcdc3ced9228ad231ca79800f76a`
Author: Jithin Sabu
License: MIT — see [LICENSE](LICENSE) and [ACKNOWLEDGMENTS.md](../../ACKNOWLEDGMENTS.md).

## What is here

Only this licence and note. **No Purge source is vendored, compiled, or
shipped.** What NotchHub took is the knowledge, rewritten in this project's
own style:

- the 250-entry safety catalog from `purge/Resources/explanations.json`,
  converted by [`scripts/generate-cache-catalog.py`](../../scripts/generate-cache-catalog.py)
  into `Sources/NotchHub/Core/CacheCatalog+Apps.swift` and
  `CacheCatalog+DevTools.swift`. Only the classification fields survive the
  conversion — key, display name, safe/check-first tag, aliases, bundle
  identifiers, scope. The per-entry prose does not: the notch has no room for it;
- the protected-folder rules from `purge/Services/DeletionSafetyPolicy.swift` —
  the account and identity daemons whose caches cause login-keychain prompt
  storms, the substring fragments that catch the ones nobody has catalogued
  yet, the protected containers, and the never-delete paths;
- the tier lists from `purge/Services/SafetyTierList.swift`;
- the developer-cache locations from `purge/Services/DevScanner.swift`, minus
  the entries that are not really caches (see the note in
  `Sources/NotchHub/Core/CacheCatalog+DevToolPaths.swift`).

## Why it was rewritten rather than ported

Purge's core is about 3,200 lines, sizes folders by shelling out to
`/usr/bin/du`, and is built with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
which its `nonisolated` annotations depend on. NotchHub has a 500-line file cap,
runs no subprocesses for this feature, and requires new code to be clean under
Swift 6 strict concurrency. The rules are the valuable part, and they carry over
exactly; the plumbing is this project's own.

## Refreshing the catalog

```bash
git clone --depth 1 https://github.com/jithin-sabu/purge-app.git
scripts/generate-cache-catalog.py purge-app/purge/Resources/explanations.json "$(git -C purge-app rev-parse HEAD)"
```

Then run `swift test --filter CacheCatalogTests`, which checks the conversion:
no duplicate keys, every developer-cache path names a real entry, and a name two
entries claim resolves to the more cautious of the two.

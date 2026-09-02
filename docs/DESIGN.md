# NotchHub Design System

**Intent:** NotchHub draws on two surfaces with opposite rules, and today it has
tokens for one of them that almost nothing uses. This document makes the rules
explicit, anchors each one to a value or a measured threshold, and gives code
review something it can actually check.

Companion to [`ARCHITECTURE.md`](ARCHITECTURE.md), which covers structure. This
covers what things look like and how they behave.

---

## 1. Context and goals

### The two surfaces

Almost every design mistake in this app comes from treating these as one thing.

| | **The Overlay** | **The Window** |
| --- | --- | --- |
| Where | The notch panel: strip, HUD, dashboard, picker | Settings, Onboarding |
| Ground | **True black**, always | The macOS material of the moment |
| Why | It is standing in for the camera housing. Any other ground makes the seam visible. | It is an ordinary app window and should look like one. |
| Colour comes from | `NotchTheme` + explicit `.white` opacities | System semantics — `.secondary`, `.red`, `Form` styling |
| Files | `NotchContainerView`, `NotchHUDView`, `ExpandedDashboardView`, `MediaModuleView`, `ModuleChip`, `ClipPickerView`, `ActivityDetailView` | `SettingsRootView`, `OnboardingView`, `PermissionRowView`, `ActivitySettingsView` |

**Rule 1.1** — On the Overlay you **must not** use system semantic colours
(`.secondary`, `.primary`, `.tertiary`, `Color(nsColor:)`). They are resolved
against the window's appearance, not against black, and will drift with the
system theme on a surface that never changes.

**Rule 1.2** — On the Window you **must not** use `NotchTheme`. Its values are
calibrated against black and are unreadable on a light material.

> Rule 1.1 holds today — all five `.foregroundStyle(.secondary)` call sites are
> in Window files. **Rule 1.2 did not.** Writing this document turned up three
> places in `SettingsRootView` using `NotchTheme.secondaryText`, which is white
> at 68% and calibrated against black:
>
> | Where it was rendering | Contrast |
> | --- | --- |
> | The notch panel — its intended home | 9.40:1 |
> | Settings in dark mode | 7.74:1 |
> | **Settings in light mode** | **1.11:1** |
>
> Three strings were effectively blank for every light-mode user, including the
> screenshot status note and the Accessibility recovery hint — the two messages
> that exist precisely because something has gone wrong. Fixed to `.secondary`.
>
> This is the failure mode both surface rules exist to catch, and it is worth
> naming why it survived review: it looks perfectly fine in dark mode. One
> author introduced it and two more call sites copied the pattern within the
> hour. Neither the compiler nor SwiftLint can see it. Only a computed ratio
> can.

### What is wrong today

Measured across `Sources/NotchHub/UI`:

| Finding | Count | Consequence |
| --- | --- | --- |
| Distinct `.font(.system(size:weight:))` combinations | **26** | No scale — sizes 8 through 24 with no rhythm |
| Distinct raw `.white.opacity()` values | **16** | `NotchTheme` defines 4 of them; the rest are ad hoc |
| Distinct corner radii | **4** (5, 6, 8, 9) | `NotchTheme.cardRadius` (9) is used **once**; `8` is used **ten times** |
| Distinct stack `spacing:` values | **11** (0–14) | No vertical or horizontal rhythm |

The tokens are not missing. They are being bypassed. Everything below is written
to close that gap rather than to invent a new vocabulary.

---

## 2. Tokens and foundations

### 2.1 Colour — the Overlay

Canonical source: `Sources/NotchHub/UI/NotchTheme.swift`. Contrast measured
against the panel's true black using the WCAG 2.2 relative-luminance formula.

| Token | Value | On black | Use for |
| --- | --- | --- | --- |
| *(ground)* | `.black` | — | The panel. Never anything else. |
| primary text | `.white` | **21.00:1** | Titles, values, anything that must be read |
| `secondaryText` | `white @ 0.68` | **9.40:1** | Subtitles, hints, captions |
| `divider` | `white @ 0.14` | 1.35:1 | Hairlines only — decorative, never load-bearing |
| `subtleSurface` | `white @ 0.07` | 1.12:1 | Resting fill for chips and cards |
| `selectedSurface` | `white @ 0.18` | 1.54:1 | Selected fill |

**Rule 2.1.1** — A new white opacity **must not** be introduced. Use a token. If
a genuinely new role exists, add it to `NotchTheme` with a name and a comment,
so the next reader inherits a decision instead of a number.

**Rule 2.1.2** — `subtleSurface` and `selectedSurface` are **surfaces, not
signals**. At 1.12:1 and 1.54:1 neither is distinguishable enough to be the only
thing communicating state. Selection must also be carried by something else —
`ModuleChip` is correct here: it pairs the fill with a `matchedGeometryEffect`
capsule and a label change.

*Don't:* `.background(Color.white.opacity(0.12))`
*Do:* `.background(NotchTheme.subtleSurface)`

### 2.2 Colour — status and accent

`ActivityKind.tint` (`NotchContainerView.swift`) is the accent vocabulary, and it
is deliberately six system colours rather than a brand palette:

| Kind | Tint | Kind | Tint |
| --- | --- | --- | --- |
| Calendar | `.blue` | Battery | `.yellow` |
| Timer | `.orange` | Media | `.mint` |
| Reminder | `.green` | Focus | `.purple` |

**Rule 2.2.1** — NotchHub has **no brand hue**. Colour here means *what kind of
thing this is*, never *which app this is*. Do not introduce a house accent.

**Rule 2.2.2** — Colour **must not** be the only carrier of meaning. Every tinted
element pairs its tint with an SF Symbol. A red error string pairs with the word
that says what failed.

### 2.3 Typography

The Overlay uses SF Pro at small sizes on a dark ground. Twenty-six size/weight
combinations is not a scale; this is.

| Step | Size / weight | Role | Real example |
| --- | --- | --- | --- |
| `display` | 22 regular | The clock in the collapsed strip | `9:41` |
| `title` | 15 semibold | Charge percentage, headline values | `86%` |
| `heading` | 13 semibold | HUD row title, module title | `Screenshot` |
| `body` | 12 semibold / 12 regular | Module content, track title | `Blinding Lights` |
| `caption` | 11 regular | Subtitles, hints, secondary rows | `The Weeknd` |
| `micro` | 10 semibold | Capsule labels, badges | `Copied` |

**Rule 2.3.1** — New UI **must** use a step above. Sizes 8, 9, 14, 16, 17, 19 and
24 are legacy; do not add to them.

**Rule 2.3.2** — Below 11pt, weight **must** be `.semibold` or heavier. Regular
weight at 10pt on black loses its stems to the ground.

**Rule 2.3.3** — Numbers that change in place **must** carry
`.contentTransition(.numericText())`. Already correct in the clock, the charge
percentage and the timer.

### 2.4 Space

**Rule 2.4.1** — Spacing and padding **must** come from a 4pt rhythm:
**2, 4, 8, 12, 16, 20**. The values 3, 5, 6, 7, 10 and 14 currently in the tree
are legacy. Two exceptions are load-bearing and stay:

- `NotchTheme.chipSpacing = 7` — tuned so seven chips flank the camera housing
- `MediaAstronautView` inset `3` — a hairline of ground around the artwork

**Rule 2.4.2** — Structural dimensions come from `NotchTheme` and **must not** be
re-declared: `expandedWidth 860`, `contentHeight 68`, `moduleHeaderWidth 150`,
`horizontalPadding 16`, `verticalPadding 12`, `navigationHeight 32`.

**Rule 2.4.3** — `contentHeight` is a hard 68pt with `.clipped()`. Content that
does not fit **must** be shortened, not allowed to overflow. The panel cannot
grow; the notch is a fixed piece of hardware.

### 2.5 Radius

**Rule 2.5.1** — One token: `NotchTheme.cardRadius = 9`. It is currently used
once while `8` is hardcoded ten times, `6` twice and `5` three times. New code
**must** use the token; touched code **should** migrate to it.

Nested shapes are the one exception: an inner radius **should** be
`cardRadius − inset` so the curves stay concentric.

### 2.6 Motion

Real durations in the tree, and what they are for:

| Duration | Curve | Used for |
| --- | --- | --- |
| 0.22s | `easeOut` (`NotchMotion`) | Panel open and close — the window frame and the SwiftUI content share this one timeline, so they cannot drift apart and stutter |
| 0.25–0.28s | `easeInOut` | Content swaps and tile updates inside the dashboard |
| 0.8–1.1s | `easeInOut`, phased | Ambient loops — the music pulse, the battery breath |
| 0.01s | `linear` | The Reduce Motion substitute |

`NotchMotion` is the single source of truth for open/close motion: both
`NotchViewModel.transitionAnimation` (content) and
`NotchWindowController.animateFrame` (window frame) read their duration and curve
from it.

Timings that are behaviour rather than decoration, from `NotchViewModel`:
`collapseDelay 0.15s`, `peekPromotionDelay 0.6s`. The copy popup's dwell is
`copyPopupDuration` (Brief 1.5s, Standard 2.5s, Long 4.0s; default Brief),
counted down on a monotonic clock so a system-time change cannot stretch it, with
a hover-proof `hudHoverCeiling` (6.0s) that clears it even while the pointer
pauses that countdown.

**Rule 2.6.1** — Every animation **must** be gated on
`@Environment(\.accessibilityReduceMotion)`. Five views do this today. The house
substitutions are `reduceMotion ? nil : animation`,
`reduceMotion ? 1 : scale`, and `.linear(duration: 0.01)`.

**Rule 2.6.2** — An ambient loop **must** have a reason to be running. The
astronaut loops while a track plays and settles when it pauses; the battery
breathes only while charging. A loop that runs regardless is motion the user
cannot switch off by changing what they are doing.

**Rule 2.6.3** — Animation **must not** be the only feedback for a state change.

---

## 3. Component rules

### 3.1 Collapsed strip — the resting state

Two wings flanking the camera housing. The middle **must** stay empty.

- **Left wing:** clock, `display` step, `numericText` transition
- **Right wing:** the current activity — tinted SF Symbol plus one line of text
- **Empty state:** draws **nothing**. This is deliberate and documented in
  `NotchContainerView`: a placeholder here is worse than an empty wing, because
  the strip is on screen permanently.

**Rule 3.1.1** — Nothing new may be added to the strip without an equally
explicit answer for what it looks like when it has nothing to say.

### 3.2 HUD — the transient tier

Grows from the notch, dismisses by sliding down through the pill's bottom edge
where the window mask clips it — the "swallowed" exit. Insertion and removal are
deliberately asymmetric and **must** stay that way.

**Anatomy:** `[ 44×44 icon ] [ title / subtitle ] [ status capsule ]`

| State | Behaviour |
| --- | --- |
| default | Auto-dismisses after `copyPopupDuration` (default Brief, 1.5s; Standard/Long in Settings) |
| hover | Dismissal pauses so the popup can be read or dragged from; when the pointer leaves it resumes with the time that was left, and a hover-proof `hudHoverCeiling` (6.0s) clears it regardless so a resting cursor cannot hold it open |
| click | Expands to the dashboard — but only on genuinely empty space |

**Rule 3.2.1** — Interactive children **must** win the click. The expand gesture
sits *behind* content via `.background`, so a click landing a pixel off a peek
card does not fall through to expand. Any new HUD content follows this.

**Rule 3.2.2** — Icons **must** degrade in a fixed order: thumbnail → file icon →
SF Symbol. Never an empty frame while something loads.

### 3.3 Module row

`[ header 150pt ] │ [ body ]` inside `contentHeight` 68pt.

**Rule 3.3.1** — Every module **must** implement four states: content, empty,
permission-denied, and error. `EmptyHint` is the shared atom for the middle two.

**Rule 3.3.2** — "Nothing yet" and "not allowed" **must not** share a string.
Saying *"Play something"* while music is audibly playing is a lie the user cannot
diagnose, because macOS never re-prompts for Automation. `MediaModuleView` is the
reference implementation.

**Rule 3.3.3** — Errors render as inline text at `caption`, in `.red`, in place of
the content they replace. **No `NSAlert`, ever.** An overlay that blocks the
screen to report that a thumbnail failed is worse than the failure.

### 3.4 Controls

| Control | Size | Floor |
| --- | --- | --- |
| `TransportButton` | 30×30 | ✅ |
| `ModuleChip` (inactive) | 30×30 | ✅ |
| HUD icon / drag handle | 44×44 | ✅ |
| Picker card | 22pt icon + padding | ✅ via `.contentShape` |

**Rule 3.4.1** — Interactive targets **must** be at least **28×28pt**.

> **Conflict, resolved deliberately.** The generic guidance is a 44pt *touch*
> target. NotchHub has no touch surface — it is pointer-only on macOS, where the
> platform convention is 28pt. Applying 44 here would force the module row past
> its 68pt ceiling. Twenty-eight is the floor; 44 is still correct for anything
> draggable, which is why the HUD icon is 44.

**Rule 3.4.2** — Padding **must** be inside the hit target via `.contentShape`,
not outside it.

**Rule 3.4.3** — Every control **must** define default, hover, focus-visible,
pressed and disabled. `focus-visible` is the one most often skipped and the one
keyboard users depend on.

### 3.5 Decorative artwork

**Rule 3.5.1** — Artwork **must** meet **3:1** against the ground it is drawn on,
or be given a ground it does meet.

> The worked example, and the reason this rule exists. The astronaut's ink is
> `rgb(0.098, 0.047, 0.137)`. On the panel's black that is **1.12:1** — below
> even the 1.35:1 of a hairline divider. The music notes and stars were not dim,
> they were *absent*, and the figure read as a smudge. On the `#F6F4F9` tile it
> was drawn for, it measures **17.20:1** and every mark lands.
>
> This was initially presented as a matter of taste. It was not. A 1.12:1 graphic
> is a failure with a number attached, and the number decides it.

**Rule 3.5.2** — A missing asset **must** degrade to the layout that existed
before it, never to a blank frame. See `AnimationLocator`.

**Rule 3.5.3** — Decoration **must** be `.accessibilityHidden(true)`.

---

## 4. Accessibility — testable criteria

Every line here can be checked in review.

| # | Criterion | How to test |
| --- | --- | --- |
| A1 | Text on the Overlay ≥ **4.5:1** | `.white` = 21:1, `secondaryText` = 9.40:1. Any third value must be computed. |
| A2 | Meaningful graphics ≥ **3:1** | Compute ink against its actual ground, not its intended one. |
| A3 | State is never colour alone | Turn the display greyscale. Is the state still readable? |
| A4 | Every animation gated on Reduce Motion | System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion. Nothing may still be moving. |
| A5 | Interactive targets ≥ 28×28pt | Read the `.frame`. Padding outside `.contentShape` does not count. |
| A6 | Focus is visible on the Window | Tab through Settings. Every control must show a ring. |
| A7 | Decoration is hidden from VoiceOver | VoiceOver must not stop on the astronaut. |
| A8 | Overlay uses no system semantic colour | `grep -n "foregroundStyle(.secondary)" Sources/NotchHub/UI` — hits must be Window files only. |
| A9 | Errors reach the user visually | Every `report(_:)` sets a `lastError` some view renders. |

**Rule 4.1** — Where aesthetics and accessibility disagree, accessibility wins,
and the losing option is recorded with its measured number so the trade-off is
not re-litigated from memory.

---

## 5. Content and tone

The repo already has a voice. It is worth naming so it survives.

**Say what happened, in the user's terms.**
✅ `Play something — it shows up here.`
❌ `No media source available`

**Name the fix, and where it lives.**
✅ `macOS is blocking access to Desktop. Allow NotchHub in System Settings ▸ Privacy & Security ▸ Files and Folders, then turn this back on.`
❌ `Permission denied (error 257)`

**Never blame the user, and never blame nobody.**
✅ `Your screenshots are saved as PDF. NotchHub copies image screenshots — change the format in the Screenshot app to copy them.`
❌ `Unsupported format.`

**Rule 5.1** — Every Settings `Section` **must** have a `footer:` that explains
what the switch actually does, including what it does *not* do.

**Rule 5.2** — Sentence case everywhere. Never Title Case, never ALL CAPS.

**Rule 5.3** — A limit the user will hit **must** be stated in the footer, not
discovered. "Up to 12 entries", "larger than 32 MB".

**Rule 5.4** — When macOS causes a delay, **say so and say whose it is**. The
screenshot footer names the floating preview rather than letting NotchHub look
slow.

---

## 6. Anti-patterns

| Don't | Do | Why |
| --- | --- | --- |
| `Color.white.opacity(0.12)` | `NotchTheme.subtleSurface` | Sixteen ad-hoc opacities exist; that is the bug |
| `cornerRadius: 8` | `NotchTheme.cardRadius` | The token is used once and ignored ten times |
| `.foregroundStyle(.secondary)` on the Overlay | `NotchTheme.secondaryText` | System semantics resolve against the wrong ground |
| `.font(.system(size: 17))` | A step from §2.3 | 26 combinations is not a scale |
| `.animation(.spring, value: x)` | Gate on `reduceMotion` first | Motion sickness is not a preference |
| Artwork straight onto black | Measure it; give it a ground | 1.12:1 is invisible, not moody |
| `NSAlert` for a failure | Inline `.red` text | Nothing in the notch is worth blocking the screen |
| A placeholder in the empty strip | Draw nothing | It is on screen permanently |
| A `body` over 40 lines | Extract a sub-view | Compiler timeouts, and CLAUDE.md forbids it |

---

## 7. QA checklist

Run in code review. Any unchecked box is a change request.

**Tokens**
- [ ] No new raw `.white.opacity()` — a token was used or added with a comment
- [ ] No new corner radius literal
- [ ] Every font size is a step from §2.3
- [ ] Spacing is on the 4pt rhythm, or the exception is named in a comment

**Surfaces**
- [ ] Overlay code uses no system semantic colour (A8)
- [ ] Window code uses no `NotchTheme`
- [ ] Nothing was added to the middle of the collapsed strip

**States**
- [ ] Content, empty, denied and error all render
- [ ] Empty and denied use different words (Rule 3.3.2)
- [ ] Every new control defines hover, focus-visible, pressed, disabled

**Accessibility**
- [ ] Text ≥ 4.5:1, meaningful graphics ≥ 3:1 — computed, not eyeballed
- [ ] State survives greyscale
- [ ] Reduce Motion holds everything still
- [ ] Targets ≥ 28×28pt inside `.contentShape`
- [ ] Decoration is `.accessibilityHidden(true)`

**Content**
- [ ] Sentence case
- [ ] Every new Section has an explanatory footer
- [ ] Errors name the fix and where it lives
- [ ] Limits are stated, not discovered

**Layout**
- [ ] Nothing overflows `contentHeight` 68pt
- [ ] Long strings truncate rather than wrap the row taller
- [ ] Every `body` is under 40 lines

---

## 8. Migration

Nothing here demands a sweep. The rules bind **new code**, and touched code
**should** be migrated as it is touched — the same bargain the Swift 6
concurrency migration runs on.

Worth doing first, in order of ratio between cost and payoff:

1. **Radius.** Four values → one token. Mechanical, ten call sites.
2. **Opacity.** Sixteen values → five tokens. The 0.6 body colour is used more
   often than the 0.68 token that was meant to be it; one of them should win.
3. **Type.** Twenty-six combinations → six steps. Largest job, biggest payoff.
4. **Spacing.** Eleven values → six, with the two named exceptions kept.

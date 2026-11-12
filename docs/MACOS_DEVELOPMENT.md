# macOS Development

This is the source of truth for developing and reviewing Ghostty's macOS
application. It records the project's platform baseline, build workflow,
Apple-framework conventions, compatibility risks, and required validation.

The short operational rules in [`macos/AGENTS.md`](../macos/AGENTS.md) apply to
all changes under `macos/`. General project setup remains in
[`HACKING.md`](../HACKING.md).

Last reviewed against Apple's published documentation: **July 14, 2026**.

## Platform Baseline

| Concern                         | Project baseline                                                       |
| ------------------------------- | ---------------------------------------------------------------------- |
| App deployment target           | macOS 14                                                               |
| Development toolchain           | Xcode 26 with the macOS 26 SDK and Metal Toolchain                     |
| Development host                | macOS 15.6 or newer, as required by Xcode 26                           |
| Main app language mode          | Swift 5                                                                |
| Dock tile plug-in language mode | Swift 6                                                                |
| Renderer                        | Zig core with the macOS Metal backend                                  |
| Distribution security           | Hardened runtime; library validation remains enabled in release builds |

The deployment target is the oldest supported runtime, not the required
development host. Keep macOS 14 compatibility unless the project explicitly
changes `MACOSX_DEPLOYMENT_TARGET`.

Xcode 27 is a compatibility target, not the required day-to-day toolchain. Its
beta only runs on Apple silicon, although its macOS SDK can still build
universal applications. Use it to find upcoming failures without introducing
unguarded beta-only APIs into production code.

Official references:

- [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [macOS release notes](https://developer.apple.com/documentation/macos-release-notes)

## Repository Map

| Path                             | Responsibility                                                               |
| -------------------------------- | ---------------------------------------------------------------------------- |
| `macos/Sources/App/`             | Application lifecycle, delegates, menus, and platform entry points           |
| `macos/Sources/Ghostty/`         | App model, terminal surface, renderer integration, and shared macOS behavior |
| `macos/Sources/Features/`        | User-facing AppKit and SwiftUI features                                      |
| `macos/Sources/Helpers/`         | Extensions, backports, and isolated platform helpers                         |
| `macos/Sources/Helpers/Private/` | Unsupported private APIs; compatibility risk, not a pattern to extend        |
| `pkg/macos/`                     | Zig-side macOS integration, including video timing and Metal support         |
| `macos/*.entitlements`           | Per-configuration security and protected-resource capabilities               |
| `macos/Ghostty.xcodeproj/`       | Deployment targets, language modes, signing, build phases, and tests         |

Clawddy's agent workspace is described separately in
[`CLAWDDY_ARCHITECTURE.md`](CLAWDDY_ARCHITECTURE.md).

## Build and Test Workflow

Select the intended Xcode installation before building:

```sh
sudo xcode-select --switch /Applications/Xcode.app
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
```

If a change touches code outside `macos/`, rebuild the underlying Ghostty
library first. The repository wrapper keeps the Zig prefix, both caches, and
downloaded packages on external storage:

```sh
./build.nu -Demit-macos-app=false
```

Build the app through the repository wrapper. It removes environment variables
that commonly leak from Nix shells and writes products, DerivedData, object
files, Swift packages, module and compilation caches, Zig caches, and temporary
files beneath `/Volumes/Xcode/GhosttyBuilds/ghostty/macos/`:

```sh
macos/build.nu --scheme Ghostty --configuration Release --action build
```

Package resolution uses Xcode's noninteractive `netrc` authorization provider.
This repository's package dependencies are public, and avoiding an unnecessary
Keychain query prevents unattended builds from blocking indefinitely.

Run the macOS unit tests with:

```sh
macos/build.nu --scheme Ghostty --configuration Release --action test
```

Production builds and unit tests use separate external build graphs. Unit tests
need an `@testable` app module and may inject XCTest support into their host;
their products, objects, DerivedData, module cache, and temporary directory live
under the wrapper's `tests/` subtree. The production Release graph remains
optimized with `ENABLE_TESTABILITY=NO` and never serves as a test host. The
wrapper also marks its dedicated `SYMROOT`, `OBJROOT`, and `DSTROOT` directories
as Xcode-owned so `--action clean` can remove stale generated products safely.

Both wrappers fail closed if the external volume is not mounted. Use
`GHOSTTY_BUILD_ROOT`, `GHOSTTY_MACOS_BUILD_ROOT`, or `--build-root` only for an
alternate path under `/Volumes`. Run either wrapper with `--show-paths` to audit
its resolved locations without starting a build.

Zig 0.17 is usually not the `zig` on `PATH`, so `./build.nu` selects its
compiler from `GHOSTTY_ZIG` and falls back to `zig` on `PATH`. The selected
executable is invoked by absolute path inside the sealed build environment, and
`--show-paths` reports it together with the version it actually prints:

```sh
GHOSTTY_ZIG=/Volumes/Xcode/GhosttyBuilds/ghostty/tools/zig-0.17.0/zig ./build.nu --show-paths
```

The upstream build writes the XCFramework directly to
`macos/GhosttyKit.xcframework` because the Xcode project links it there. The
wrapper keeps that path as a symlink to
`<build root>/xcframework/GhosttyKit.xcframework`, moves the real framework back
to external storage after every build, and fails rather than leaving real build
products in the worktree. Replaced copies are preserved under
`<build root>/xcframework/history/` and can be removed manually when reclaiming
disk space.

The wrapper skips UI tests because they require interactive permissions. Run
the `GhosttyUITests` target from the `Ghostty` scheme in Xcode when the change affects input,
accessibility, windows, App Intents, pasteboard behavior, or system prompts.

Format and lint Swift changes before review:

```sh
swiftlint lint --strict --fix
```

Do not use `zig build` as the final macOS app validation. The Xcode project is
authoritative for Swift compilation, resources, entitlements, signing, plug-ins,
and application tests.

## Framework and API Policy

### Prefer public, nondeprecated APIs

New code must use public Apple APIs. Before adopting an API, check its current
availability and deprecation annotations in the SDK used by the project.

Existing private calls are isolated in `macos/Sources/Helpers/Private/`, plus a
small number of KVC-based titlebar and window helpers. They exist because some
Ghostty behavior has no public equivalent. Do not add another private symbol or
internal AppKit class-name dependency without documenting:

1. The user-visible behavior that requires it.
2. Why public APIs cannot provide that behavior.
3. The failure-safe behavior when the symbol or view hierarchy changes.
4. A compatibility test for the next macOS release.

Use public `NSWindow.CollectionBehavior` options for Spaces and Stage Manager
behavior where they are sufficient.

Known replacements:

- The Core Video `CVDisplayLink` implementation in
  `pkg/macos/video/display_link.zig` is deprecated. Create a display link from
  the most specific AppKit object, normally `NSView`, and bridge it into the
  renderer. A view display link follows display changes and pauses when the
  view is not visible.
- `LSCopyDefaultApplicationURLForContentType` in
  `NSWorkspace+Extension.swift` is deprecated. Use
  `NSWorkspace.urlForApplication(toOpen:)`.

Official references:

- [NSView display links](https://developer.apple.com/documentation/appkit/nsview/displaylink%28target%3Aselector%3A%29)
- [Core Video display-link deprecations](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k)
- [NSWorkspace default application lookup](https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication%28toopen%3A%29-95cvp)
- [NSWindow collection behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)

### AppKit, SwiftUI, and input

Ghostty is an AppKit application that embeds SwiftUI where declarative views
improve isolated UI. A wholesale SwiftUI rewrite is not a goal.

- Keep AppKit ownership for windows, menus, focus, responder-chain behavior,
  terminal surfaces, and exact keyboard/mouse input.
- Use SwiftUI for self-contained presentation and controls when its lifecycle
  can be cleanly hosted by AppKit.
- Prefer system controls, control events, and gesture recognizers for ordinary
  UI. Raw `NSEvent` handling remains appropriate for terminal protocol input,
  where every modifier, button, and coordinate matters.
- Give windows and restorable controllers stable identifiers. Always call
  state-restoration completion handlers, including error paths.
- Preserve keyboard navigation and verify the key-view loop after adding or
  moving controls.

The Observation framework is available at the deployment target and is the
preferred model for new SwiftUI-facing state. New AppKit automatic observation
features may have newer availability; gate those features rather than raising
the app's deployment target accidentally.

Official references:

- [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/)
- [Use SwiftUI with AppKit](https://developer.apple.com/videos/play/wwdc2026/272/)
- [AppKit updates](https://developer.apple.com/documentation/Updates/AppKit)

### Swift concurrency

UI-owned state must stay on the main actor. File parsing and other expensive
work may run on a background queue or task, but it must operate on immutable
snapshots and return results to the main actor before mutating UI models.

Do not silence concurrency diagnostics with `@unchecked Sendable` until the
object's synchronization and lifetime are documented. C and Zig callbacks need
particular care because the compiler cannot infer their executor or ownership.

Migrate the main app to Swift 6 in stages:

1. Enable complete strict-concurrency diagnostics while remaining in Swift 5
   language mode.
2. Resolve callbacks, delegates, shared state, and retroactive conformances.
3. Move modules or targets independently to Swift 6.
4. Keep the application building in both release and test configurations
   throughout the migration.

[Apple's Swift 6 adoption guide](https://developer.apple.com/documentation/Swift/AdoptingSwift6)
explicitly supports incremental migration.

### Rendering and frame timing

The renderer remains Metal-based. Preserve Ghostty's existing storage-mode
split: Apple GPUs use shared resources; discrete and Intel GPUs use managed
resources with explicit synchronization where required.

Use the view's AppKit display link as the default frame-timing source. Consider
`CAMetalDisplayLink` only when the renderer needs its Metal-specific presentation
timing; adopting Metal 4 is not itself a requirement for a terminal renderer.

Validate rendering changes on:

- Apple silicon and Intel hardware while Intel remains supported.
- A built-in display and an external display with a different refresh rate.
- A variable-refresh-rate display when available.
- Hidden, minimized, occluded, and moved-between-displays windows.
- Standard and reduced-motion accessibility settings.

[Apple's managed-resource synchronization guide](https://developer.apple.com/documentation/metal/synchronizing-a-managed-resource-in-macos)
describes the discrete-GPU requirements.

## System Integration

### Pasteboard

Reading the general pasteboard is privacy-sensitive. A user pressing Command-V
or choosing Paste is different from a background read initiated by a terminal
program such as OSC 52.

- Do not read pasteboard contents merely to validate a menu or determine
  whether a supported type exists. Use pasteboard detection APIs.
- Inspect `NSPasteboard.accessBehavior` before programmatic general-pasteboard
  reads and handle allowed, denied, and prompting behavior.
- Keep custom selection pasteboards and drag-and-drop behavior distinct from
  the general pasteboard.
- Test OSC 52 independently from direct Paste commands.

Enable Apple's developer-preview behavior for the active bundle identifier:

```sh
defaults write com.mitchellh.ghostty.debug \
  EnablePasteboardPrivacyDeveloperPreview -bool yes
```

See [Apple's current AppKit pasteboard guidance](https://developer.apple.com/documentation/Updates/AppKit).

### Notifications

Request notification authorization in context, when the user enables agent or
terminal notifications or when the feature first needs to notify. Do not ask at
application launch.

- Treat denial as a normal state and keep in-app indicators functional.
- Use passive, active, or time-sensitive interruption levels according to the
  actual urgency.
- Do not use a critical notification sound without the Critical Alerts
  entitlement and a product requirement that satisfies Apple's policy.
- Group agent notifications by stable agent UUID and route notification taps
  to that agent when possible.

See [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications).

### Accessibility

The terminal surface is a custom text control. Its accessibility implementation
must expose a coherent role, value, selected range, bounds, and attributed text,
then post relevant accessibility notifications when terminal content or the
selection changes.

Every new custom control must provide an accessible label or description,
keyboard operation, visible focus behavior, and meaningful state/value. Respect
Reduce Motion and Reduce Transparency when applying animation or glass effects.

Run `XCUIApplication.performAccessibilityAudit` for major windows and perform a
manual VoiceOver pass for live terminal output, selection, the agent sidebar,
the command palette, and notifications.

Official references:

- [Accessibility for AppKit](https://developer.apple.com/documentation/AppKit/accessibility-for-appkit)
- [AppKit accessibility notifications](https://developer.apple.com/documentation/appkit/accessibility-functions)
- [Performing accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)

### App Intents

Declare the supported execution modes for every intent and availability-gate
newer behavior. An intent that opens or manipulates UI must not claim to be
background-only unless it can complete correctly without foregrounding Ghostty.

Add `AppIntentsTesting` integration coverage for creating, focusing, closing,
and sending input to terminals. Cover no-window, missing-target, and denied
permission paths. Manual Shortcuts and Siri testing is still required.

Official references:

- [App Intent supported modes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)
- [App Intents updates](https://developer.apple.com/documentation/Updates/AppIntents)
- [Testing App Intents](https://developer.apple.com/videos/play/wwdc2026/295/)

### Entitlements, privacy, and signing

Release builds use the hardened runtime and must keep library validation enabled
unless a documented plug-in architecture requires otherwise. Debug-only signing
exceptions must not leak into release entitlements.

Ghostty declares protected-resource capabilities because programs running in a
terminal may request those resources. For each capability:

- Keep the entitlement and usage description only while the behavior is
  supported and tested.
- Describe why a program running inside Ghostty is requesting access.
- Localize user-facing usage descriptions with `InfoPlist.strings`.
- Test whether macOS attributes the prompt and decision to Ghostty as expected.
- Review bundled dependencies when Apple's privacy-manifest requirements change.

Official references:

- [Configuring the hardened runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Managing `Info.plist`](https://developer.apple.com/documentation/BundleResources/managing-your-app-s-information-property-list)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

### Liquid Glass and future UI APIs

Prefer standard AppKit and SwiftUI controls, which receive platform appearance
updates automatically. Use custom glass only to express a clear visual hierarchy;
do not layer multiple glass backgrounds or make decorative surfaces interactive.
Availability-gate macOS 26 and macOS 27 APIs and verify contrast with increased
contrast and reduced transparency enabled.

- [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)

## Required Validation Matrix

Choose the rows affected by a change; release-signing changes require the full
matrix.

| Area                  | Required checks                                                                     |
| --------------------- | ----------------------------------------------------------------------------------- |
| Build                 | Debug and Release Xcode builds; no new SDK deprecation or module warnings           |
| Runtime compatibility | macOS 14 deployment lane and the current shipping macOS                             |
| Future compatibility  | Latest macOS/Xcode beta smoke test for AppKit internals and private APIs            |
| Architecture          | Apple silicon; Intel when the change affects renderer, process, or binary packaging |
| Input                 | Keyboard layouts, IME/dead keys, mouse reporting, secure input, focus changes       |
| Windows               | Tabs, splits, fullscreen, Quick Terminal, Spaces, Stage Manager, restoration        |
| Displays              | Mixed refresh rates, external display movement, occlusion, sleep/wake               |
| Clipboard             | Paste command, menu validation, drag/drop, selection pasteboard, OSC 52             |
| Accessibility         | Automated audit plus VoiceOver, keyboard navigation, reduced motion/transparency    |
| System prompts        | Notifications and each affected protected-resource permission, including denial     |
| Automation            | App Intents, AppleScript, Services, notification activation                         |
| Distribution          | Hardened runtime, entitlements, nested-code signing, notarization                   |

The unit-test target currently deploys to macOS 15.5 even though the app deploys
to macOS 14. CI must retain a macOS 14 application or UI-test lane until those
targets are aligned.

## Tracked Migration Work

This table describes known work; it does not claim the implementation is already
complete.

| Priority | Work                                                                                       | Primary code                                                   |
| -------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------- |
| High     | Replace deprecated Core Video display link with a view-created AppKit display link         | `pkg/macos/video/display_link.zig`, `SurfaceView_AppKit.swift` |
| High     | Adopt pasteboard detection/access behavior and test OSC 52 privacy                         | `NSPasteboard+Extension.swift`, `Ghostty.App.swift`            |
| High     | Replace deprecated Launch Services lookup                                                  | `NSWorkspace+Extension.swift`                                  |
| High     | Isolate or remove private CGS, Dock, KVC, and internal-view dependencies                   | `Helpers/Private/`, titlebar/window helpers                    |
| Medium   | Post terminal accessibility notifications and add automated audits                         | `SurfaceView_AppKit.swift`, UI tests                           |
| Medium   | Enable complete strict-concurrency diagnostics before migrating the main target to Swift 6 | Xcode project, Swift app sources                               |
| Medium   | Add `AppIntentsTesting` integration tests                                                  | App Intents, UI tests                                          |
| Medium   | Localize protected-resource usage descriptions and audit capability scope                  | Xcode project, `InfoPlist.strings`, entitlements               |
| Medium   | Resolve GhosttyKit umbrella-header and redundant-conformance warnings                      | module map and Swift extensions                                |

When a migration is completed, remove its row and add its behavior to the
relevant permanent rule or test above.

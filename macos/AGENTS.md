# macOS Ghostty Application

- Read [`docs/MACOS_DEVELOPMENT.md`](../docs/MACOS_DEVELOPMENT.md) before
  changing AppKit, SwiftUI, Metal, system integration, entitlements, or macOS
  build settings. It is the source of truth for platform policy and validation.
- Use `swiftlint` for formatting and linting Swift code.
- If code outside of `macos/` directory is modified, use
  `./build.nu -Demit-macos-app=false` before building the macOS app to update
  the underlying Ghostty library.
- Use `macos/build.nu` to build the macOS app, do not use `zig build`
  (except to build the underlying library as mentioned above).
  - Build: `macos/build.nu [--scheme Ghostty] [--configuration Release] [--action build]`
  - Output: `/Volumes/Xcode/GhosttyBuilds/ghostty/macos/products/<configuration>/Ghostty.app`
  - All products, intermediates, packages, caches, and temporary files are
    external. The wrapper must fail rather than fall back when the SSD is absent.
- Run unit tests directly with `macos/build.nu --action test`
- For Clawddy validation in this workspace, build and run `Release` only. Never
  launch the Debug, ReleaseLocal, preview, or development-mode app.
- Automation shells may set `NO_COLOR`. Remove that automation-only variable
  when launching Clawddy (for example, `env -u NO_COLOR open -na <app>`) so it
  is not inherited by interactive Claude or Codex terminals. Do not globally
  override a user's intentional `NO_COLOR` preference in application code.
- When replacing a running Clawddy build, match the built executable's absolute
  path and leave every other Ghostty or Clawddy process untouched.

## Platform Rules

- Preserve the macOS 14 deployment target unless a platform-support change is
  explicitly requested. Availability-gate newer APIs.
- Prefer public, nondeprecated APIs. Do not add private symbols, KVC access to
  private properties, or dependencies on internal AppKit class names without a
  documented public-API analysis and failure-safe behavior.
- Keep UI-owned mutable state on the main actor. Background work must return to
  the main actor before mutating AppKit, SwiftUI, or observable UI state.
- Treat the general pasteboard as privacy-sensitive. Do not read it for menu
  validation or type discovery, and test programmatic reads such as OSC 52 with
  Apple's pasteboard privacy developer preview enabled.
- Request notification and protected-resource permissions in context, never as
  an unconditional application-launch side effect.
- Custom controls and terminal state changes must maintain accessibility labels,
  keyboard behavior, and appropriate accessibility notifications.
- New or changed system integration must include the relevant manual test from
  the validation matrix in `docs/MACOS_DEVELOPMENT.md`.

## AppleScript

- The AppleScript scripting definition is in `macos/Ghostty.sdef`.
- Guard AppleScript entry points and object accessors with the
  `macos-applescript` configuration (use `NSApp.isAppleScriptEnabled`
  and `NSApp.validateScript(command:)` where applicable).
- In `macos/Ghostty.sdef`, keep top-level definitions in this order:
  1. Classes
  2. Records
  3. Enums
  4. Commands
- Test AppleScript support:
  (1) Build with `macos/build.nu`
  (2) Launch and activate the app via osascript using the absolute path
      to the built app bundle:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to activate'`
  (3) Wait a few seconds for the app to fully launch and open a terminal.
  (4) Run test scripts with `osascript`, always targeting the app by
      its absolute path (not by name) to avoid calling the wrong
      application.
  (5) When done, quit via:
      `osascript -e 'tell application "<absolute path to build/Debug/Ghostty.app>" to quit'`

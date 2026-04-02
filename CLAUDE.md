# Snug — CLAUDE.md

## What this is

Snug is a native macOS menu bar utility (macOS 14.0+, Swift 6.0) that hides and collapses third-party status bar icons. It exposes hidden items via a hover dropdown panel and supports auto-hide timers.

---

## Tech Stack

- **Language:** Swift 6.0, strict concurrency enabled
- **Platform:** macOS 14.0+ (Sonoma)
- **UI:** AppKit (system integration, window management) + SwiftUI (settings, onboarding)
- **Animations:** QuartzCore / CALayer
- **Reactive bindings:** Combine + `@Observable` macro
- **Build:** XcodeGen (`project.yml` → `.xcodeproj`)
- **Auto-update:** Sparkle 2.6.0+ via `docs/appcast.xml`
- **Dependencies managed via SPM** (declared in `project.yml`)

---

## Project Structure

```
Snug/
├── AppDelegate.swift              # NSApplicationDelegate, boots StatusBarController
├── SnugApp.swift                  # @main enum entry point
├── StatusBar/
│   ├── StatusBarController.swift  # Core controller: item hiding, separator sizing, wake recovery
│   ├── NotchDropdownCoordinator.swift  # Orchestrates dropdown panel show/hide (two-phase hover)
│   └── NotchDropdownPanel.swift   # NSPanel subclass with CALayer mask animations
├── MenuBar/
│   ├── MenuBarItemManager.swift   # CGWindowList discovery (layer == 25); refreshes every 5s
│   ├── MenuBarItem.swift          # Identifiable struct: windowID, frame, ownerPID, bundleID, title
│   └── AccessibilityMenuBarHelper.swift  # AX API: item lookup, press/activate, cmd+drag reorder
├── Preferences/
│   ├── AppPreferences.swift       # @Observable singleton (UserDefaults-backed)
│   ├── GeneralSettingsView.swift  # SwiftUI settings UI (login item, auto-hide, pocket toggle)
│   └── AboutSettingsView.swift    # SwiftUI about page (version, Sparkle update button)
├── Onboarding/
│   ├── OnboardingWindow.swift     # First-launch NSWindowController wrapper (480×360)
│   └── OnboardingView.swift       # 3-step SwiftUI flow; polls AX permission every 1s on step 3
├── Models/
│   └── AutoHideInterval.swift     # Enum: 5s/10s/30s/1min; raw value 2 reserved (removed 15s)
├── Utilities/
│   ├── SnugLog.swift              # File logger → /tmp/snug-debug.log (DEBUG only, GCD-serialised)
│   ├── UpdaterController.swift    # Sparkle SPUUpdater singleton (@Observable)
│   └── SettingsOpener.swift       # Opens Settings window (TabView: General + About, 420×480)
└── Extensions/
    ├── Bundle+Version.swift       # releaseVersionNumber / buildVersionNumber helpers
    └── NSImage+Scaled.swift       # scaled(to:) using modern drawing handler API
SnugTests/
└── StatusBarControllerWakeFromSleepTests.swift  # 6 async tests: wake/screen-change scenarios
```

---

## Build & Run

**Requirements:** Xcode 16+, macOS 14+

```bash
# Generate Xcode project (required after project.yml changes)
xcodegen generate

# Build from CLI
xcodebuild build -scheme Snug

# Run tests
xcodebuild test -scheme SnugTests

# Run debug log
tail -f /tmp/snug-debug.log
```

Open `Snug.xcodeproj` in Xcode and press `⌘R` for day-to-day development. Tests are in `SnugTests/`; run with `⌘U` in Xcode or the command above.

---

## Code Patterns

### Concurrency
All classes interacting with UI or AppKit are annotated `@MainActor`:
```swift
@MainActor final class StatusBarController { ... }
```
`SWIFT_STRICT_CONCURRENCY = complete` is enforced at build time — the compiler will reject data races.

### Singletons
Shared state uses `.shared` singletons:
- `AppPreferences.shared` — observable preferences
- `UpdaterController.shared` — Sparkle updater

### Preferences
`AppPreferences` is `@Observable` (Swift Observation framework). SwiftUI views bind to it directly. AppKit code uses the `onPreferencesChanged` callback.

### Error handling
- Guard + early return for optional unwrapping; silent failure is acceptable for CGWindowList misses
- `try?` (not `try!`) for fallible operations like file I/O in `SnugLog`
- No thrown errors propagated to callers in AppKit code

### Naming
- Types: `PascalCase`
- Functions/properties: `camelCase`
- Extensions: `Type+Feature.swift`
- UserDefaults keys: nested `enum Keys` inside the preferences type

### AppKit ↔ SwiftUI bridge
SwiftUI views (`GeneralSettingsView`, `OnboardingView`) are hosted via `NSHostingController` / `NSHostingView`. Preferences are shared through the `@Observable` singleton.

---

## Key Implementation Notes

- Menu bar items are discovered via `CGWindowListCopyWindowInfo` filtering for windows at `kCGWindowLayer == 25` (status window level).
- The "pocket" (hidden area) works by resizing the separator item to push items off-screen.
- `NotchDropdownCoordinator` manages a transparent tracking `NSWindow` that detects hover; it must be torn down before showing the panel to avoid z-order races (see issue #59).
- After the dropdown panel is dismissed, the tracking window must be re-ordered to front (see issue #60).
- Accessibility permission is optional — the app degrades gracefully without it (item names won't resolve, `pressItem()` / `moveItem()` won't work).
- Distribution: DMG via GitHub Releases; Sparkle polls `docs/appcast.xml`.

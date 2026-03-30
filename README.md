# Snug

A lightweight macOS utility to hide and organize your menu bar icons.

## Features

- **Hide menu bar icons** — Click to collapse third-party status items behind a separator
- **Auto-collapse** — Optionally hide items after a configurable delay (5s, 10s, 30s, 1min)
- **Right-click menu** — See names and icons of hidden items, click to activate them
- **Multi-monitor support** — Works across multiple displays, including ultrawide setups
- **First-launch onboarding** — Guided setup with Accessibility permission request
- **Auto-updates** — Sparkle-powered updates delivered via GitHub Releases

## Installation

Download the latest DMG from [GitHub Releases](https://github.com/Studio-Knowhere-Team/Snug/releases), open it, and drag Snug to your Applications folder.

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (optional, enables hidden item names in right-click menu)

## How to Use

1. Hold **Cmd** and drag menu bar icons to the left of the open circle separator
2. Click the Snug icon to toggle — the circle splits open or closes shut
3. When closed, the filled circle shows the count of hidden items
4. Right-click the icon to see a list of hidden items and access preferences

## Building from Source

```bash
git clone https://github.com/Studio-Knowhere-Team/Snug.git
cd Snug
xcodebuild -scheme Snug -configuration Release build
```

Requires Xcode 16.0+ and macOS 14.0 SDK.

## License

[MIT](LICENSE)

Copyright (c) 2025-2026 Mike Williams / Studio Knowhere Team

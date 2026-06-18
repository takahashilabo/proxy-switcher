# Proxy Switcher

A tiny native macOS **menu bar app** that switches your proxy settings
automatically based on the Wi-Fi network (SSID) you're connected to.

> Example: connect to your phone's **NetShare** hotspot → SOCKS proxy
> `192.168.49.1:8282` turns on automatically. Back on home Wi-Fi → proxy off.

This fills the gap in macOS, which has no built-in "per-SSID proxy" feature.

## Features

- 🌐 Lives in the menu bar (no Dock icon)
- 📡 Detects Wi-Fi changes instantly (CoreWLAN events + safety-net poll)
- 🧩 Per-SSID rules: **Off / HTTP / HTTPS / SOCKS / PAC (auto)**, with optional auth
- ⚙️ Applies settings via `networksetup` (asks for admin password when changing)
- 🚀 Optional **Launch at Login**
- 💾 Rules saved as JSON in `~/Library/Application Support/ProxySwitcher/profiles.json`

## Requirements

- macOS 14 (Sonoma) or later
- Swift toolchain (Xcode or Command Line Tools — `xcode-select --install`)

## Build & install

```bash
./build_app.sh
mv ProxySwitcher.app /Applications/
open /Applications/ProxySwitcher.app
```

For development you can also just run `swift build && swift run` (it'll show a
Dock icon and won't have the Info.plist permissions, but it's handy for testing).

## First run

1. A **Location** permission prompt appears — **Allow it.**
   macOS requires location access to read the Wi-Fi network name; the app only
   uses it for that and never stores or transmits your location.
2. Click the globe icon in the menu bar → **Settings…**
3. Add a rule (the toolbar has a **"Use current: <SSID>"** shortcut), pick the
   proxy type, and fill in host/port.
4. Done. When you join that network the proxy is applied automatically; on any
   network without a rule, the proxy is turned **off**.

## A note on the admin password

Changing system proxy settings requires administrator rights, so macOS asks for
your password each time the proxy actually changes (which is only when the SSID
changes — not on every poll).

If you'd rather not be prompted, allow `networksetup` to run without a password
by adding a sudoers rule (advanced, optional):

```bash
echo "$(whoami) ALL=(root) NOPASSWD: /usr/sbin/networksetup" | sudo tee /etc/sudoers.d/proxyswitcher
sudo chmod 440 /etc/sudoers.d/proxyswitcher
```

…and change `runAdmin` in `ProxyManager.swift` to call
`sudo -n /usr/sbin/networksetup …` instead of the AppleScript prompt.

## Project layout

```
Package.swift
build_app.sh                  # packages the .app bundle
Sources/ProxySwitcher/
  ProxySwitcherApp.swift      # @main, MenuBarExtra + Settings window
  AppModel.swift              # state, Wi-Fi → proxy logic, login item
  WiFiMonitor.swift           # CoreWLAN SSID change detection
  ProxyManager.swift          # networksetup command builder + admin exec
  ProfileStore.swift          # JSON persistence
  Models.swift                # ProxyProfile / ProxyType
  MenuView.swift              # menu bar dropdown
  SettingsView.swift          # rule editor window
sample_profiles.json          # example rules
```

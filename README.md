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
- ⚙️ Applies settings via `networksetup` — **no password prompts** (proxy changes don't need root for an admin user)
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

## No password prompts

Changing the proxy for a network *service* with `networksetup` does **not**
require root for an admin user, so the app applies settings silently — you'll
never be asked for a password when the network changes.

The only permission prompt is the one-time **Location** access on first run
(needed to read the Wi-Fi name).

## CLI tools (curl / git / npm …)

GUI apps read the macOS system proxy, but most command-line tools ignore it and
look at environment variables instead. So on a tethering/SOCKS network, browsers
work while `curl`, `git`, `npm`, etc. fail (they try to connect directly and
there's no direct route).

To keep them in sync, the app writes a sourceable snippet whenever the proxy
changes:

```
~/.config/proxy-switcher/env.sh
```

Source it from your shell (add once to `~/.zshrc`):

```sh
[ -f ~/.config/proxy-switcher/env.sh ] && source ~/.config/proxy-switcher/env.sh
```

Now every **new** terminal automatically gets the right proxy: on a SOCKS
network it exports `ALL_PROXY/HTTP_PROXY/HTTPS_PROXY=socks5h://host:port` (plus
lowercase variants and a sensible `NO_PROXY`); on a network with no rule it
unsets them. `socks5h` resolves DNS at the proxy, which is what you want for
tethering.

Notes:
- Already-open shells won't update until you open a new one (or re-source the
  file). For live updates you can add a `precmd` hook that re-sources it.
- `wget` doesn't support SOCKS; use `curl`. For `ssh`, add a `ProxyCommand`
  (e.g. `ProxyCommand nc -X 5 -x host:port %h %p`) to `~/.ssh/config`.
- PAC-type rules can't be expressed as env vars, so the file leaves them unset.

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
  ShellEnvWriter.swift        # writes ~/.config/proxy-switcher/env.sh for CLIs
  Models.swift                # ProxyProfile / ProxyType
  MenuView.swift              # menu bar dropdown
  SettingsView.swift          # rule editor window
sample_profiles.json          # example rules
```

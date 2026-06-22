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

Most command-line tools ignore the macOS system proxy, so on a SOCKS-only
tethering link they can't reach the network. Use **Full tunnel mode** (below) —
it routes every process, including terminals, through the proxy. (An earlier
approach that exported proxy env vars was removed; the tunnel supersedes it.)

### The `claude` CLI (special-cased)

Claude Code streams long responses, which can stall through the TUN tunnel, so
it gets its own lighter path: a shell wrapper that detects NetShare and points
`claude` straight at NetShare's HTTP proxy (Claude Code honours `HTTPS_PROXY`).
It needs no tunnel and falls back to running normally on other networks.

Install (once):

```sh
echo '[ -f ~/.config/proxy-switcher/claude-netshare.sh ] && source ~/.config/proxy-switcher/claude-netshare.sh' >> ~/.zshrc
```

(`claude-netshare.sh` lives in `~/.config/proxy-switcher/`.) Open a new terminal
and `claude` just works on NetShare or anywhere else.

## Full tunnel mode (for apps that ignore the proxy, e.g. LINE)

The macOS system SOCKS proxy is *opt-in*: only apps that consult the proxy
config (Safari, Chrome, Slack, Apple Music, …) use it. Apps that open raw
sockets — **LINE** is one — bypass it and fail on a SOCKS-only tethering link.

"Full tunnel" mode fixes this by creating a TUN virtual interface with
[`sing-box`](https://sing-box.sagernet.org/) that forces **all** traffic
(every app) through the proxy, including DNS.

### Setup (one time)

```bash
brew install sing-box          # if not already installed
sudo ./install_tunnel_helper.sh
```

This installs a tiny root helper (`/usr/local/bin/proxy-tunnel`) and a sudoers
rule so the app can start/stop the tunnel **without a password**.

### Use

In **Settings**, open a SOCKS/HTTP rule and turn on
**"Route ALL apps through proxy (TUN tunnel)"**. From then on:

- Join that SSID → proxy is set **and** the tunnel starts → LINE etc. work.
- Leave it (or quit the app) → the tunnel stops automatically and routing is
  restored.

The app writes the sing-box config to `~/.config/sing-box/proxy-switcher.json`
based on the rule's host/port.

### Safety watchdog

A full tunnel routes *everything* through the proxy, so if you leave the
tethering network and the SSID change isn't detected, the machine could be left
with no connectivity. To prevent this, the app probes the internet every ~10s
while the tunnel is up; after a couple of consecutive failures it automatically
stops the tunnel and clears the proxy, restoring the direct route. It re-engages
on its own once a working network is back.

Notes:
- TUN needs root, which is why the one-time helper/sudoers install exists.
- TCP works (messaging, login). UDP (e.g. LINE voice/video calls) only works if
  the upstream proxy supports SOCKS5 UDP — many tethering proxies don't.
- Uninstall: `sudo rm /usr/local/bin/proxy-tunnel /etc/sudoers.d/proxy-switcher-tunnel`

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
  SingBoxConfigWriter.swift   # generates the sing-box TUN config
  TunnelManager.swift         # start/stop tunnel via the root helper
  Models.swift                # ProxyProfile / ProxyType
install_tunnel_helper.sh      # one-time root helper + sudoers install
  MenuView.swift              # menu bar dropdown
  SettingsView.swift          # rule editor window
sample_profiles.json          # example rules
```

# nixremote

Declarative, address-cascading native app forwarding for Wayland — over Nix
— plus a declarative wayvnc + noVNC "whole session in a browser" leg (see
["Full session in a browser"](#full-session-in-a-browser-wayvnc--novnc)
below) and a self-hosted RustDesk remote-desktop server for the cases
neither fits (see ["Self-hosted RustDesk server"](#self-hosted-rustdesk-server)
below).

## Vision

Two machines, each running their own native Wayland session, on their own
GPU. Sometimes you want a window from the *other* one, right here, as an
ordinary native app — not a remote-desktop stream, not a second nested
compositor, just the one window you actually asked for. `waypipe` already
does this beautifully. What's missing is the declarative, portable,
network-topology-aware layer around it: which address to reach a peer at
(you're not always on the same LAN), and reproducing all of it from a single
Nix config instead of hand-written fish functions and `~/.ssh/config` edits.

**nixremote** is that layer. One module, `nixremote.forward.<peer>`:
package provisioning (straight from nixpkgs — no AUR, no pacman, no
dependency on any particular system-management layer), an ordered
address cascade (native OpenSSH `Match ... exec` blocks — try the fast LAN
address first, fall back to a VPN/overlay address when you're not home),
and a wrapper script around waypipe's own `ssh` mode.

It's deliberately **not** coupled to [nixarch](https://github.com/julian-corbet/nixarch-corbet-ch)
— nixarch's job is making sure a machine has a working Wayland compositor and
a compatible stack; nixremote's job starts *after* that's already true, and
only needs `nixpkgs` + `home-manager`. That split is what makes it an
optional extension usable on any Wayland-capable, home-manager-managed
system — a nixarch box, a plain NixOS box, whatever else runs declaratively
on Nix and can grow a Wayland session.

## Status

**Pre-alpha.** Five modules now (`forward`, `fishDispatch`, `sunshine`, `moonlight`, `console`), plus
the standalone `nixosModules.rustdesk`; `console` (wayvnc + noVNC) is the newest and, unlike the
others below, has real eval-time test coverage — `checks/default.nix` exercises its attrsOf wiring,
unit shape, the auth/tls coupling assertion, and the actual *rendered command text* of every
generated script (not just option values), including regression tests for two real defects a
text-blind check missed the first time (a `--` that silently swallowed every trailing CLI argument,
and `--vnc` being handed the wrong address — the BIND address instead of the one to actually DIAL).
Not yet exercised anywhere outside this repo's own checks: no host has enabled it yet.

`forward` — extracted from and replacing a
one-off manual setup (packages installed by hand, exactly one direction
wired, a single hardcoded LAN IP with no fallback). Honest gaps:

- No test suite yet.
- The address cascade's fallback behavior was proven live (forced
  unreachability on the real first address, confirmed it falls through to
  the next one) — not assumed correct because it typechecks.
- Verified live, through the real `<app>@<peer>` dispatch command (not a
  manual invocation): GPU-accelerated forwarding (`vkcube`, RX 6800
  selected remotely, window visually confirmed on screen; a real Firefox
  window too — `zwp_linux_dmabuf_v1` bound, formats negotiated against the
  RX 6800), hardware H.264 encoding (`video = "h264"`, confirmed via
  `--debug` output showing `H264 support: hwenc T` and a real Vulkan
  encode queue selected on the remote GPU), and orphan reaping
  (`nixremote-reap-<peer>` against real orphaned trees left behind by a
  killed local wrapper, both directions).
- **`video`'s CPU cost is not a rounding error — this is why it's the
  default.** Measured live on a real Firefox forward with an actual
  playing video (not a synthetic benchmark): the local `waypipe` process
  compressing raw frame updates with `lz4` (`video = "none"`) sat at
  **~90% of one CPU core** — comfortably the single largest consumer on
  the sending host. Switching to `video = "h264"` dropped that to **~6%**
  for the identical workload. `none` still exists for hosts without a
  working DMABUF/GPU path (see the `package` gotcha below).
- nixpkgs' own `waypipe` build links against Nix's own `vulkan-loader`,
  which has zero visibility into a non-NixOS host's actual GPU driver
  install (confirmed live on an Arch/CachyOS + system-manager/home-manager
  host: `vulkaninfo`/`vkcube` both worked perfectly via plain SSH, while
  `pkgs.waypipe` failed every DMABUF/GPU-touching connection with "Failed
  to create Vulkan instance: Unable to find a Vulkan driver," confirmed via
  `LD_DEBUG`/`VK_LOADER_DEBUG` to be a wrong-loader problem, not a missing
  file or permissions issue). This is why the module names no package of
  its own: `binary` resolves `waypipe` through `$PATH` and `package`
  defaults to installing nothing, so the host decides which build runs.
  See `home/forward.nix`'s header for the full diagnosis.
- **Audio** (`audio.*`, see below) verified live through the real dispatch
  path: a forwarded app's sound followed the caller's current default
  output device (a Bluetooth/USB headset), confirmed audible with a
  genuine libpulse client (`paplay`). Note for anyone testing this by
  hand: `pw-cat --playback` does **not** honor `PULSE_SINK` (it's a native
  PipeWire tool, not a libpulse/pulse-compat client) — it silently plays
  to whatever PipeWire's own default is regardless of the env var, which
  looks exactly like a forwarding failure; use `paplay` or another real
  libpulse client instead.

## Usage

```nix
{
  imports = [ inputs.nixremote.homeManagerModules.forward ];

  nixremote.forward.some-peer = {
    addresses = [
      { address = "192.168.1.10"; }                       # tried first
      { address = "100.64.0.10"; probeTimeoutMs = 500; }   # fallback
    ];
  };
}
```

This installs no waypipe of its own (see `package` below — the host
provides it), generates the `Match`/`Host` cascade for the alias `some-peer` into
its own file — `~/.ssh/conf.d/nixremote.conf` — and adds a
`waypipe@some-peer` script to your `$PATH`: `waypipe@some-peer firefox`
forwards a native window from `some-peer`, wherever it currently answers.

Deliberately **not** managed: `~/.ssh/config` itself. This module never
touches it, on purpose — home-manager's own ssh module takes over that file
wholesale, which is a bad default for an "optional extension" meant to drop
onto an already-configured machine with its own unrelated ssh config. The
one manual, one-time step this module can't do for you: add this as the
**first** line of `~/.ssh/config` on each machine —

```
Include ~/.ssh/conf.d/nixremote.conf
```

See [`home/forward.nix`](home/forward.nix) for the full option reference —
`user`, `scriptName`, `binary`/`package` (which waypipe runs, and who
provides it — see Status above for why the module refuses to choose),
`video` (hardware-encode motion content — `none`/`h264`/
`vp9`/`av1`, defaults to `h264`; see Status above for why the default
isn't `none`), `compress` (tune CPU compression for non-video traffic,
e.g. `"zstd=5"` — `null` leaves waypipe's own `lz4` default alone; see its
own option docs for `waypipe bench` numbers measured against a real LAN
link, not assumed), `extraOptions` (any other passthrough flag, e.g.
`"--no-gpu"`), `audio.*` (route a forwarded app's sound to wherever you
actually are — see its own section below), and
`serverAliveInterval`/`serverAliveCountMax`.

### `<app>@<peer>` dispatch

```nix
{
  imports = [
    inputs.nixremote.homeManagerModules.forward
    inputs.nixremote.homeManagerModules.fishDispatch
  ];

  nixremote.forward.some-peer.addresses = [ { address = "192.168.1.10"; } ];
  nixremote.fishDispatch.enable = true;
}
```

With this enabled, `firefox@some-peer` (any app name, not just ones declared
anywhere) works directly — matching the `tmux@<host>`/`zellij@<host>`
convention already in use across hosts, without pre-declaring every app you
might ever forward. Implemented as a `~/.config/fish/conf.d/*.fish` file, not
`programs.fish.functions` — see [`home/fish-dispatch.nix`](home/fish-dispatch.nix)'s
header for why (short version: a real machine's existing fish config, e.g.
`cachyos-fish-config`, would otherwise get silently replaced).

### Audio

waypipe forwards the Wayland protocol only — it has no concept of audio, so
a forwarded app's sound plays out of the *peer's* own default output, not
yours (confirmed live: a forwarded Firefox's audio came out of the remote
machine's speakers, not the caller's). If the peer happens to be running a
PipeWire device-mesh daemon of the kind that mirrors every real audio
device on every node as a sink described `Tunnel to tcp:<addr>:<port>/<device>`
(this module doesn't run or require one, it only looks for its sinks),
`audio.enable = true` (the default) has every wrapper resolve, fresh on
each launch, which of the *peer's* sinks mirrors *your* current default
output, and sets `PULSE_SINK` to it — so the forwarded app's audio follows
wherever you actually are, the same way any other app's already does. Pure
best-effort: no default sink, an unreachable peer, or no matching mirror
just falls through to today's behavior (the peer's own default), never
blocking the window forward itself.

```nix
nixremote.forward.some-peer.audio.localAddress = "192.168.1.14";
```

`audio.localAddress` — the address *this* machine is known by on the
peer's mesh (there's no generic way to guess it, so it's opt-in and
explicit) — is the only thing you need to set; `audio.tunnelPort` defaults
to 4713 (the standard PulseAudio/PipeWire native-protocol port). See
`home/forward.nix`'s `audio` option docs for the full reference.

### Origin marking

waypipe forwards the Wayland protocol verbatim — a forwarded window's `app_id` reaches the
receiving compositor completely unchanged, so nothing on that end can natively tell "this `foot`
window is local" from "this `foot` window was just forwarded from somewhere else." Two routes let
a receiving compositor config (anything that can match on `app_id`, or read a process's
environment) draw that distinction — what it actually DOES with the match is entirely up to that
config; this module only guarantees the tag is there:

- **The static `app_id` route (primary).** Every `waypipe@<peer>` wrapper knows a small table of
  apps it can tag with their own `--app-id`-style flag (`foot` today — see `home/forward.nix`'s
  `appIdFlagTemplates`, and its own header for why nothing else is claimed without being verified
  first). When the forwarded command matches one of those, the wrapper rewrites it so the app
  launches as `<app> --app-id=<app>@<peer>` — e.g. `waypipe@some-peer foot` actually launches
  `foot --app-id=foot@some-peer` on the remote end. A receiving compositor can then match
  `app_id="@some-peer$"` and apply whatever per-window treatment it likes. In the sway/scroll
  family specifically: per-window BORDER *colour* is genuinely not available (`client.*`-style
  colour directives, and every colour-capable call in scroll's own Lua API, are compositor-global,
  not per-window — checked directly against scroll's exported Lua function table, not assumed),
  but `for_window [...] title_format "..."` IS per-container and — once the session's `font`
  directive carries a `pango:` prefix — renders Pango markup, so a coloured host badge inline in
  the title text (e.g. `title_format "<span foreground='#1e3a8a'>▌ some-peer</span>   %title"`)
  is a real, per-window, and trivially *verifiable* (a window's own title text, unlike a border or
  shadow, is visible over IPC) way to carry this signal. `for_window [...] decoration
  shadow_color ...` is also genuinely per-container and can layer a second, non-clashing visual
  cue on top, but its rendering isn't independently verifiable the same way (no IPC introspection
  exposes decoration state), so it works best as a secondary reinforcement, not the only signal.
  No runtime state, no extra process either way — the tag is carried in the one Wayland request
  (`xdg_toplevel.set_app_id`) the app already makes at launch. Anything outside the table forwards
  completely unmarked, exactly as if this feature didn't exist.
- **`NIXREMOTE_ORIGIN` (general fallback).** Every wrapper unconditionally exports
  `NIXREMOTE_ORIGIN=<peer>` into its OWN local environment before `exec`ing into `waypipe` — not
  passed through to the remote side, since the process that matters for this route is the LOCAL
  one. This is what makes an origin discoverable for an app the table above doesn't cover: a
  compositor scripting API that can read a window's owning process's environment (e.g. a Lua
  script under a sway-family compositor, on that compositor's own `view_map` event, calling
  something like `view_get_env(view, "NIXREMOTE_ORIGIN")` — which resolves `/proc/<pid>/environ`
  of whichever process actually opened the Wayland connection, i.e. waypipe's own local process,
  the exact one this variable is set on — and then issuing the identical `title_format` command
  itself, e.g. `command(container, "title_format \"<span foreground='...'>...")`) can apply the
  identical per-window treatment without needing the app itself to support any `--app-id`-style
  flag at all. Writing that script is a compositor-config concern outside this module's own
  scope — this module's job stops at guaranteeing the variable is there to read.

### Cleaning up after a killed session

waypipe's own cleanup is only reliable when the forwarded app exits **on
its own** (window closed, command finishes) — killing the local
`waypipe@<peer>` process itself (or a network path vanishing) still orphans
the remote side, a known, unfixed upstream limitation (verified live).
Every wrapper tags its remote command with an environment marker, and
`nixremote-reap-<peer>` (generated per peer, installed alongside the
wrapper) finds and kills exactly the orphaned process trees left behind —
safe to run any time, on demand; it does nothing if there's nothing to
reap.

## Roadmap

Planned, explicitly not built yet, and not guaranteed to happen — recorded
honestly rather than left implicit:

- **A merged local/remote app library.** The end goal: invoke an app by
  name and it transparently runs wherever it actually lives — a local
  binary if present, else forwarded from whichever peer has it — without
  the caller needing to know or care which. This would mean scanning each
  peer's `.desktop` entries over SSH and materializing merged launcher
  entries wrapped in the right `waypipe@<peer>` invocation. Whether this
  is actually needed in practice is genuinely open.
- A NixOS-module mirror of the home-manager module, for parity with how
  nixarch exports both, if a system-layer piece of this ever turns out to
  be needed (nothing here currently requires root).
- Declarative known_hosts pinning (a `programs.ssh.knownHosts`-style option),
  if the standard first-connection host-key trust prompt (consolidated to
  once per peer alias via `HostKeyAlias`) turns out to be more friction than
  it's worth in practice.
- Integration tests exercising the address cascade against simulated
  network-partition scenarios, not just eval-time type checks.
- An opt-in "reap before launch" toggle (run `nixremote-reap-<peer>` inline
  before connecting, instead of only on demand) — not built now to avoid
  adding an extra SSH round-trip's latency to every single launch by
  default.

## Full session in a browser (wayvnc + noVNC)

`forward` pulls one window at a time; `sunshine` streams a session to a purpose-built Moonlight
client. Neither covers the third shape: reaching a *whole* Wayland session (or one output of it)
from an ordinary VNC client, or nothing more than a browser tab — the case that matters most for a
machine with no GPU to game-stream from, or a session you want reachable from a device that will
never have anything installed on it. `nixremote.console.<name>` is that leg: declarative wayvnc,
optionally fronted by a noVNC web UI + websocket proxy in one process.

```nix
{
  imports = [ inputs.nixremote.homeManagerModules.console ];

  nixremote.console.mysession = {
    enable = true;
    web = {
      enable = true;
      package = pkgs.novnc; # required when web.enable is true -- nothing installs it implicitly
    };
  };
}
```

This renders a `systemd --user` unit (`nixremote-console-<name>`, `PartOf`/`After`
`graphical-session.target`, matching `sunshine`'s own ordering) running wayvnc against the session's
Wayland socket, plus — with `web.enable` — a second unit running noVNC's `novnc_proxy` (installed by
nixpkgs as `bin/novnc`) in front of it, giving a plain `http://<host>:6080/vnc.html` URL with nothing
to install on the viewing end.

**Capability boundary: wlroots-only.** wayvnc captures frames through `zwlr_screencopy_manager_v1`,
a wlr-* protocol extension every compositor this family targets (niri, sway, scroll) implements —
GNOME/Mutter or KDE/KWin sessions expose no equivalent surface at all, and there is no portable
substitute. This is a hard capability boundary of wayvnc itself, not a config knob.

**Security posture, by default.** `address` (wayvnc's own raw RFB bind) defaults to loopback-only —
plain RFB has a long history of weak-or-absent auth, so this module never defaults to a public
bind. Widen it only alongside `auth.enable = true` (wayvnc's own username/password RFB auth) and
ideally `tls.enable = true` (VeNCrypt, negotiated inside the RFB stream) together — wayvnc's own
`enable_auth` key requires `certificate_file`/`private_key_file`/`password` all set together, and
this module asserts `auth.enable == tls.enable` at eval time for exactly that reason (one without
the other is a config wayvnc would silently half-apply, not a degraded-but-valid one).
`web.enable`'s noVNC leg is unaffected by any of this and binds all interfaces by nixpkgs' own
default the moment it's turned on — front it with your own reverse proxy/firewall before exposing
it past a trusted network, the same caution `address`'s own option doc gives for the raw RFB port.
`auth.usernameFile`/`auth.passwordFile`/`tls.certFile`/`tls.keyFile` are all read fresh from disk at
every service start (never at Nix eval time, never copied into the world-readable store) — pass
them as plain strings, never a bare Nix `path` literal (see `home/console.nix`'s own header for why
a `path` value would leak the referenced file into the store the moment it were used).

**One precondition this module cannot set for you.** A wlroots compositor auto-detects its renderer
and will reach for a real DRM render node if one exists — on an estate where the only render node
belongs to a GPU other sessions must not touch, that's a problem `WLR_RENDERER=pixman` (software
rendering) fixes, but it has to be set on the *compositor's own* systemd unit, not on anything this
module renders: wayvnc is a screencopy *client*, it links no wlroots rendering code and never reads
`WLR_RENDERER` itself. A session with no render node at all (nothing to auto-detect toward) needs no
such override — `wlr_renderer_autocreate` has nothing to reach for.

See [`home/console.nix`](home/console.nix)'s own header for the full option reference — `output`
(capture one output or, the default, all of them via wayvnc 0.10.1's `-a`/`--desktop`),
`address`/`port`, `package`/`binary` (same host-decides split as `forward`'s own), `auth.*`/`tls.*`,
`web.*` (port, package, `connectAddress` — the address websockify *dials*, deliberately distinct
from the address wayvnc *binds*), and `extraArgs`.

## Self-hosted RustDesk server

A different shape from everything above: `nixosModules.rustdesk` runs a
self-hosted RustDesk rendezvous+relay server (hbbs + hbbr, one podman
container). It is a host-level, root-owned, always-on service, not a
per-user session component — see the module's own header for the full
design (image baked into the closure, no registry contact at runtime,
persistent hbbs keypair/database).

```nix
{
  imports = [ inputs.nixremote.nixosModules.rustdesk ];

  nixremote.rustdesk = {
    enable = true;
    relayHost = "rustdesk.example.com"; # required -- no default, see the option's own description
  };
}
```

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point; exports `homeManagerModules.{forward,fishDispatch,sunshine,moonlight,console}` and `nixosModules.rustdesk`. |
| `home/forward.nix` | The core module — package provisioning, address cascade, wrapper scripts, keepalive, orphan reaping. See its header comment for the full design rationale and gotchas. |
| `home/fish-dispatch.nix` | Optional `<app>@<peer>` fish integration, layered on top of `forward`. |
| `home/sunshine.nix` | The inverse direction — declarative Sunshine (LizardByte) desktop/game streaming host, serving THIS machine's Wayland session to a remote Moonlight client. |
| `home/moonlight.nix` | The VIEWER half of the streaming pair `sunshine` serves — a transport client (bitrate/codec/latency settings), not a player. Deliberately does not manage Moonlight's own pairing state, which is runtime, not config — see the module's own header. |
| `home/console.nix` | The "full session in a browser" leg — declarative wayvnc + noVNC. See ["Full session in a browser"](#full-session-in-a-browser-wayvnc--novnc) above and the module's own header (wlroots-only capability boundary, secrets-as-files handling, the `WLR_RENDERER=pixman` precondition it cannot set for you). |
| `modules/rustdesk.nix` | Self-hosted RustDesk server (hbbs+hbbr), a single podman container. NixOS-only — see "Self-hosted RustDesk server" above. |
| `checks/default.nix` | Eval-time tests for `nixosModules.rustdesk` (no VM, no container start — module evaluation only). |
| `experiments/` | Throwaway trials — see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written-up findings — see [`studies/README.md`](studies/README.md). |

## Related projects

nixremote is one of several small, independently-usable open-source projects
sharing a common design system: [nixarch](https://github.com/julian-corbet/nixarch-corbet-ch)
(declarative Arch/CachyOS via system-manager + home-manager), nixvps (tiny
sub-1GB NixOS VPS profiles), nixram (RAM/memory tuning), nixnas (a NixOS
distro build). nixremote's own niche is the cross-machine app-forwarding
layer — usable alongside any of them, or standalone.

## License

[MIT License](LICENSE) © 2026 Julian Corbet

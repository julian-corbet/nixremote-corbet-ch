# nixremote

Declarative, address-cascading native app forwarding for Wayland — over Nix.

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

**Pre-alpha.** One real module (`forward`), extracted from and replacing a
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
  RX 6800, a `get_surface_feedback` call tied to the actual browser
  surface), hardware H.264 encoding (`video = "h264"`, confirmed via
  `--debug` output showing `H264 support: hwenc T` and a real Vulkan
  encode queue selected on the remote GPU), and orphan reaping
  (`nixremote-reap-<peer>` against real orphaned trees left behind by a
  killed local wrapper, both directions).
- **`video`'s CPU cost is not a rounding error — this is why it's the
  default.** Measured live on a real Firefox forward with an actual
  playing video (not a synthetic benchmark): the local `waypipe` process
  compressing raw frame updates with `lz4` (`video = "none"`) sat at
  **~90% of one CPU core** — comfortably the single largest consumer on
  the sending host, well above Firefox's own processes combined. Switching
  to `video = "h264"` dropped that to **~6%** for the identical workload.
  On a host that's also running other work (verified live: this box's load
  average was ~24 on 32 threads from unrelated processes), that ~90%
  chunk landing on top of an already-busy scheduler is a real, reproduced
  cause of audible stutter in a *separate* PipeWire audio tunnel running
  alongside it — not a hypothetical. `none` still exists for hosts without
  a working DMABUF/GPU path (see the `waypipeBinary` gotcha below).
- **A significant course correction, worth recording plainly.** This
  module's first design invoked `tssh <peer> -o EnableWaypipe=yes <app>`,
  following `tssh` (trzsz-ssh)'s own documented `EnableWaypipe` feature for
  automating waypipe's lifecycle. That feature does not exist in the tssh
  version this was actually built and tested against (0.1.25) — confirmed
  via `tssh --help`/`man tssh` (neither mentions waypipe/Wayland/GPU
  anywhere) and a `tssh --debug` trace of a live session (zero
  waypipe-related activity, only ordinary SSH setup). Every
  `-o EnableWaypipe=yes` was silently accepted and did nothing: the
  "forwarded" app was actually just running on the remote machine's own
  local Wayland session the whole time, invisible locally — exactly why
  process exit codes and clean logs were never sufficient evidence that
  this module worked; only a live screenshot, or the person actually
  looking at their own screen, ever caught it. Rebuilt around waypipe's own
  `ssh` mode (`waypipe ssh <dest> <command>`), which genuinely implements
  the protocol itself and needs no tssh involvement. `tssh` is no longer a
  dependency of this module at all.
- One real compatibility quirk found via live testing along the way,
  fixed, and worth knowing about even though it's no longer tssh-specific:
  nixpkgs' own `waypipe` build links against Nix's own `vulkan-loader`,
  which has zero visibility into a non-NixOS host's actual GPU driver
  install (confirmed live on an Arch/CachyOS + system-manager/home-manager
  host: `vulkaninfo`/`vkcube` both worked perfectly via plain SSH, while
  `pkgs.waypipe` failed every DMABUF/GPU-touching connection with "Failed
  to create Vulkan instance: Unable to find a Vulkan driver," confirmed via
  `LD_DEBUG`/`VK_LOADER_DEBUG` to be a wrong-loader problem, not a missing
  file or permissions issue). `waypipeBinary`/`installWaypipe` exist
  specifically to point at a system-provided binary instead on such a host.
  See `home/forward.nix`'s header for the full diagnosis.
- Two more bugs caught only by actually watching the app render, not by
  clean exit codes — both fixed, both worth recording:
  - The wrapper's first cut passed the whole remote command as one
    pre-joined, `exec`-prefixed quoted string. waypipe's `ssh` mode does
    NOT hand that off to a remote shell for parsing the way plain
    `ssh host "cmd"` does — it builds the remote invocation from the
    trailing words as a literal argv vector itself, so the literal word
    `exec` (a shell builtin, not a real binary) became something it tried
    to execute directly, failing every single forward with `Failed to run
    program "exec"`. Fixed by passing the tag and command as separate,
    unquoted words instead.
  - Orphan detection (`nixremote-reap-<peer>`) initially checked the
    orphaned root's `/proc/<pid>/environ` for the `NIXREMOTE_PEER` tag —
    reasoning carried over from testing against a since-abandoned
    invocation shape. Under waypipe's own `ssh` mode, the env var is only
    ever set two forks below the process that actually gets re-parented to
    PID 1 (the remote login shell), so `environ`-based detection silently
    found nothing to reap. Verified live against real orphaned trees, then
    fixed: the tag reliably survives as a plain substring of the orphaned
    root's own **command line** instead (ssh always joins a multi-word
    remote command into one string handed to `<shell> -c`), so detection
    now greps `/proc/<pid>/cmdline`.
- **Audio** (`audio.*`, see below) verified live through the real dispatch
  path: a forwarded app's sound followed the caller's current default
  output device (a Bluetooth/USB headset), confirmed audible, twice, with
  a genuine libpulse client (`paplay`). One test-tooling trap along the
  way, worth recording so nobody re-walks it: `pw-cat --playback` does
  **not** honor `PULSE_SINK` (it's a native PipeWire tool, not a
  libpulse/pulse-compat client) — it silently plays to whatever
  PipeWire's own default is regardless of the env var, which looked
  exactly like a forwarding failure until swapping in `paplay` (which does
  honor it, same as Firefox and most other real apps) proved the actual
  mechanism was fine all along.

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

This installs `waypipe` (from nixpkgs, unless `installWaypipe = false` — see
below), generates the `Match`/`Host` cascade for the alias `some-peer` into
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
`user`, `scriptName`, `waypipeBinary`/`installWaypipe` (point at a
system-provided waypipe instead of nixpkgs' — see Status above for why
that matters), `video` (hardware-encode motion content — `none`/`h264`/
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
convention already in use on this fleet, without pre-declaring every app you
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
  if the standard first-connection host-key trust prompt (now correctly
  consolidated to once per peer alias via `HostKeyAlias`, since this module
  no longer routes through tssh's non-conforming known_hosts lookup) turns
  out to be more friction than it's worth in practice.
- Integration tests exercising the address cascade against simulated
  network-partition scenarios, not just eval-time type checks.
- An opt-in "reap before launch" toggle (run `nixremote-reap-<peer>` inline
  before connecting, instead of only on demand) — not built now to avoid
  adding an extra SSH round-trip's latency to every single launch by
  default.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point; exports `homeManagerModules.{forward,fishDispatch}`. |
| `home/forward.nix` | The core module — package provisioning, address cascade, wrapper scripts, keepalive, orphan reaping. See its header comment for the full design rationale and gotchas. |
| `home/fish-dispatch.nix` | Optional `<app>@<peer>` fish integration, layered on top of `forward`. |
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

# nixremote

Declarative, address-cascading native app forwarding for Wayland — over Nix.

## Vision

Two machines, each running their own native Wayland session, on their own
GPU. Sometimes you want a window from the *other* one, right here, as an
ordinary native app — not a remote-desktop stream, not a second nested
compositor, just the one window you actually asked for. `waypipe` already
does this beautifully; `tssh` (trzsz-ssh) already wraps its lifecycle for
normal interactive use. What's missing is the declarative, portable,
network-topology-aware layer around them: which address to reach a peer at
(you're not always on the same LAN), and reproducing all of it from a single
Nix config instead of hand-written fish functions and `~/.ssh/config` edits.

**nixremote** is that layer. One module, `nixremote.forward.<peer>`:
package provisioning (straight from nixpkgs — no AUR, no pacman, no
dependency on any particular system-management layer), an ordered
address cascade (native OpenSSH `Match ... exec` blocks — try the fast LAN
address first, fall back to a VPN/overlay address when you're not home),
and a wrapper script that carries the tssh/waypipe-specific flags that must
never be written into a shared `~/.ssh/config`.

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
- UDP roaming (`udpRoaming`) is implemented but off by default and lightly
  exercised so far — it solves a different problem (a session surviving the
  *client's* own network path changing mid-session) than the address cascade
  does (picking the *initial* path to a peer), and shouldn't be conflated
  with it.
- Two real, tssh-specific compatibility quirks were found via live testing
  and are now handled, but are worth knowing about: (1) a VPN client's own
  system-wide SSH hook (NetBird, and Tailscale has the same feature) can get
  its `ProxyCommand` applied by `tssh` even when it shouldn't — worked around
  by every wrapper script unconditionally passing `-o ProxyCommand=none`;
  (2) `tssh` does not honor `HostKeyAlias` for its own known_hosts lookup
  (plain `ssh` against the identical config is unaffected) — the first
  connection to a new peer needs its host key trusted once per literal
  address, not once per peer alias. See `home/forward.nix`'s header comments
  for the full detail on both.

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

This installs `waypipe` + `trzsz-ssh` (both from nixpkgs), generates the
`Match`/`Host` cascade for the alias `some-peer` into its own file —
`~/.ssh/conf.d/nixremote.conf` — and adds a `waypipe@some-peer` script to
your `$PATH`: `waypipe@some-peer firefox` forwards a native window from
`some-peer`, wherever it currently answers.

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
`user`, `scriptName`, `waypipeClientOptions`/`waypipeServerOptions`
(passthrough tuning, e.g. `--video=h264`), `udpRoaming`, and
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

### Cleaning up after a killed session

tssh's cleanup is only reliable when the forwarded app exits **on its own**
(window closed, command finishes) — killing the local `waypipe@<peer>`
process itself (or a network path vanishing) still orphans the remote side,
a known, unfixed upstream limitation (verified live, both before and after
this module's changes). Every wrapper tags its remote command with an
environment marker, and `nixremote-reap-<peer>` (generated per peer,
installed alongside the wrapper) finds and kills exactly the orphaned
process trees left behind — safe to run any time, on demand; it does nothing
if there's nothing to reap.

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
- Declarative known_hosts pinning (a `programs.ssh.knownHosts`-style option
  per address), if the current one-time-per-address manual trust bootstrap
  (see Status — tssh doesn't honor HostKeyAlias for this) turns out to be
  more friction than it's worth in practice.
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

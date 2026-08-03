# home/forward.nix — nixremote's core module: declarative, address-cascading
# native Wayland app-window forwarding between two Nix-managed peers, via
# waypipe's own `ssh` mode.
#
# THE SPLIT this module encodes:
#   - Each peer you declare gets an ORDERED list of candidate addresses (a
#     fast LAN IP first, a VPN/overlay IP as fallback, etc). This module
#     renders that ordering into native OpenSSH `Match ... exec` / `Host`
#     blocks, so a plain `ssh <peer>` (and, more to the point, the generated
#     `waypipe@<peer>` wrapper) transparently resolves to whichever address
#     answers first. Nothing here needs to know or care which path won.
#   - This module NAMES NO PACKAGE. It declares which binary it needs
#     (`binary`, a bare `waypipe` resolved through $PATH by default) and
#     leaves the choice of who provides it to the host: pacman on an Arch
#     box, `package = pkgs.waypipe` on NixOS, anything else you like. That
#     is what makes it usable standalone on any Wayland + home-manager
#     system without depending on nixarch or any other system-management
#     layer — and it is not merely a portability nicety: see `package`'s
#     description for the Vulkan-loader failure that makes a module
#     choosing this package for you actively harmful on a non-NixOS host.
#   - One wrapper script per peer (a real executable on $PATH, not a
#     fish-specific function) is what actually invokes
#     `waypipe ... ssh <peer> <app>`.
#   - `ServerAliveInterval`/`ServerAliveCountMax` bound how long a forwarded
#     session hangs LOCALLY if the network genuinely disappears (not an
#     explicit close). This is a keepalive for the CLIENT's own hang, not a
#     cleanup mechanism for the remote side — see the next point.
#   - Every wrapper script tags its remote command with
#     `env NIXREMOTE_PEER=<sshAlias>`, and a generated `nixremote-reap-<name>`
#     command per peer finds and kills remote process trees still carrying
#     that tag after being orphaned (re-parented to PID 1). This exists
#     because waypipe's own cleanup is only reliable when the forwarded app
#     exits on its own — killing the local wrapper externally (or a network
#     path vanishing) leaves the remote side running, a known upstream
#     limitation this module does not try to paper over, only clean up after
#     the fact, on demand.
#
# ── GOTCHA: the remote command must be UNQUOTED separate argv words, ──────
# ── never one pre-joined shell string, and never prefixed with `exec` ─────
# waypipe's `ssh` mode takes the trailing words as a literal argv vector it
# constructs the remote invocation from itself; it does not hand a single
# joined string to a remote shell for parsing the way plain `ssh host "cmd
# args"` does. Joining the command into one quoted argument makes `exec` (a
# shell builtin, not a real binary) the literal first word waypipe tries to
# execute directly, which fails outright. Pass `env NIXREMOTE_PEER=<alias>
# "$@"` as separate, unquoted shell words (so bash expands them into
# separate argv items before waypipe ever sees them) and drop `exec`
# entirely — `env`(1) already replaces its own process image via `execve`
# once it sets up the environment, so the tag lands on the correct final PID
# with no shell-level `exec` trick needed.
#
# ── GOTCHA: no unrecognized ssh keywords may land in this module's ────────
# ── generated file, or in any other file OpenSSH reads alongside it ───────
# OpenSSH's config parser aborts ALL parsing — for every Host block, not
# just the one it doesn't recognize — the moment it meets a single
# unrecognized keyword anywhere in the file. This module's own generated
# file contains only standard `Host`/`Match`/`HostName`/etc. directives —
# keep it that way if you extend it.
#
# ── GOTCHA: HostKeyAlias must be pinned per peer, not left to default ──────
# A peer's resolved Hostname can change between activations of this very
# cascade (LAN today, overlay tomorrow), so `HostKeyAlias <peer>` is set
# unconditionally on every generated block for that peer — known_hosts stays
# keyed on the stable peer name, never on whichever address happened to
# answer.
#
# This module supplies NONE of the address values, package lists beyond
# waypipe itself, or peer names — all of that is `nixremote.forward.<name>.*`,
# entirely the caller's. An empty attrset is a complete no-op.
#
# ── DESIGN CHOICE: a dedicated file, not `programs.ssh.enable` ─────────────
# home-manager's own ssh module (`programs.ssh.settings`/`matchBlocks`) takes
# over `~/.ssh/config` WHOLESALE — every Host block on the machine has to be
# re-expressed in Nix or it's silently gone the moment this module is
# enabled. That's a bad default for a tool meant to be an optional extension
# dropped onto an already-configured machine: real machines accumulate real,
# unrelated ssh config (other hosts, IdentityFiles, ProxyCommands) this
# module has no business touching. So instead this module owns exactly one
# new file, `~/.ssh/conf.d/nixremote.conf`, containing only its own
# generated blocks, and never reads or rewrites the rest of `~/.ssh/config`.
#
# The one thing this module CANNOT do declaratively is make plain `ssh`
# actually read that file — OpenSSH only picks up an extra config file via
# an `Include` directive written inside `~/.ssh/config` itself, which this
# module deliberately does not own. Add this line once, by hand, as the
# FIRST line of `~/.ssh/config` on each machine that uses this module:
#
#     Include ~/.ssh/conf.d/nixremote.conf
#
# ── AUDIO: routed through nixaudio's catalogue when composed, string-matched when not ─────
# A forwarded window's audio is resolved by `peer.audio.*` (documented on that option itself),
# via `probeFact` against `nixaudio.fabric.catalogue`/`nixaudio.resolvedDevices` (nixhost's
# `lib/facts.nix`, closed over as a plain function argument below -- see flake.nix's `nixhost`
# input comment, the same shape `home/sunshine.nix` already uses this input for). What the
# catalogue CAN and CANNOT replace here is worth stating precisely, because it is easy to
# over-claim: the mirrored tunnel sink's own NAME and DESCRIPTION are daemon-internal (a
# deterministic hash, and PipeWire's own unmodified "Tunnel to tcp:<addr>:<port>/<raw sink
# name>" text -- verified against nixaudio's real `daemon/fabric-sync` source, not assumed), so
# the actual cross-host match still has no source but a live `pactl`/`ssh` round-trip, and
# `peer.audio.localAddress`/`tunnelPort` remain this module's own options, hand-set per peer --
# nixaudio's own README says as much: the day peer addressing migrates from raw IPs to nixnet
# names, `localAddress` needs a manual update (nixnet's migration, not something derivable from
# a catalogue that carries no address at all).
#
# What the catalogue DOES replace: a blind match attempt against WHATEVER `pactl
# get-default-sink` currently happens to return. When nixaudio is composed, the caller's
# current default sink is first identified against nixaudio's own declared inventory --
# matching its renamed `device.description` (the naming rule `nixaudio/modules/devices.nix`
# already applies to every declared device, unconditionally, "so it shows up that way
# everywhere") -- before the SSH lookup below is even attempted. A sink nixaudio doesn't
# recognise (almost always because it is ITSELF already a fabric mirror -- a virtual tunnel
# node the naming rule never touches, since it only matches real ALSA vendor/product ids) skips
# resolution entirely instead of constructing a match that cannot succeed. When nixaudio is not
# composed at all, this degrades to exactly the original string-matching behaviour,
# unconditionally -- so this module never REQUIRES nixaudio to stay useful standalone.
{ probeFact }:
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.forward;

  # ── nixaudio catalogue: two defensive reads, ONE presence test ─────────────────────────────
  # Both probes share `namespace = "nixaudio"` -- probeFact's own presence test is only the
  # namespace's FIRST segment (see nixhost's `lib/facts.nix` header), so both ask exactly the
  # same question ("is nixaudio composed here at all") and therefore report `state == "absent"`
  # identically; only their individual `state`/`value` for the deeper leaf can differ (e.g. one
  # leaf renamed, the other not). Never a flake input on nixaudio -- see this module's header
  # and flake.nix's `nixhost` input comment for why the boundary is drawn there instead.
  audioCatalogueProbe = probeFact {
    inherit config;
    namespace = "nixaudio";
    path = [ "fabric" "catalogue" ];
    fallback = { };
  };
  audioDevicesProbe = probeFact {
    inherit config;
    namespace = "nixaudio";
    path = [ "resolvedDevices" ];
    fallback = [ ];
  };

  # `state != "absent"` -- composed, whether or not the specific leaf resolved cleanly (an
  # "unresolved" leaf still counts: nixaudio IS here, just under a renamed/rejected path, and
  # that host still gets the gated code path below with an empty device table, plus probeFact's
  # own warning (see `config.warnings`) -- rather than silently reverting to the plain fallback,
  # which would hide a real rename the same way a bare `or` would).
  nixaudioComposed = audioCatalogueProbe.state != "absent";

  # This host's OWN devices, exactly `nixaudio.fabric.catalogue`'s `origin == "local"` slice --
  # never the peer-projected `<peer>.<device>` entries, which describe what a PEER offers, not
  # what WE currently output (see this module's header for why that direction is the wrong one
  # for this lookup).
  localAudioCatalogue = lib.filterAttrs (_: e: e.origin == "local") audioCatalogueProbe.value;

  # `.source` ("usb" | "explicit") lives on `resolvedDevices`, not on the catalogue schema (see
  # nixaudio's `catalogue.nix`: it deliberately carries `known`, not `source`) -- looked up by
  # name for the diagnostic note in the resolve script below, never to GATE resolution: the live
  # fabric daemon mirrors every real sink regardless of this classification (verified against
  # its source -- see this module's header), so refusing to resolve an "explicit" device would
  # be a real regression, not a safety improvement.
  audioSourceByName = lib.listToAttrs
    (map (d: lib.nameValuePair d.name (d.source or "explicit")) audioDevicesProbe.value);

  # One `case` arm per locally-declared nixaudio device, matched against the LIVE
  # `Description:` a local `pactl list sinks` reports for the caller's current default sink --
  # not the raw sink NAME (`pactl get-default-sink`'s own output stays the match target for the
  # peer-side lookup, unchanged -- see the header), but the DESCRIPTION, because that is the
  # one field nixaudio's naming rule (`devices.nix`'s `mkRule`) actually renames on every
  # declared device, unconditionally, the moment it matches. Built once (this describes only
  # the CALLER, not any particular peer), consumed by every peer's wrapper below.
  audioDeviceCaseBody = lib.concatStrings (lib.mapAttrsToList
    (deviceName: entry:
      let
        # catalogue.nix's own schema keeps `description` nullable for a PEER entry (its text is
        # the peer's to know, not ours) but a LOCAL entry always carries the real one --
        # devices.nix defaults it to the device's own name (`config.description = lib.mkDefault
        # name;`), so this mirrors that same fallback rather than trusting a null blindly.
        desc = if entry.description != null then entry.description else deviceName;
        source = audioSourceByName.${deviceName} or "explicit";
      in ''
        ${lib.escapeShellArg desc})
          nixaudio_device=${lib.escapeShellArg deviceName}
          nixaudio_source=${lib.escapeShellArg source}
          ;;
      '')
    localAudioCatalogue);

  # Surfaced into `config.warnings` only when some peer's audio resolution is actually enabled
  # (see `config` below) -- an always-on warning for a seam nobody is using trains operators to
  # ignore warnings, exactly probeFact's own header's point.
  audioConsumed = lib.any (peer: peer.audio.enable && peer.audio.localAddress != null) (lib.attrValues cfg);

  # ── ORIGIN MARKING: the "static app_id route" ─────────────────────────────────────────────
  # A forwarded window's Wayland `app_id` passes through waypipe UNCHANGED by default (waypipe
  # proxies the Wayland protocol, it does not rewrite it) — so a compositor on the RECEIVING end
  # has no built-in way to tell "this `foot` window is local" from "this `foot` window was just
  # forwarded from somewhere else". Per-window compositor state (a border colour, in sway/scroll
  # terms) is keyed off criteria like `app_id`, so the cheapest way to make that distinction
  # visible is to make the app_id itself carry it: launch the REMOTE app with its own
  # `--app-id=<app>@<origin-peer-name>` flag, when the app in question actually has one.
  #
  # `<origin-peer-name>` is this module's own `nixremote.forward.<name>` attribute name (the same
  # vocabulary a consuming compositor config's own peer/host registry already uses, e.g. this
  # tree's `modules/shared/host-accents.nix` on the private infra side) — NOT `peer.sshAlias`
  # (`nixremote-<name>`), which is an internal SSH-config namespacing detail with no business
  # leaking into a window's own identity.
  #
  # Only a REAL, verified command-line flag goes in this table. An app outside it is forwarded
  # completely unmarked, exactly as if this feature did not exist — there is no attempt to guess
  # a flag for an app this module hasn't checked. The general-purpose fallback for those apps is
  # NOT this table: it is `NIXREMOTE_ORIGIN` (set below, in every wrapper unconditionally) read
  # back via scroll's own Lua API (`view_get_env(view, "NIXREMOTE_ORIGIN")`, which resolves
  # `/proc/<pid>/environ` of the process that opened the Wayland socket — for a waypipe-forwarded
  # window that is waypipe's own LOCAL process, i.e. exactly the process this wrapper `exec`s
  # into, so the var only has to be exported once, here, not threaded through the remote side at
  # all). A Lua script consuming that hook is a compositor-config concern, and lives wherever
  # that config lives — this module only guarantees the environment variable is there to read.
  #
  #   foot(1): "-a, --app-id=ID  Sets app id for foot window(s) (default: foot)." — verified
  #   against foot's own man page, not assumed from a generic "every terminal has --app-id"
  #   convention other emulators may not actually share (alacritty has no such flag at all;
  #   kitty's is spelled differently across versions) — so nothing beyond foot is claimed here.
  appIdFlagTemplates = {
    foot = tag: "--app-id=${tag}";
  };

  # Cheap TCP-connect reachability probe, used as the `exec` condition in
  # generated `Match` blocks. Pure bash + coreutils (referenced by absolute
  # store path so it works regardless of the ambient PATH `Match exec` runs
  # under) — no netcat dependency.
  probeScript = pkgs.writeShellScriptBin "nixremote-probe" ''
    host="$1"
    port="$2"
    timeout_ms="''${3:-300}"
    timeout_s=$(${pkgs.gawk}/bin/awk -v ms="$timeout_ms" 'BEGIN { s = ms / 1000; if (s < 0.1) s = 0.1; printf "%.3f", s }')
    ${pkgs.coreutils}/bin/timeout "$timeout_s" ${pkgs.bash}/bin/bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  '';

  # Remote-side orphan reaper, one derivation per sshAlias (the tag baked
  # into the script IS the sshAlias, so this is naturally per-peer without
  # needing a separate argument-passing dance). Piped to `bash -s` over a
  # plain ssh connection (no waypipe involved here — this is just remote
  # process bookkeeping) rather than embedded inline in an ssh command
  # string, to avoid multiple layers of shell-quoting hell.
  #
  # DETECTION: every wrapper script this module generates tags its remote
  # command with `env NIXREMOTE_PEER=<sshAlias> <command>`, but that tag
  # does NOT end up in the environment of the process that actually gets
  # re-parented to PID 1. The remote chain is `<login-shell> -c "waypipe
  # ... server ... env NIXREMOTE_PEER=<alias> <app>"` — the login shell
  # forks rather than execs for a `-c` command, and `waypipe server`
  # itself forks `env` as a child rather than exec-ing into it directly,
  # so the tag (set only once `env` itself execve's into `<app>`) lives
  # exactly TWO forks below the orphaned root. `/proc/<pid>/environ` of
  # that root reliably finds nothing.
  #
  # What DOES reliably carry the tag on the orphaned root itself: its own
  # COMMAND LINE. ssh always joins a multi-word remote command into ONE
  # string and hands it as a single argument to `<login-shell> -c`, so the
  # literal text `NIXREMOTE_PEER=<sshAlias>` is always a substring of the
  # root process's own cmdline, regardless of how many forks separate it
  # from the leaf that actually has the var set in its environment.
  # Detection below greps `/proc/<pid>/cmdline`, not `environ`.
  #
  # When the local wrapper dies WITHOUT the remote app exiting first (the
  # documented, unfixed waypipe limitation — see the module header), the
  # remote process tree's ROOT gets re-parented to PID 1 (verified live:
  # `ps` showed exactly this after an external SIGTERM of the local
  # wrapper) while its children keep their normal parent chain underneath
  # that orphaned root. So: find processes with PPID 1 whose command line
  # carries this peer's tag, and kill their whole process group (not just
  # the one PID) to take the entire orphaned tree down together.
  remoteReapScriptFor = sshAlias: pkgs.writeText "nixremote-reap-remote-${sshAlias}.sh" ''
    set -eu
    found=0
    while read -r pid pgid; do
      # `[ -r ]` alone isn't sufficient — the kernel's ptrace_may_access check
      # can still deny /proc/<pid>/cmdline even when raw permission bits look
      # readable, printing "Permission denied" straight to the terminal if
      # stderr is only redirected on the `tr` command. Redirect stderr on the
      # whole compound command instead, so it catches the open() failure
      # regardless of which layer triggers it.
      if { [ -r "/proc/$pid/cmdline" ] && tr '\0' '\n' < "/proc/$pid/cmdline" | grep -q "NIXREMOTE_PEER=${sshAlias}"; } 2>/dev/null; then
        echo "nixremote-reap: killing orphaned group $pgid (pid $pid, peer ${sshAlias})" >&2
        kill -TERM -- -"$pgid" 2>/dev/null || true
        found=1
      fi
    done < <(${pkgs.procps}/bin/ps -eo pid,ppid,pgid --no-headers | ${pkgs.gawk}/bin/awk '$2==1{print $1, $3}')
    [ "$found" = 1 ] || echo "nixremote-reap: nothing to reap for ${sshAlias}" >&2
  '';

  addressModule = { lib, ... }: {
    options = {
      address = lib.mkOption {
        type = lib.types.str;
        description = "IP address or hostname to try for this peer.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 22;
        description = "SSH port to probe/connect on for this address.";
      };
      probeTimeoutMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = ''
          How long (milliseconds) to wait for this address to answer before
          falling through to the next one in the list. Keep this small for a
          LAN address (a reachable LAN host answers in low single-digit
          milliseconds) — the whole point of the cascade is that a failing
          probe should barely be felt, not hang.
        '';
      };
    };
  };

  peerModule = { name, ... }: {
    options = {
      addresses = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule addressModule);
        description = ''
          Ordered candidate addresses for this peer. The FIRST address whose
          TCP probe succeeds wins; put your fastest/most-local address first
          (e.g. a LAN IP) and progressively more-reachable-from-anywhere
          addresses after it (e.g. a VPN/overlay IP). At least one entry is
          required.
        '';
        example = [
          { address = "192.168.1.10"; }
          { address = "100.64.0.10"; probeTimeoutMs = 500; }
        ];
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SSH user for this peer. Null = ssh's own default (current user).";
      };

      sshAlias = lib.mkOption {
        type = lib.types.str;
        default = "nixremote-${name}";
        description = ''
          The actual SSH Host/Match alias used internally by the generated
          config and the wrapper script's own `waypipe ssh` invocation —
          distinct from `scriptName` (the user-facing command) and
          namespaced by default so it can't collide with some OTHER tool's
          own auto-registered SSH alias for the same machine.

          This is not a theoretical concern: NetBird installs a system-wide
          `/etc/ssh/ssh_config.d/*.conf` `Match host "...,<name>,..."` hook
          listing every peer's short name (including plain "<name>" itself)
          that force-sets its own ProxyCommand when it thinks it should
          handle the connection. Namespacing sidesteps ever colliding with
          it in the first place, regardless of whatever precedence
          behavior a given SSH client has for such hooks.
        '';
      };

      scriptName = lib.mkOption {
        type = lib.types.str;
        default = "waypipe@${name}";
        description = ''
          Name of the generated wrapper executable, installed on $PATH via
          `home.packages`. Defaults to the `waypipe@<peer>` convention
          already in use here, but as a real script rather than a
          fish-only function, so it works from any shell.
        '';
      };

      binary = lib.mkOption {
        type = lib.types.str;
        default = "waypipe";
        example = "/usr/bin/waypipe";
        description = ''
          The waypipe binary the wrapper script execs LOCALLY, and also
          passes as `--remote-bin` for the REMOTE side (assumes a
          symmetric setup — both ends need a working waypipe reachable
          the same way; that's the common case and what this module's own
          testing covered).

          A BARE NAME by default, resolved through `$PATH`, so whatever
          provides waypipe on this host wins. Set an absolute path only to
          pin a specific copy.
        '';
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        example = lib.literalExpression "pkgs.waypipe";
        description = ''
          A nixpkgs package to install via `home.packages` so that
          `binary` resolves, or null (the default) to install nothing and
          use whatever waypipe the host already provides.

          ── WHY THE DEFAULT INSTALLS NOTHING ────────────────────────────
          This module must not choose which waypipe you run. On a hybrid
          Nix-on-non-NixOS host (Arch/CachyOS plus home-manager), nixpkgs'
          own `waypipe` build links against NIX'S OWN vulkan-loader, which
          searches only Nix store paths for a Vulkan ICD. It has NO
          visibility into the host's real GPU driver install (an
          Arch-packaged `vulkan-radeon` under `/usr/lib` with its ICD JSON
          in `/usr/share/vulkan/icd.d/`), even when that host Vulkan stack
          is completely healthy.

          Verified live: `vulkaninfo` and `vkcube` both worked perfectly
          over plain SSH, while `pkgs.waypipe` failed every DMABUF/
          GPU-touching connection with "Failed to create Vulkan instance:
          Unable to find a Vulkan driver". `LD_DEBUG=libs` confirmed it
          searched only `/nix/store/.../glibc.../lib` and never
          `/usr/lib`; `VK_LOADER_DEBUG=error,warn` confirmed the loader
          found the ICD JSON but could not `dlopen` the driver it pointed
          at — even given an absolute path with all layers disabled —
          because it was the WRONG glibc/loader pair, not a path or
          permissions problem. `--no-gpu` (see `extraOptions`) dodges the
          crash at the cost of every GPU-accelerated app and all
          `--video=` hardware encoding.

          Installing a package here also puts it on `$PATH`, where it can
          silently SHADOW a correctly-linked host build for any ad hoc
          `waypipe ...` invocation outside this module's wrapper — so a
          wrong choice here breaks more than this module.

          Hence: the host decides, and this module defaults to trusting
          it. On NixOS, set this to `pkgs.waypipe` explicitly (or install
          waypipe system-wide); on Arch, install it with pacman and leave
          this null.
        '';
      };

      video = lib.mkOption {
        type = lib.types.enum [ "none" "h264" "vp9" "av1" ];
        default = "h264";
        description = ''
          Hardware-encode DMABUF motion content instead of forwarding raw
          frames through `--compress` (lz4 on the CPU). Verified live: with
          `none`, waypipe's own frame-forwarding process was the single
          largest CPU consumer on the sending host during real playback —
          ~90% of a core, well above the forwarded app itself — enough
          headroom loss under host load to cause audible audio stutter
          (the audio path is a separate, independent tunnel competing for
          the same CPU). `h264` moves that work onto the GPU's dedicated
          encode engine instead (confirmed live: a real hardware encode
          queue selected on an RX 6800, `hwenc T`), which is why it's the
          default rather than an opt-in.

          These are waypipe's own supported values (`waypipe --help`) —
          there is no `h265`, only `h264`/`vp9`/`av1`. Which of `vp9`/`av1`
          actually get hardware-encoded (vs. falling back to software, or
          failing outright) depends entirely on the SENDING host's GPU and
          driver — untested here beyond `h264`; check `waypipe --debug`
          output for `hwenc T`/`hwenc f` per codec before relying on one.
          `none` restores the old CPU-compression-only behavior.
        '';
      };

      compress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "zstd=5";
        description = ''
          Passthrough for waypipe's `--compress` (CPU compression of
          non-DMABUF/non-video traffic — Wayland protocol metadata, SHM
          buffer diffs for apps like `foot`; irrelevant to `video`-encoded
          motion content, which bypasses this entirely). `null` (the
          default) leaves waypipe's own default (`lz4`) untouched.

          Measured live via `waypipe bench` against a real LAN link (this
          module's actual link between two real hosts, ~1.6-2ms): for
          `image-like` content lz4's compression ratio is ~1.004 — i.e.
          essentially none, since photo/rendered data doesn't dedup well —
          meaning it is pure CPU cost with no bandwidth payoff there
          (moot in practice: `video=h264` already routes that content
          away from `--compress` entirely). For `text-like` content
          (`foot` and friends' actual traffic) `zstd` at a tuned level
          measurably beats untuned `lz4` at realistic LAN bandwidths
          (e.g. `zstd=5` at 100 MB/s: ~42ms/32MB vs. lz4's untuned
          default) — worth setting explicitly if you forward a lot of
          terminal/text-heavy apps and want to squeeze this further, but
          the gain here is real, not dramatic — nowhere near `video`'s.
        '';
      };

      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--no-gpu" ];
        description = ''
          Extra flags passed directly to the local `waypipe` invocation
          (e.g. `"--no-gpu"` to block DMABUF/GPU protocols entirely and
          force pure-shm forwarding — see `package`'s gotcha for when
          that matters). Don't put `--video=` here — use the dedicated
          `video` option above instead, so the two can't disagree. See
          `waypipe --help` for the full flag set; passed as-is, this module
          has no opinion on their content.
        '';
      };

      serverAliveInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = ''
          `ServerAliveInterval` for this peer's generated blocks — how often
          (seconds) the CLIENT probes the connection. Bounds how long a
          forwarded session hangs locally if the network genuinely vanishes
          (laptop suspend, wifi drop) without an explicit close — after
          `serverAliveCountMax` unanswered probes the local side gives up and
          exits. This is a purely CLIENT-side timeout: it does not, and
          cannot, fix cleanup on the remote side (see `nixremote-reap-<name>`
          below) — a vanished network means the remote end never even learns
          the client is gone.
        '';
      };

      serverAliveCountMax = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          `ServerAliveCountMax` for this peer's generated blocks — unanswered
          keepalive probes tolerated before the local side gives up. Total
          detection time is roughly `serverAliveInterval * serverAliveCountMax`.
        '';
      };

      audio = lib.mkOption {
        default = { };
        description = ''
          Best-effort audio routing for the forwarded app, riding on top of a
          PipeWire device-mesh daemon if one happens to be running on the
          peer (the kind of setup that mirrors every real audio device on
          every node as a `Tunnel to tcp:<addr>:<port>/<device>`-described
          sink — this module doesn't run or require that daemon, it only
          looks for its sinks). waypipe forwards the Wayland protocol only;
          it has no concept of audio at all, so a forwarded app's sound
          plays out of whatever the PEER's own default sink is, which is
          almost never what you want (verified live: a forwarded Firefox's
          audio came out of the remote machine's own headphone jack, not the
          caller's). Rather than pin a fixed destination, this resolves,
          fresh on every launch, to whichever LOCAL device is CURRENTLY the
          caller's default — so if you switch outputs (headset, speakers,
          HDMI), the next forwarded app you launch follows automatically,
          same as any other app already does. It does not follow a LIVE
          device switch mid-session — the caller's audio stack already
          doesn't do that for existing streams either, so this isn't a
          feature gap.

          When `nixaudio` (github:julian-corbet/nixaudio-corbet-ch) is composed on this host,
          the current default sink is additionally checked against its declared device
          inventory (`nixaudio.fabric.catalogue`, read via `lib.probeFact` — never a flake
          input, see this module's header) before the lookup below is attempted, so a sink
          nixaudio doesn't recognise (typically an already-mirrored fabric tunnel) is skipped
          rather than chased through another hop. Absent nixaudio, this degrades to exactly the
          string-match described above, unconditionally.
        '';
        type = lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Attempt the sink resolution described above. Purely
                best-effort: if the caller has no default sink, the peer is
                unreachable for the lookup, or no matching mirrored sink is
                found, the forwarded app's audio just falls back to
                whatever the peer's own default sink is (today's behavior)
                — a missing audio mesh never blocks the window forward
                itself.
              '';
            };

            localAddress = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "192.168.1.14";
              description = ''
                The address THIS machine is known by on the peer's audio
                mesh — i.e. the address that appears after `tcp:` in that
                mesh's `Tunnel to tcp:<addr>:<port>/<device>` sink
                descriptions for devices originating here. Null (the
                default) skips audio resolution entirely: there is no
                generic way to guess this (it depends entirely on how the
                remote mesh addresses its nodes), so an explicit address is
                required to opt in.
              '';
            };

            tunnelPort = lib.mkOption {
              type = lib.types.port;
              default = 4713;
              description = ''
                Port to match in the peer's `Tunnel to tcp:<addr>:<port>/...`
                sink descriptions. Defaults to 4713, the standard
                PulseAudio/PipeWire native-protocol port most such meshes
                listen on.
              '';
            };
          };
        };
      };
    };
  };
in
{
  options.nixremote.forward = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule peerModule);
    default = { };
    description = ''
      Declare a peer machine to forward native Wayland app windows to/from,
      via waypipe's own `ssh` mode, with an ordered address cascade for the
      initial connection. An empty attrset is a complete no-op. The
      attribute name is used to derive (by default) both the generated SSH
      alias (`sshAlias`, namespaced as `nixremote-<name>` to avoid
      colliding with any other tool's own auto-registered alias for the
      same peer) and the `waypipe@<name>` wrapper script name
      (`scriptName`).
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = lib.mapAttrsToList
      (name: peer: {
        assertion = peer.addresses != [ ];
        message = "nixremote.forward.${name}.addresses must have at least one entry.";
      })
      cfg;

    # Only surfaced when some peer's audio resolution is actually enabled (`audioConsumed`,
    # top-level `let`) — probeFact's own state (a)/(b) (nixaudio absent, or composed but
    # genuinely empty) are already silent by construction; this only ever carries state (c), a
    # renamed/rejected leaf on a host that DOES compose nixaudio and DOES try to use it here.
    warnings = lib.optionals audioConsumed (audioCatalogueProbe.warnings ++ audioDevicesProbe.warnings);

    home.packages =
      [ probeScript ]
      # Only packages a peer explicitly asked for. This module names no package of its own --
      # see `package`'s description for the Vulkan-loader failure that makes choosing one here
      # actively harmful on a non-NixOS host.
      ++ (lib.unique (lib.filter (p: p != null) (map (p: p.package) (lib.attrValues cfg))))
      ++ (lib.mapAttrsToList
        (name: peer:
          let
            waypipeExe = peer.binary;

            videoFlag = lib.optionals (peer.video != "none") [ "--video=${peer.video}" ];
            compressFlag = lib.optionals (peer.compress != null) [ "--compress=${peer.compress}" ];

            # Best-effort: resolve which of the PEER's own sinks is a mesh
            # mirror of OUR current default sink, and pass it as PULSE_SINK
            # for the forwarded app. Every failure mode (no local default
            # sink, peer unreachable, no matching mirror) falls through to
            # `extra_env` staying just NIXREMOTE_PEER — never fatal, never
            # blocks the actual window forward. Runs FRESH inside every
            # generated wrapper invocation, i.e. once per forwarded WINDOW,
            # never precomputed here at build time and never cached across
            # peers or launches — "audio follows its windows around" (see
            # `knowledge/hosts/shared/workstation-story.md` §3) needs a
            # per-launch read of wherever the caller's ears currently are,
            # not a per-machine constant; two different peers below get two
            # entirely independent renderings of this, one per
            # `peer.audio.localAddress`, so forwarding windows to several
            # peers at once never collapses onto one shared destination.
            #
            # This SSH round-trip is the one piece nixaudio's catalogue
            # cannot replace at eval time: which sink currently mirrors us
            # on the PEER is live STATE, not declared config (see
            # workstation-story.md §7c and nixaudio's own `fabric.nix`
            # header, "routing intent is state, never Nix"), so it is
            # knowable only by asking the peer, right now. See this
            # module's own header for the full trace of what the catalogue
            # can and cannot replace here.
            sshFabricLookup = ''
              pat="Tunnel to tcp:${peer.audio.localAddress}:${toString peer.audio.tunnelPort}/$local_sink"
              fabric_sink="$(${pkgs.openssh}/bin/ssh ${lib.escapeShellArg peer.sshAlias} pactl list sinks 2>/dev/null | ${pkgs.gawk}/bin/awk -v pat="$pat" '
                /^[[:space:]]*Name:/ { name = $2 }
                index($0, pat) { print name; exit }
              ')"
              if [ -n "$fabric_sink" ]; then
                extra_env="$extra_env PULSE_SINK=$fabric_sink"
              fi
            '';

            # Only rendered when nixaudio is composed here (`nixaudioComposed`, an eval-time Nix
            # bool from the top-level `let`): identifies the caller's current default sink
            # against nixaudio's own declared inventory FIRST, then falls through to the exact
            # same `sshFabricLookup` above. A sink nixaudio doesn't recognise is left alone
            # entirely — see this module's header for why (almost always a fabric mirror
            # itself, and chasing a mirror across another hop cannot succeed).
            catalogueGate = ''
              local_desc="$(${pkgs.pulseaudio}/bin/pactl list sinks 2>/dev/null | ${pkgs.gawk}/bin/awk -v target="$local_sink" '
                /^[[:space:]]*Name:/ { n = $0; sub(/^[[:space:]]*Name:[[:space:]]*/, "", n); active = (n == target); next }
                active && /^[[:space:]]*Description:/ { d = $0; sub(/^[[:space:]]*Description:[[:space:]]*/, "", d); print d; exit }
              ')"
              nixaudio_device=""
              nixaudio_source=""
              case "$local_desc" in
              ${audioDeviceCaseBody}
                *) : ;;
              esac
              if [ -n "$nixaudio_device" ]; then
                if [ "$nixaudio_source" = "explicit" ]; then
                  echo "nixremote: local output '$nixaudio_device' is a host-local (non-fleet-shared) nixaudio device -- the peer's own static catalogue may not have expected it in advance, though its live fabric daemon mirrors whatever it actually finds regardless" >&2
                fi
              ${sshFabricLookup}
              fi
            '';

            audioResolve = lib.optionalString (peer.audio.enable && peer.audio.localAddress != null) ''
              local_sink="$(${pkgs.pulseaudio}/bin/pactl get-default-sink 2>/dev/null)" || local_sink=""
              if [ -n "$local_sink" ]; then
              ${if nixaudioComposed then catalogueGate else sshFabricLookup}
              fi
            '';

            # One `case` arm per `appIdFlagTemplates` entry (module-level `let`, see its own
            # header for the full design), rendered with THIS peer's own `name` baked into the
            # tag — so `waypipe@${name} foot` ends up invoking `foot --app-id=foot@${name}` on
            # the remote end, regardless of which peer's wrapper is the one doing it.
            appIdCaseBody = lib.concatStrings (lib.mapAttrsToList
              (appName: mkFlag: ''
                ${lib.escapeShellArg appName})
                  app_id_flag=${lib.escapeShellArg (mkFlag "${appName}@${name}")}
                  ;;
              '')
              appIdFlagTemplates);
          in
          pkgs.writeShellScriptBin peer.scriptName ''
            extra_env="NIXREMOTE_PEER=${lib.escapeShellArg peer.sshAlias}"
            ${audioResolve}

            # ── ORIGIN MARKING (see this module's own `appIdFlagTemplates` header) ────────────
            # `NIXREMOTE_ORIGIN` is exported into THIS process's own environment (never passed
            # through `env` to the remote side, unlike `extra_env` above) because the general
            # Lua-fallback route reads it off the LOCAL waypipe process this script `exec`s into
            # — see the header comment for why that is the correct process to tag.
            export NIXREMOTE_ORIGIN=${lib.escapeShellArg name}

            # Static app_id route: rewrite argv so a known app-id-capable app (see
            # `appIdFlagTemplates`) carries "$1@${name}" as its own app_id. Everything outside
            # that table passes through completely unchanged, exactly as before this existed.
            app_cmd=""
            app_id_flag=""
            if [ "$#" -gt 0 ]; then
              app_cmd="$1"
              shift
              case "$app_cmd" in
              ${appIdCaseBody}
              esac
            fi

            exec ${waypipeExe} ${lib.escapeShellArgs (videoFlag ++ compressFlag ++ peer.extraOptions)} --remote-bin ${lib.escapeShellArg waypipeExe} ssh ${lib.escapeShellArg peer.sshAlias} env $extra_env ''${app_cmd:+"$app_cmd"} ''${app_id_flag:+"$app_id_flag"} "$@"
          ''
        )
        cfg)
      ++ (lib.mapAttrsToList
        (name: peer:
          pkgs.writeShellScriptBin "nixremote-reap-${name}" ''
            exec ${pkgs.openssh}/bin/ssh ${lib.escapeShellArg peer.sshAlias} bash -s < ${remoteReapScriptFor peer.sshAlias}
          ''
        )
        cfg);

    # Plain text, hand-rendered in exact list order — no DAG/ordering
    # machinery needed since string concatenation IS the order. OpenSSH
    # applies the first-set value per directive across sequential Host/Match
    # blocks, so each peer's blocks must appear with the highest-priority
    # (first-address) probe block before its fallback(s), which `imap0`
    # over `peer.addresses` in declared order already guarantees.
    home.file.".ssh/conf.d/nixremote.conf".text =
      let
        mkBlock = peer: n: idx: addr:
          let
            isLast = idx == n - 1;
            header =
              if isLast
              then "Host ${peer.sshAlias}"
              else ''Match host ${peer.sshAlias} exec "${probeScript}/bin/nixremote-probe ${addr.address} ${toString addr.port} ${toString addr.probeTimeoutMs}"'';
            portLine = lib.optionalString (addr.port != 22) "  Port ${toString addr.port}\n";
            userLine = lib.optionalString (peer.user != null) "  User ${peer.user}\n";
          in ''
            ${header}
              HostKeyAlias ${peer.sshAlias}
              HostName ${addr.address}
              ServerAliveInterval ${toString peer.serverAliveInterval}
              ServerAliveCountMax ${toString peer.serverAliveCountMax}
            ${portLine}${userLine}'';

        mkPeer = name: peer:
          let n = lib.length peer.addresses;
          in lib.concatStrings (lib.imap0 (mkBlock peer n) peer.addresses);
      in
      ''
        # Generated by nixremote (nixremote.forward.*) — do not hand-edit.
        # Requires `Include ~/.ssh/conf.d/nixremote.conf` as the first line
        # of ~/.ssh/config (added once, by hand — see this module's header).
      '' + lib.concatStringsSep "\n" (lib.mapAttrsToList mkPeer cfg);
  };
}

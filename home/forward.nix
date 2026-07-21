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
#   - Package install (`waypipe` itself) comes straight from nixpkgs via
#     `home.packages` — no AUR, no pacman, no dependency on nixarch or any
#     other system-management layer. That's what makes this module usable
#     standalone on any Wayland + home-manager system, not just an
#     Arch/nixarch box. See the `waypipeBinary` gotcha below for the one
#     real caveat that comes with that portability.
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
# Found live: an earlier version of this wrapper passed the whole remote
# command as ONE quoted string, `"exec env NIXREMOTE_PEER=... $*"`. This
# broke every forward with `Error: "src/main.rs:1262: Failed to run
# program \"exec\": No such file or directory"` — waypipe's `ssh` mode
# takes the trailing words as a literal argv vector it constructs the
# remote invocation from itself; it does not hand a single joined string
# to a remote shell for parsing the way plain `ssh host "cmd args"` does.
# Quoting the whole thing into one argument made `exec` (a shell
# builtin, not a real binary) the literal first word waypipe tried to
# execute directly. Fixed by passing `env NIXREMOTE_PEER=<alias> "$@"` as
# separate, unquoted shell words (so bash expands them into separate argv
# items before waypipe ever sees them) and dropping `exec` entirely —
# `env`(1) already replaces its own process image via `execve` once it
# sets up the environment, so the tag lands on the correct final PID with
# no shell-level `exec` trick needed. Verified live: `vkcube` rendered
# remotely (RX 6800 selected, exit 0) with this exact shape, immediately
# after the quoted/`exec`-prefixed form failed outright.
#
# ── HISTORY: this module's FIRST design was built around `tssh`'s ─────────
# ── `EnableWaypipe`, which does not exist in the tssh actually installed ──
# The original design invoked `tssh <peer> -o EnableWaypipe=yes <app>`,
# following `tssh`'s own documented feature set. Verified live, the
# HARD way: `tssh --help` and `man tssh` for the installed build
# (trzsz-ssh 0.1.25) mention NOTHING about waypipe, Wayland, or GPU
# forwarding anywhere, and `tssh --debug` traces of a live session showed
# zero waypipe-related activity — only ordinary SSH channel setup. Every
# `-o EnableWaypipe=yes` invocation was silently accepted (tssh's `-o`
# parser stores arbitrary unrecognized keys without erroring) and did
# NOTHING: the "forwarded" app was actually just running on the REMOTE
# machine's own local Wayland session the entire time, invisible to
# whoever was looking at the LOCAL screen. This is exactly why "the
# process exited cleanly with no errors" was never sufficient evidence of
# anything working in this module's own development — only an actual
# screenshot, or the user's own eyes, ever caught this. The fix was to
# rebuild the wrapper around waypipe's OWN `ssh` mode (`waypipe ssh <dest>
# <command>`), which genuinely implements the Wayland-forwarding protocol
# itself and needs no tssh involvement at all.
#
# ── GOTCHA: tssh-specific keywords must NEVER land in ~/.ssh/config ────────
# This module no longer uses tssh, but if a caller's OWN config still
# layers tssh-specific extended options (`EnableWaypipe`, `UdpMode`,
# `TsshdPath`, etc.) into shared ssh config for OTHER purposes: those are
# tssh extensions, not OpenSSH directives, and plain OpenSSH's config
# parser aborts ALL parsing — for every Host, not just the one it doesn't
# recognize — the moment it meets an unrecognized keyword anywhere in the
# file. This module's own generated file never contains any such keyword
# (only standard `Host`/`Match`/`HostName`/etc. directives) — keep it that
# way if you extend it.
#
# ── GOTCHA: HostKeyAlias must be pinned per peer, not left to default ──────
# A peer's resolved Hostname can change between activations of this very
# cascade (LAN today, overlay tomorrow), so `HostKeyAlias <peer>` is set
# unconditionally on every generated block for that peer — known_hosts stays
# keyed on the stable peer name, never on whichever address happened to
# answer. (An earlier version of this module warned that `tssh` ignored
# `HostKeyAlias` — moot now that this module invokes plain `ssh` under
# waypipe's own `ssh` mode, which honors it normally, as verified live.)
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
# (An earlier version of this header warned that a VPN client's own
# system-wide `/etc/ssh/ssh_config.d/*.conf` ProxyCommand hook could
# hijack the connection, and had every wrapper pass `-o ProxyCommand=none`
# to work around it. Verified live: that hijack was a `tssh`-specific
# Match-evaluation bug — the identical config, alias, and system hook, but
# invoked as plain `ssh <alias>` or via waypipe's own `ssh` mode, was
# NEVER affected. Removed along with tssh itself.)
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.forward;

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
  # command with `env NIXREMOTE_PEER=<sshAlias> <command>`. Found live
  # (killing a real orphaned tree and inspecting it): that tag does NOT
  # end up in the environment of the process that actually gets
  # re-parented to PID 1. The chain sshd/waypipe build remotely is
  # `<login-shell> -c "waypipe ... server ... env NIXREMOTE_PEER=<alias>
  # <app>"` — the login shell (fish, on a nixfish-managed host) forks
  # rather than execs for a `-c` command, and `waypipe server` itself
  # forks `env` as a child rather than exec-ing into it directly, so the
  # env var (set only once `env` itself execve's into `<app>`) lives
  # exactly TWO forks below the orphaned root. Checking that root's own
  # `/proc/<pid>/environ` for the tag — the original design, carried over
  # from testing against a completely different remote-invocation shape
  # — reliably finds nothing.
  #
  # What DOES reliably carry the tag on the orphaned root itself: its own
  # COMMAND LINE. ssh always joins a multi-word remote command into ONE
  # string and hands it as a single argument to `<login-shell> -c`
  # (verified live via `tr '\0' '\n' < /proc/<pid>/cmdline`: exactly three
  # argv elements — the shell, `-c`, and the ENTIRE command as one huge
  # string) — so the literal text `NIXREMOTE_PEER=<sshAlias>` is always a
  # substring of the root process's own cmdline, regardless of how many
  # forks separate it from the leaf that actually has the var set in its
  # environment. Detection below greps `/proc/<pid>/cmdline`, not
  # `environ`.
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
      # readable (observed live against /proc/<pid>/environ under the
      # previous detection scheme: one PID slipped through the `-r` guard
      # and printed "Permission denied" straight to the terminal, bypassing a
      # `2>/dev/null` placed only on the `tr` command). Redirecting stderr on
      # the whole compound command, not just `tr`, catches the open() failure
      # itself regardless of which layer triggers it.
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
          already in use on this fleet, but as a real script rather than a
          fish-only function, so it works from any shell.
        '';
      };

      waypipeBinary = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute path to the waypipe binary the wrapper script execs
          LOCALLY, and also passes as `--remote-bin` for the REMOTE side
          (assumes a symmetric setup — both ends need a working waypipe at
          this same path; that's the common case and what this module's
          own testing covered). Null (the default) uses nixpkgs' own
          `pkgs.waypipe` build.

          ── GOTCHA, found via live testing on a hybrid Nix-on-non-NixOS ──
          ── host (e.g. Arch/CachyOS + system-manager/home-manager) ───────
          nixpkgs' own `waypipe` build links against NIX'S OWN
          vulkan-loader package, which only searches Nix store paths for
          a Vulkan ICD — it has NO visibility into the host's actual GPU
          driver installation (e.g. an Arch-packaged `vulkan-radeon` at
          `/usr/lib` + `/usr/share/vulkan/icd.d/`), even when that host
          Vulkan stack is completely healthy (verified live: `vulkaninfo`
          and `vkcube` both worked perfectly via plain SSH, while
          `pkgs.waypipe` failed every single DMABUF/GPU-touching
          connection with "Failed to create Vulkan instance: Unable to
          find a Vulkan driver" — confirmed via `LD_DEBUG=libs` that it
          was searching only `/nix/store/.../glibc.../lib` and similar,
          never `/usr/lib`, and confirmed via `VK_LOADER_DEBUG=error,warn`
          that the loader found the ICD JSON but failed to `dlopen` the
          driver library it pointed to — even with an absolute path and
          all Vulkan layers disabled — specifically because it was the
          WRONG glibc/loader pair, not a path or permissions problem).
          `--no-gpu` (see `extraOptions`) avoids the crash but also means
          no GPU-accelerated app or `--video=` hardware encoding ever
          works. The fix on such a host is to point this option at the
          SYSTEM package's binary instead (e.g. `"/usr/bin/waypipe"`,
          installed via whatever your system's own package manager
          provides) — set `installWaypipe = false` alongside this to also
          stop installing the shadowing nixpkgs copy onto $PATH at all,
          since otherwise any OTHER ad hoc bare `waypipe ...` invocation
          (outside this module's own wrapper) silently hits the exact same
          failure.
        '';
      };

      installWaypipe = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to install `pkgs.waypipe` via `home.packages` at all.
          Set to `false` when `waypipeBinary` above points at a
          system-provided binary instead — see its description for why
          installing both risks the nixpkgs build silently shadowing a
          correctly-linked system one on $PATH.
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
          module's actual archlxc↔elitebook link, ~1.6-2ms): for
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
          force pure-shm forwarding — see `waypipeBinary`'s gotcha for when
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

    home.packages =
      [ probeScript ]
      ++ (lib.optional (lib.any (p: p.installWaypipe) (lib.attrValues cfg)) pkgs.waypipe)
      ++ (lib.mapAttrsToList
        (name: peer:
          let
            waypipeExe = if peer.waypipeBinary != null then peer.waypipeBinary else "${pkgs.waypipe}/bin/waypipe";

            videoFlag = lib.optionals (peer.video != "none") [ "--video=${peer.video}" ];
            compressFlag = lib.optionals (peer.compress != null) [ "--compress=${peer.compress}" ];

            # Best-effort: resolve which of the PEER's own sinks is a mesh
            # mirror of OUR current default sink, and pass it as PULSE_SINK
            # for the forwarded app. Every failure mode (no local default
            # sink, peer unreachable, no matching mirror) falls through to
            # `extra_env` staying just NIXREMOTE_PEER — never fatal, never
            # blocks the actual window forward.
            audioResolve = lib.optionalString (peer.audio.enable && peer.audio.localAddress != null) ''
              local_sink="$(${pkgs.pulseaudio}/bin/pactl get-default-sink 2>/dev/null)" || local_sink=""
              if [ -n "$local_sink" ]; then
                pat="Tunnel to tcp:${peer.audio.localAddress}:${toString peer.audio.tunnelPort}/$local_sink"
                fabric_sink="$(${pkgs.openssh}/bin/ssh ${lib.escapeShellArg peer.sshAlias} pactl list sinks 2>/dev/null | ${pkgs.gawk}/bin/awk -v pat="$pat" '
                  /^[[:space:]]*Name:/ { name = $2 }
                  index($0, pat) { print name; exit }
                ')"
                if [ -n "$fabric_sink" ]; then
                  extra_env="$extra_env PULSE_SINK=$fabric_sink"
                fi
              fi
            '';
          in
          pkgs.writeShellScriptBin peer.scriptName ''
            extra_env="NIXREMOTE_PEER=${lib.escapeShellArg peer.sshAlias}"
            ${audioResolve}
            exec ${waypipeExe} ${lib.escapeShellArgs (videoFlag ++ compressFlag ++ peer.extraOptions)} --remote-bin ${lib.escapeShellArg waypipeExe} ssh ${lib.escapeShellArg peer.sshAlias} env $extra_env "$@"
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

# home/forward.nix — nixremote's core module: declarative, address-cascading
# native Wayland app-window forwarding between two Nix-managed peers, via
# waypipe + tssh (trzsz-ssh).
#
# THE SPLIT this module encodes:
#   - Each peer you declare gets an ORDERED list of candidate addresses (a
#     fast LAN IP first, a VPN/overlay IP as fallback, etc). This module
#     renders that ordering into native OpenSSH `Match ... exec` / `Host`
#     blocks, so a plain `ssh <peer>` (and, more to the point, the generated
#     `tssh <peer>` wrapper) transparently resolves to whichever address
#     answers first. Nothing here needs to know or care which path won.
#   - Package installs (`waypipe`, `trzsz-ssh`, optionally `tsshd`) come
#     straight from nixpkgs via `home.packages` — no AUR, no pacman, no
#     dependency on nixarch or any other system-management layer. That's
#     what makes this module usable standalone on any Wayland + home-manager
#     system, not just an Arch/nixarch box.
#   - One wrapper script per peer (a real executable on $PATH, not a
#     fish-specific function) is what actually invokes
#     `tssh <peer> -o EnableWaypipe=yes`.
#   - `ServerAliveInterval`/`ServerAliveCountMax` bound how long a forwarded
#     session hangs LOCALLY if the network genuinely disappears (not an
#     explicit close). This is a keepalive for the CLIENT's own hang, not a
#     cleanup mechanism for the remote side — see the next point.
#   - Every wrapper script tags its remote command with
#     `env NIXREMOTE_PEER=<sshAlias>`, and a generated `nixremote-reap-<name>`
#     command per peer finds and kills remote process trees still carrying
#     that tag after being orphaned (re-parented to PID 1). This exists
#     because tssh/waypipe's cleanup is only reliable when the forwarded app
#     exits on its own — killing the local wrapper externally (or a network
#     path vanishing) leaves the remote side running, a known upstream
#     limitation this module does not try to paper over, only clean up after
#     the fact, on demand.
#
# ── GOTCHA: tssh-specific keywords must NEVER land in ~/.ssh/config ────────
# `EnableWaypipe`, `UdpMode`, `TsshdPath`, `UdpAliveTimeout` etc. are tssh
# extensions, not OpenSSH directives. Plain OpenSSH's config parser aborts
# ALL parsing — for every Host, not just the one it doesn't recognize — the
# moment it meets an unrecognized keyword anywhere in the file. This module
# NEVER writes any of those keywords into the generated `matchBlocks` (which
# plain `ssh` also reads); they are passed only as `-o key=value` flags on
# the wrapper script's own `tssh` invocation, which only tssh ever parses.
# Do not "simplify" this by moving them into `programs.ssh.extraOptions` —
# that reintroduces exactly the mistake this module exists to avoid.
#
# ── GOTCHA: HostKeyAlias must be pinned per peer, not left to default ──────
# A peer's resolved Hostname can change between activations of this very
# cascade (LAN today, overlay tomorrow), so `HostKeyAlias <peer>` is set
# unconditionally on every generated block for that peer — known_hosts stays
# keyed on the stable peer name, never on whichever address happened to
# answer. This is correct and worth keeping for plain `ssh`/anything else
# reading this same config — but see the note below: `tssh` itself was
# observed NOT to honor `HostKeyAlias` for its own known_hosts lookup, so
# don't rely on it alone for a tssh-only setup.
#
# ── GOTCHA (found via live testing): tssh ignores HostKeyAlias for ────────
# ── known_hosts verification — bootstrap trust per literal ADDRESS ────────
# Observed directly: even with a `nixremote-<peer>` entry already trusted in
# known_hosts (via HostKeyAlias), a first connection through the generated
# wrapper script still hit "The authenticity of host ... can't be
# established" for every literal address in that peer's cascade. Plain
# `ssh` does not have this problem against the identical config — this is a
# `tssh`-specific behavior, not a config mistake. Practical consequence: the
# first time a NEW peer (or a new address added to an existing peer) is
# used, expect one interactive host-key prompt per literal address it can
# resolve to (not per peer name) — accept each once (e.g. `ssh-keyscan -t
# ed25519,ecdsa,rsa <address> | ssh-keygen -H -f ~/.ssh/known_hosts -R
# <address> ...` or a plain `ssh <peer>` from a real terminal), and it's
# never asked again for that address. This module cannot do that bootstrap
# step for you declaratively — nixpkgs has no way to know a real target's
# genuine host key in advance without either trusting an unverified fetch
# or requiring the caller to paste it in; a `programs.ssh.knownHosts`-style
# declarative pin is a plausible future addition (see README Roadmap) if
# this friction turns out to matter enough to justify the extra option
# surface.
#
# This module supplies NONE of the address values, package lists beyond
# waypipe/tssh themselves, or peer names — all of that is
# `nixremote.forward.<name>.*`, entirely the caller's. An empty attrset is a
# complete no-op.
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
# ── GOTCHA (found via live testing, not theoretical): third-party SSH ──────
# ── hooks can still hijack the connection even after Hostname resolves ────
# A VPN client (NetBird, and Tailscale has the same feature) may install its
# own SYSTEM-WIDE `/etc/ssh/ssh_config.d/*.conf` with a `Match host "<big
# comma list>" exec "..."` block that sets its own `ProxyCommand` when it
# thinks it should handle the connection. This was observed live: `tssh`
# applied such a hook's ProxyCommand even for a peer alias/resolved address
# that was NOT textually present in that hook's own match list — plain
# `ssh` was unaffected by the identical config, so this is a `tssh`-specific
# Match-evaluation quirk, not a config mistake on this module's part, and not
# something worth chasing into tssh's own source. The robust fix is a
# command-line override, which always wins over anything set inside a config
# file regardless of which Match block set it or why: every wrapper script
# this module generates passes `-o ProxyCommand=none` unconditionally. This
# is also the philosophically correct default for what this module IS — the
# whole point of the address cascade is "connect directly to whichever of
# these addresses answers," never through a third party's jump host.
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
  # plain, ProxyCommand-free ssh connection (no waypipe/tssh involved here —
  # this is just remote process bookkeeping) rather than embedded inline in
  # an ssh command string, to avoid multiple layers of shell-quoting hell.
  #
  # DETECTION: every wrapper script this module generates tags its remote
  # command with `exec env NIXREMOTE_PEER=<sshAlias> <command>`. The `exec`
  # is load-bearing, not decorative — found via live testing: `env VAR=val
  # cmd` WITHOUT `exec` forks a child to become `cmd`, so the tag lands on
  # that child, not on the shell process the remote sshd/tssh actually
  # invoked — and that outer shell, not its child, is the one that gets
  # re-parented to PID 1 when the local wrapper dies (its child stays a
  # normal child of it the whole time, since the child never itself lost a
  # parent). With `exec`, the tagging process REPLACES itself (execve,
  # same PID) all the way through to the final command, so the process that
  # actually ends up orphaned is the exact one carrying the tag. Verified
  # directly: without `exec`, the orphaned root's own `/proc/<pid>/environ`
  # had no trace of the tag even though a live descendant did; with `exec`,
  # the orphaned root itself carries it.
  #
  # When the local wrapper dies WITHOUT the remote app exiting first (the
  # documented, unfixed tssh/waypipe limitation — see the module header),
  # the remote process tree's ROOT gets re-parented to PID 1 (verified live:
  # `ps` showed exactly this after an external SIGTERM of the local wrapper)
  # while its children keep their normal parent chain underneath that
  # orphaned root. So: find processes with PPID 1 whose environment carries
  # this peer's tag, and kill their whole process group (not just the one
  # PID) to take the entire orphaned
  # tree down together.
  remoteReapScriptFor = sshAlias: pkgs.writeText "nixremote-reap-remote-${sshAlias}.sh" ''
    set -eu
    found=0
    while read -r pid pgid; do
      # `[ -r ]` alone isn't sufficient — the kernel's ptrace_may_access check
      # can still deny /proc/<pid>/environ even when raw permission bits look
      # readable (observed live: one PID slipped through the `-r` guard and
      # printed "Permission denied" straight to the terminal, bypassing a
      # `2>/dev/null` placed only on the `tr` command). Redirecting stderr on
      # the whole compound command, not just `tr`, catches the open() failure
      # itself regardless of which layer triggers it.
      if { [ -r "/proc/$pid/environ" ] && tr '\0' '\n' < "/proc/$pid/environ" | grep -qx "NIXREMOTE_PEER=${sshAlias}"; } 2>/dev/null; then
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
          config and the wrapper script's own `tssh` invocation — distinct
          from `scriptName` (the user-facing command) and namespaced by
          default so it can't collide with some OTHER tool's own
          auto-registered SSH alias for the same machine.

          This is not a theoretical concern: NetBird installs a system-wide
          `/etc/ssh/ssh_config.d/*.conf` `Match host "...,<name>,..."` hook
          listing every peer's short name (including plain "<name>" itself)
          that force-sets its own ProxyCommand — and tssh's own Match/Host
          precedence across system vs. user config was observed to differ
          from plain OpenSSH's, letting NetBird's ProxyCommand win over this
          module's own resolved HostName even though plain `ssh` was
          unaffected by the same collision. Using a namespaced alias here
          sidesteps the collision entirely rather than depending on any
          particular tool's precedence behavior.
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

      waypipeClientOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra waypipe client arguments (e.g. "--video=h264"), passed via
          tssh's WaypipeClientOption on the wrapper script's own
          invocation — never written to ~/.ssh/config.
        '';
      };

      waypipeServerOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra waypipe server arguments, passed via tssh's
          WaypipeServerOption on the wrapper script's own invocation — never
          written to ~/.ssh/config.
        '';
      };

      udpRoaming = {
        enable = lib.mkEnableOption ''
          tssh's UDP roaming mode (UdpMode) for this peer, so an established
          forwarding session survives the CLIENT's own network path changing
          mid-session (wifi to cellular, suspend/resume). This is unrelated
          to the address cascade above, which only picks the initial
          connection path — this keeps an already-open one alive afterwards.
          Installs pkgs.tsshd and passes TsshdPath so no imperative
          `tssh --install-tsshd` step is ever needed. Passed via the wrapper
          script's own `-o` flags, same as EnableWaypipe — never written to
          ~/.ssh/config
        '';

        aliveTimeout = lib.mkOption {
          type = lib.types.str;
          default = "10d";
          description = "tssh's UdpAliveTimeout for this peer, e.g. \"10d\", \"1w3d\".";
        };
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
    };
  };
in
{
  options.nixremote.forward = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule peerModule);
    default = { };
    description = ''
      Declare a peer machine to forward native Wayland app windows to/from,
      via waypipe + tssh, with an ordered address cascade for the initial
      connection. An empty attrset is a complete no-op. The attribute name
      is used to derive (by default) both the generated SSH alias
      (`sshAlias`, namespaced as `nixremote-<name>` to avoid colliding with
      any other tool's own auto-registered alias for the same peer) and the
      `waypipe@<name>` wrapper script name (`scriptName`).
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
      [ pkgs.waypipe pkgs.trzsz-ssh probeScript ]
      ++ (lib.optional (lib.any (p: p.udpRoaming.enable) (lib.attrValues cfg)) pkgs.tsshd)
      ++ (lib.mapAttrsToList
        (name: peer:
          let
            tsshOpts = [ "-o" "EnableWaypipe=yes" "-o" "ProxyCommand=none" ]
              ++ (lib.optionals (peer.waypipeClientOptions != [ ]) [
                "-o"
                "WaypipeClientOption=${lib.concatStringsSep " " peer.waypipeClientOptions}"
              ])
              ++ (lib.optionals (peer.waypipeServerOptions != [ ]) [
                "-o"
                "WaypipeServerOption=${lib.concatStringsSep " " peer.waypipeServerOptions}"
              ])
              ++ (lib.optionals peer.udpRoaming.enable [
                "-o"
                "UdpMode=yes"
                "-o"
                "TsshdPath=${pkgs.tsshd}/bin/tsshd"
                "-o"
                "UdpAliveTimeout=${peer.udpRoaming.aliveTimeout}"
              ]);
          in
          pkgs.writeShellScriptBin peer.scriptName ''
            exec ${pkgs.trzsz-ssh}/bin/tssh ${lib.escapeShellArg peer.sshAlias} ${lib.escapeShellArgs tsshOpts} "exec env NIXREMOTE_PEER=${lib.escapeShellArg peer.sshAlias} $*"
          ''
        )
        cfg)
      ++ (lib.mapAttrsToList
        (name: peer:
          pkgs.writeShellScriptBin "nixremote-reap-${name}" ''
            exec ${pkgs.openssh}/bin/ssh -o ProxyCommand=none ${lib.escapeShellArg peer.sshAlias} bash -s < ${remoteReapScriptFor peer.sshAlias}
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

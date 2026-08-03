# home/sunshine.nix — declarative Sunshine (LizardByte/Sunshine, github.com/LizardByte/Sunshine)
# desktop/game streaming host. Sibling to forward.nix: that module PULLS a window FROM a remote
# peer to look at here; this one is the inverse direction — SERVES this machine's own Wayland
# session so a remote Moonlight client can stream it. Same problem space ("declarative remote
# access to a Wayland session over Nix"), genuinely different shape (no peer/address-cascade —
# Sunshine just needs to run locally and be reachable), so it's its own module rather than forced
# into forward.nix's per-peer abstraction.
#
# THE REAL PROBLEM THIS SOLVES: Sunshine needs WAYLAND_DISPLAY set correctly to find the
# compositor's socket, and hardcoding a guessed value (e.g. "wayland-0") is fragile -- a compositor
# that happens to claim a different slot (a stale lock from a previous session, multiple
# compositors tested on the same box, etc.) silently breaks it. The fix used here: order this
# unit's activation via `graphical-session.target`, AFTER the compositor unit, and import the
# environment rather than hardcode it -- any niri/sway/wlroots compositor started with a
# `--session`-equivalent flag (or via a display manager) exports WAYLAND_DISPLAY into the systemd
# user manager's GLOBAL environment on startup, which every later-ordered unit inherits for free.
# Confirmed live 2026-07-22: niri's own `--session` flag does exactly this.
#
# ── FAIL CLOSED WHEN THE PINNED OUTPUT IS ABSENT ────────────────────────────────────────────────
#
# Sunshine has NO option to treat a missing `output_name` as fatal -- verified directly in its
# source (`src/video.cpp`, `src/platform/linux/wlgrab.cpp`), not assumed:
#
#   - `video::refresh_displays()` -- on a stream's FIRST call, `current_display_index` starts at
#     -1, so `current_display_name` is empty and the function takes the `else` branch: it loops
#     over the live output list looking for `output_name`, and if nothing matches, the loop simply
#     ENDS. `current_display_index` stays at the `0` it was reset to a few lines above, and NOTHING
#     is logged on this path -- the one warning line (`"Previous active display [...] is no longer
#     present"`) only exists on the *mid-stream* path (`current_display_name` non-empty), which a
#     first connection never takes.
#   - `wlr_t::init()` (`src/platform/linux/wlgrab.cpp`) -- an unmatched `display_name` falls
#     through to a hand-rolled numeric parse (`util::from_view`), fails the bounds check
#     (`streamedMonitor >= 0 && streamedMonitor < interface.monitors.size()`), and `monitor` is left
#     exactly where it was set two lines above the whole matching block: `interface.monitors[0]`.
#     Again, no log anywhere on this path.
#
#   Net effect on this estate: the 4K monitor migrates to another host, the pivoted HP stays
#   attached, a client connects, and Sunshine streams the HP in PORTRAIT while logging a POSITIVE
#   "Selected monitor" line naming the WRONG panel -- a confident lie, not a visible failure.
#
#   Two neighbouring traps, same root cause (no fatal path for "the output I was told to use isn't
#   there"): with ZERO outputs present at Sunshine's own startup, `platf::init()` latches its
#   "no capture method" state for the rest of the PROCESS's lifetime (the sources bitset is set
#   once, at init) -- hotplugging the panel back in does NOT recover it, only a full restart does.
#   And an output count that drops to zero *after* a successful start reaches an unguarded
#   `monitors[0]` on an empty vector.
#
# Since none of this is fixable from sunshine.conf, this module gates Sunshine from OUTSIDE:
# `requireOutput` renders an `ExecStartPre` that queries the compositor's OWN live output list
# (never Sunshine's) and fails the unit start outright -- before Sunshine's own silent fallbacks
# ever get a chance to run -- unless (a) at least one output exists at all (the zero-outputs
# latch, above) and (b) `outputName`, if pinned, is actually among them.
#
# THE QUERY IS COMPOSITOR-AWARE, because there is no single portable Wayland IPC for "list live
# outputs": niri, sway/scroll and a generic wlroots fallback (`wlr-randr`) each speak their own.
# `compositor` picks which one `outputQueryCommand`'s default targets, and is itself resolved
# through `lib.probeFact` (nixhost's `lib/facts.nix`, consumed via this repo's `nixhost` flake
# input -- see flake.nix) against `nixdesktop.desktop.compositor` -- the SAME free-form fact
# nixdesktop's own `profiles/desktop.nix` declares once for a whole session -- so a host that
# already tells nixdesktop which compositor it runs does not have to say it a second time here.
# `probeFact` rather than a bare `config.nixdesktop.desktop.compositor or null` for the usual
# reason this family uses it everywhere else (see nixhost's own header, and nixscroll's
# `nixdesktopStartupProbe` for the identical shape one repo over): a bare `or` cannot tell "this
# host never composed nixdesktop's profile at all" from "it did, but the fact itself was renamed
# or rejected by its own type" -- both would silently resolve to the identical `null` fallback,
# and only `probeFact`'s `state`/`warnings` can tell the difference. `compositor` stays free-form
# (`nullOr str`, not a closed enum) for the same reason nixdesktop's own option does: a compositor
# this repo has never heard of must become usable by *naming* it in an override, never by editing
# this file (`defaultOutputQueryCommandFor` below already falls through to a portable cascade for
# any name it doesn't recognise, including `null`).
#
# THE RESTART TRIGGER, considered and deliberately NOT added as a separate mechanism: the unit's
# own `Restart = "on-failure"; RestartSec = 5;` (below, unchanged from before this task) already
# covers it. A failing `ExecStartPre` is, per `systemd.service(5)`, treated exactly like a failing
# `ExecStart` for `Restart=` purposes -- so once the pinned output reappears (panel plugged back
# in, host migrated back), the very next 5-second retry's `ExecStartPre` succeeds and Sunshine
# starts normally, with nothing else to wire up. This does mean the gate script (a compositor IPC
# round-trip plus a `jq` parse, both sub-millisecond locally) reruns every 5 seconds for as long as
# the output stays absent -- cheap enough that this module does not expose a separate knob for it;
# override `systemd.user.services.sunshine.Service.RestartSec` directly from consuming config if a
# different cadence is ever actually needed.
{ probeFact }:
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.sunshine;

  # Defensive cross-repo read of the compositor's name -- see this module's header for why
  # `probeFact`, not a bare `config.nixdesktop.desktop.compositor or null`, and why `compositor`
  # stays free-form below. `state == "absent"` (nixdesktop never composed here) and a genuinely
  # unresolved fact are both silent (`value = null`); only a composed-but-renamed fact warns.
  compositorProbe = probeFact {
    inherit config;
    namespace = "nixdesktop";
    path = [ "desktop" "compositor" ];
    fallback = null;
  };

  # One shell pipeline per compositor, each producing a NEWLINE-SEPARATED list of live output/
  # connector names on stdout -- the one shape the gate script below needs, regardless of which
  # compositor produced it. `jq` is pinned to its own nixpkgs store path (`${pkgs.jq}/bin/jq`)
  # rather than left to resolve through $PATH like the compositor binaries themselves: this
  # module's own fail-closed *logic* depends on jq actually running, so its absence from a
  # systemd unit's minimal PATH must never silently look like "compositor produced zero outputs"
  # -- pinning it removes that entire failure class rather than hoping it's on PATH.
  #
  # CONFIG-KEY/JSON-SHAPE PROVENANCE, so a future reader knows what to trust and what to re-check:
  #   - niri: `niri msg --json outputs` returns a JSON OBJECT keyed by connector name
  #     (`niri-ipc::Response::Outputs(HashMap<String, Output>)`, confirmed directly against
  #     niri's own IPC source this session) -- hence `keys[]`, not `.[].name`.
  #   - sway/scroll: `swaymsg`/`scrollmsg -t get_outputs` returns a JSON ARRAY of output objects,
  #     each carrying a `name` field -- scroll's own `scroll-output(5)` confirms it speaks the
  #     identical `get_outputs` IPC sway does (verified against scroll's own man page this
  #     session); the array-of-`{name: ...}` shape itself is sway's long-stable, widely-documented
  #     IPC reply and was not independently re-derived from source here.
  #   - `wlr-randr --json`: the generic wlroots fallback for a compositor this module has no
  #     dedicated branch for -- an array of output objects, each carrying a `name` field, mirroring
  #     sway's own shape; not independently re-verified against wlr-randr's own source this
  #     session, so treat a mismatch report against a real wlr-randr build as more trustworthy
  #     than this comment.
  defaultOutputQueryCommandFor = compositor:
    if compositor == "niri" then
      "niri msg --json outputs | ${pkgs.jq}/bin/jq -r 'keys[]'"
    else if compositor == "sway" then
      "swaymsg -t get_outputs | ${pkgs.jq}/bin/jq -r '.[].name'"
    else if compositor == "scroll" then
      "scrollmsg -t get_outputs | ${pkgs.jq}/bin/jq -r '.[].name'"
    else
      # Unknown, or unresolved (probeFact came back null and nothing overrode `compositor`
      # explicitly): try the generic wlroots tool first, then guess niri, then fall back to the
      # sway/scroll IPC shape -- covers this repo's whole compositor family without requiring the
      # fact to have resolved at all.
      ''
        if command -v wlr-randr >/dev/null 2>&1; then
          wlr-randr --json | ${pkgs.jq}/bin/jq -r '.[].name'
        elif command -v niri >/dev/null 2>&1; then
          niri msg --json outputs | ${pkgs.jq}/bin/jq -r 'keys[]'
        else
          swaymsg -t get_outputs | ${pkgs.jq}/bin/jq -r '.[].name'
        fi
      '';

  # The gate itself. Rendered once, unconditionally (cheap -- it's just a `writeShellScript`
  # derivation reference, never built unless `requireOutput` actually wires it into a unit below).
  #
  # `set -euo pipefail` deliberately NOT applied to the whole script: the `names="$(...)" || { ...
  # }` idiom below needs the assignment's own failure to reach the `||`, which -e would otherwise
  # short-circuit past inside a plain top-level command (the assignment form used here is the
  # documented exception -- a command substitution's exit status IS checked, and IS caught by a
  # trailing `||`, which is why forward.nix's own `audioResolve` uses the identical shape).
  outputGateScript = pkgs.writeShellScript "nixremote-sunshine-output-gate" ''
    set -uo pipefail
    names="$(${cfg.outputQueryCommand})" || {
      status=$?
      echo "nixremote sunshine output gate: the output query exited $status -- refusing to start Sunshine rather than let it fall through to its own silent per-output-name/zero-output defaults (see this module's header). Command was: ${cfg.outputQueryCommand}" >&2
      exit 1
    }

    if [ -z "$(printf '%s' "$names" | tr -d '[:space:]')" ]; then
      echo "nixremote sunshine output gate: the compositor currently reports ZERO outputs. Refusing to start: Sunshine's platf::init() latches its 'no capture method' state for the rest of the PROCESS's lifetime the first time this happens (verified in source, see this module's header) -- a later hotplug would not recover it, only a restart would, so starting now risks permanently wedging this process instance." >&2
      exit 1
    fi

    ${lib.optionalString (cfg.outputName != null) ''
      if ! printf '%s\n' "$names" | grep -qxF -- ${lib.escapeShellArg cfg.outputName}; then
        echo "nixremote sunshine output gate: pinned output '${cfg.outputName}' is NOT in the compositor's current output list:" >&2
        printf '%s\n' "$names" | sed 's/^/  - /' >&2
        echo "Sunshine itself has no fatal path for this (video::refresh_displays()'s first-call branch and wlgrab.cpp's wlr_t::init() both fall back silently to display/monitor index 0 -- see this module's header) -- refusing to start rather than risk it streaming whatever panel happens to occupy that slot." >&2
        exit 1
      fi
    ''}
  '';
in
{
  options.nixremote.sunshine = {
    enable = lib.mkEnableOption "declarative Sunshine desktop/game streaming host";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.sunshine";
      description = ''
        A nixpkgs Sunshine package to install via home.packages, or null (the default) to
        install nothing and use whatever Sunshine the host already provides — `binary` resolves
        through $PATH.

        Defaults to installing NOTHING on purpose: this module does not choose which Sunshine
        you run. A capture/encode stack is exactly the kind of package where a Nix-built copy
        links against Nix's own graphics libraries and loses sight of the host's real GPU
        driver, so the host is better placed to decide. Set this explicitly on NixOS; leave it
        null and install via the system package manager on a hybrid host.
      '';
    };

    binary = lib.mkOption {
      type = lib.types.str;
      default = "sunshine";
      example = "/usr/bin/sunshine";
      description = ''
        Path (or bare name resolved via PATH) to the actual Sunshine binary the generated unit
        execs. Defaults to whatever `package` puts on PATH. Override to an absolute path (e.g.
        the system pacman build) on an Arch/CachyOS host: nixpkgs' Sunshine links against Nix's
        own Vulkan loader, which has no visibility into the host's real Mesa/VAAPI install --
        the same class of bug already found and worked around for nixpkgs' waypipe build (see
        forward.nix's `waypipeBinary` option and its header comment for the full diagnosis). If
        you set this to a host-provided binary, also set `package = null` to avoid installing an
        unused nixpkgs copy alongside it.
      '';
    };

    compositorUnit = lib.mkOption {
      type = lib.types.str;
      default = "niri.service";
      description = ''
        The systemd --user unit that owns the Wayland session Sunshine should capture. This
        unit's activation is ordered strictly after it (`After`), so it inherits the compositor's
        exported WAYLAND_DISPLAY from the global environment rather than guessing a value.
      '';
    };

    outputName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "HDMI-A-1";
      description = "Pin Sunshine's capture to a specific output name, or null to let it pick automatically.";
    };

    compositor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = compositorProbe.value;
      defaultText = lib.literalExpression ''
        probed from `nixdesktop.desktop.compositor` via `lib.probeFact` (nixhost's own
        `lib/facts.nix`), or `null` if nixdesktop isn't composed here or the fact doesn't resolve
      '';
      example = "niri";
      description = ''
        Which compositor `outputQueryCommand`'s default targets -- `"niri"`, `"sway"`,
        `"scroll"`, or anything else (free-form, deliberately: see this module's header for why
        this mirrors nixdesktop's own `desktop.compositor` in staying open-ended). Defaults to
        whatever `nixdesktop.desktop.compositor` resolves to on this host, so a host that already
        tells nixdesktop which compositor it runs doesn't have to repeat it here. `null` when
        nixdesktop isn't in the picture at all, or its fact doesn't resolve -- in either case
        `outputQueryCommand`'s own default falls back to a portable wlr-randr/niri/sway cascade
        (see `defaultOutputQueryCommandFor`), so leaving this unset never breaks the gate, it only
        makes the query slightly less direct. Set explicitly when nixdesktop is absent or wrong
        for this particular session.
      '';
    };

    outputQueryCommand = lib.mkOption {
      type = lib.types.str;
      default = defaultOutputQueryCommandFor cfg.compositor;
      defaultText = lib.literalExpression ''
        a niri/sway/scroll-specific `... | jq` pipeline selected by `compositor`, or a
        wlr-randr/niri/sway try-in-order cascade when `compositor` is null or unrecognised
      '';
      description = ''
        Shell command (run via `sh -c` inside the `requireOutput` gate script) whose stdout is a
        NEWLINE-SEPARATED list of the compositor's currently live output/connector names, one per
        line -- niri's connector keys, or sway/scroll's/wlr-randr's `.name` fields. Override this
        if `compositor` doesn't cover your setup, or your query needs extra flags (a non-default
        niri/sway socket, a different `WAYLAND_DISPLAY`, ...). See this module's header for the
        exact per-compositor JSON shapes this default assumes and where each was confirmed.
      '';
    };

    requireOutput = lib.mkOption {
      type = lib.types.bool;
      default = cfg.outputName != null;
      example = true;
      description = ''
        Render an `ExecStartPre` that queries the compositor's OWN live output list (via
        `outputQueryCommand`) and refuses to start Sunshine unless (a) at least one output exists
        at all, and (b) `outputName`, if pinned, is actually among them. See this module's header
        for exactly which of Sunshine's own silent fallbacks this exists to preempt.

        Defaults to `true` whenever `outputName` is pinned (a pinned name that has gone missing is
        precisely the "streams the wrong panel while logging a confident lie" failure mode this
        gate exists for) and `false` otherwise (auto-picking, unpinned, doesn't have a "wrong
        panel" failure mode to preempt -- though the zero-outputs half of the gate is still useful
        there; set this to `true` explicitly with `outputName` left `null` to get only that half).
      '';
    };

    encoder = lib.mkOption {
      type = lib.types.str;
      default = "vaapi";
      description = "Sunshine's `encoder` config value (e.g. \"vaapi\" for AMD/Intel, \"nvenc\" for NVIDIA).";
    };

    audioSink = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sink-sunshine-stereo";
      description = ''
        Sunshine's `audio_sink` — the PipeWire/PulseAudio sink it captures from. `null`, the
        default, leaves it unset and Sunshine follows whatever the system default sink is.

        FOLLOWING THE DEFAULT SINK IS A REAL FAILURE MODE, not merely untidy, which is why this
        option exists rather than being left to `extraConfig`. A capture process is not a playback
        client: the default sink answers "where should sound the user just started go", and a
        session policy daemon re-evaluates it whenever any device appears or disappears — including
        devices that are not local at all. On a machine that mirrors remote audio devices onto
        itself (a network audio fabric, a tunnelled sink), the default can be moved onto a tunnel
        pointing at ANOTHER machine, at which point the stream silently captures a sink whose audio
        is being sent somewhere else and the viewer hears nothing. Diagnosed exactly that way in one
        estate: a stream's audio died mid-playback because a laptop's headset, mirrored back over
        the fabric, won the default-sink election on the streaming host.

        Sunshine creates its own virtual sinks (`sink-sunshine-stereo`, `sink-sunshine-surround51`,
        `sink-sunshine-surround71`). Naming one here pins capture to a stable target that no policy
        daemon will move, which is the whole point.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra raw key/value pairs merged into sunshine.conf, verbatim.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mkIf (cfg.package != null) [ cfg.package ];

    # The only place `nixdesktop.desktop.compositor` being composed-but-renamed would ever
    # surface: a bare `or null` read couldn't tell that apart from nixdesktop never being
    # imported at all, and both look identical downstream (compositor stays null, the portable
    # cascade kicks in, nothing breaks) -- see this module's header and nixhost's own
    # `lib/facts.nix` for the full defect class this warning exists to report.
    warnings = compositorProbe.warnings;

    xdg.configFile."sunshine/sunshine.conf".text =
      let
        baseConfig = {
          capture = "wlr";
          encoder = cfg.encoder;
        } // lib.optionalAttrs (cfg.outputName != null) {
          output_name = cfg.outputName;
        } // lib.optionalAttrs (cfg.audioSink != null) {
          audio_sink = cfg.audioSink;
        } // cfg.extraConfig;
      in
      lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k} = ${v}") baseConfig);

    systemd.user.services.sunshine = {
      Unit = {
        Description = "Sunshine desktop/game streaming host";
        PartOf = [ "graphical-session.target" ];
        After = [ cfg.compositorUnit ];
        Requires = [ cfg.compositorUnit ];
      };
      Service = {
        # Empty when `requireOutput` is false -- Sunshine's original, ungated behavior, byte for
        # byte, for anyone who wants to opt out. See this module's header for why a failing
        # ExecStartPre already gets automatic retry/recovery from `Restart`/`RestartSec` below,
        # with no separate trigger needed.
        ExecStartPre = lib.optionals cfg.requireOutput [ "${outputGateScript}" ];
        ExecStart = cfg.binary;
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}

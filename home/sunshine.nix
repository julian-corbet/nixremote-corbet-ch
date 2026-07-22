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
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.sunshine;
in
{
  options.nixremote.sunshine = {
    enable = lib.mkEnableOption "declarative Sunshine desktop/game streaming host";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.sunshine or null;
      description = ''
        nixpkgs Sunshine package to install via home.packages, or null to install none (use
        `binary` to point at an already-installed copy instead, e.g. system pacman's build --
        see the GPU-linking caveat below).
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

    encoder = lib.mkOption {
      type = lib.types.str;
      default = "vaapi";
      description = "Sunshine's `encoder` config value (e.g. \"vaapi\" for AMD/Intel, \"nvenc\" for NVIDIA).";
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra raw key/value pairs merged into sunshine.conf, verbatim.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mkIf (cfg.package != null) [ cfg.package ];

    xdg.configFile."sunshine/sunshine.conf".text =
      let
        baseConfig = {
          capture = "wlr";
          encoder = cfg.encoder;
        } // lib.optionalAttrs (cfg.outputName != null) {
          output_name = cfg.outputName;
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
        ExecStart = cfg.binary;
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}

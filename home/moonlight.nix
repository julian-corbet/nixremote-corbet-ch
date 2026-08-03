# home/moonlight.nix — the CLIENT half of this repo's streaming pair.
#
# `home/sunshine.nix` serves a machine's Wayland session; this declares the viewer that consumes
# it. They belong in one repo because they are one mechanism seen from two ends: a stream has a
# host and a viewer, and which machine plays which role is a deployment fact, not a different
# concern. Splitting the viewer into a "media player" domain would file it by what it looks like
# rather than by what it does — it is not a local playback tool, it has no use without a remote
# host, and its settings are transport settings (bitrate, codec, latency) rather than media ones.
#
# ── WHAT THIS DELIBERATELY DOES NOT MANAGE ─────────────────────────────────────────────────────
# Moonlight's pairing state — the client certificate and key it exchanges with a host, and the
# per-host records built from it — is RUNTIME state, written by the app after a human enters a PIN
# on the host. It is not configuration and must never be rendered from Nix: overwriting it
# un-pairs every host silently, and the symptom is "it asks me to pair again", long after the
# switch that caused it. Same boundary a keyring's own secrets have. So this module installs and
# declares; it does not touch ~/.config/Moonlight Game Streaming Project/.
#
# ── PACKAGE POLICY, mirroring sunshine.nix ─────────────────────────────────────────────────────
# `package = null` by default: on a distro that already ships Moonlight, Nix should own the
# declaration and the distro should own the binary. Installing a second copy from nixpkgs on a
# foreign distro is how GPU-touching clients end up linked against the wrong Mesa — the same trap
# documented for waypipe in this repo's own forward.nix. On NixOS, set `package` explicitly.
{ lib, config, ... }:
let
  cfg = config.nixremote.moonlight;
in
{
  options.nixremote.moonlight = {
    enable = lib.mkEnableOption "the Moonlight streaming client (the viewer half of nixremote's streaming pair)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.moonlight-qt";
      description = ''
        A nixpkgs Moonlight package to install via `home.packages`, or `null` (the default) to
        install nothing and use whatever Moonlight the host already provides.

        Null is right on a distro that packages Moonlight itself: the client renders video through
        the system's own VA-API/Vulkan stack, and a nixpkgs build on a foreign distro links its own
        graphics libraries rather than the host's. On NixOS there is no such split — set this.
      '';
    };

    binary = lib.mkOption {
      type = lib.types.str;
      default = "moonlight";
      example = "/usr/bin/moonlight";
      description = ''
        Path, or bare name resolved via PATH, to the Moonlight binary. Consumed by anything that
        needs to launch the viewer (a keybind, a launcher entry); stated here so a caller never
        has to guess whether the distro named it `moonlight` or `moonlight-qt`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.mkIf (cfg.package != null) [ cfg.package ];
  };
}

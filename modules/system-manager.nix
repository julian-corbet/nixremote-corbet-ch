# modules/system-manager.nix — Arch/CachyOS plane: declare this repo's binaries into nixarch's
# package reconciler.
#
# This module says WHAT to install; nixarch's own `nixarch.packages` mechanism installs it. Import
# alongside `nixarch.systemManagerModules.packages`, or the list is computed and nothing acts on it.
#
# WHY A SEPARATE PLANE AT ALL, and why the enable flags are not shared with the home-manager
# modules: system-manager and home-manager are two independent `lib.evalModules` runs with no shared
# `config`. `nixremote.moonlight.enable` set in a home-manager profile is invisible here, so a host
# that wants both states both — the same split nixscroll's own install plane already draws.
#
# Also imports ./tools.nix: the plain catalogue-selection surface (`nixremote.transport`,
# `archPackages`/`aurPackages`) for openssh/waypipe — see that module's own header for why it is a
# separate option shape from `nixremote.install.*` below rather than folded into it. Composing
# THIS module (`systemManagerModules.default`) is what a host needs for either surface; there is
# no second module to import for the catalogue half.
{ lib, config, ... }:
let
  cfg = config.nixremote.install;
in
{
  imports = [ ./tools.nix ];

  options.nixremote.install = {
    moonlight = {
      enable = lib.mkEnableOption "installing the Moonlight streaming client on an Arch/CachyOS host via nixarch's package reconciler";

      package = lib.mkOption {
        type = lib.types.str;
        default = "moonlight-qt";
        description = ''
          Arch package providing Moonlight. Note the package and the binary disagree:
          `moonlight-qt` installs `/usr/bin/moonlight`, with no `-qt` suffix. A caller pointing
          `nixremote.moonlight.binary` at the package name would get a command that does not exist,
          which is why that option defaults to the BINARY name rather than this one.
        '';
      };
    };
  };

  config = lib.mkIf cfg.moonlight.enable {
    nixarch.packages.pacman = [ cfg.moonlight.package ];
  };
}

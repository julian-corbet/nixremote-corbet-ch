#
# nixremote's own tool catalogue, resolved — platform-neutral, installs nothing itself. Same
# shape as nixdev's modules/nixdev.nix and nixfs's modules/nixfs.nix core modules: declares WHAT
# is wanted, resolves it via ../lib/tools.nix, and publishes the platform-neutral selection that
# Arch and NixOS backends consume. See modules/system-manager.nix (names for nixarch's reconciler)
# and modules/nixos-tools.nix (nixpkgs derivations for environment.systemPackages).
#
# WHY A SEPARATE OPTION SURFACE FROM `nixremote.install.*`. That existing surface (moonlight) is
# one enable flag per app-shaped package with its own knobs (a binary override, for one). openssh
# and waypipe are not app-shaped -- there is nothing to configure beyond "install it" -- so they
# get the plain catalogue-selection shape this whole nix* family already uses for exactly that
# case, rather than growing a second `install.openssh.enable`/`install.waypipe.enable` pair that
# would just be this same mechanism re-invented per entry.
#
# `tssh` deliberately has no entry. nixremote keeps the two distinct concerns explicit: shpool
# owns PTY/session persistence, while OpenSSH owns today's byte-transparent network transport.
# A future roaming transport can replace that outer layer without replacing the session owner;
# tssh's combined model would blur the boundary this catalogue now exposes directly.
{ config, lib, ... }:
let
  cfg = config.nixremote;
  tools = import ../lib/tools.nix { };

  mkGroup = name: table: lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames table));
    default = [ ];
    description = "Which ${name} to install. Available: ${lib.concatStringsSep ", " (lib.attrNames table)}.";
  };

  selected = lib.flatten [
    (map (k: tools.transport.${k}) cfg.transport)
  ];
in
{
  options.nixremote = {
    transport = mkGroup "transport tools" tools.transport;

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The selected tools as pacman package names.

        This module cannot install them: on Arch there is no installer here to call. Feed it to
        whatever reconciler the host uses, e.g.

          nixarch.packages.pacman = config.nixremote.archPackages;
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that live in the AUR rather than an official repo, kept SEPARATE because
        `pacman -S` cannot resolve them -- it fails the whole transaction with "target not found".
        Wire them to the AUR side:

          nixarch.packages.aur = config.nixremote.aurPackages;

        shpool currently occupies this channel because Arch publishes it in the AUR rather than
        an official repository. Keeping the channels separate prevents a pacman transaction from
        failing with "target not found".
      '';
    };

    unavailableOnNixos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Selected tools with no nixpkgs equivalent. Surfaced rather than silently dropped.";
    };
  };

  config = {
    nixremote.archPackages = lib.unique (map (t: t.arch) (lib.filter (t: !(t.aur or false)) selected));
    nixremote.aurPackages = lib.unique (map (t: t.arch) (lib.filter (t: t.aur or false) selected));
    nixremote.unavailableOnNixos =
      lib.unique (map (t: t.arch) (lib.filter (t: t.nixpkgs == null) selected));
  };
}

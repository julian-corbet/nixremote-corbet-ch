#
# nixremote's own tool catalogue, resolved — platform-neutral, installs nothing itself. Same
# shape as nixdev's modules/nixdev.nix and nixfs's modules/nixfs.nix core modules: declares WHAT
# is wanted, resolves it via ../lib/tools.nix, and publishes archPackages/aurPackages for a
# platform backend to consume. See modules/system-manager.nix, the only backend that consumes it
# today (nixremote has no NixOS backend for this catalogue -- see that module's own header for
# why the Arch case is the one that matters here).
#
# WHY A SEPARATE OPTION SURFACE FROM `nixremote.install.*`. That existing surface (moonlight) is
# one enable flag per app-shaped package with its own knobs (a binary override, for one). openssh
# and waypipe are not app-shaped -- there is nothing to configure beyond "install it" -- so they
# get the plain catalogue-selection shape this whole nix* family already uses for exactly that
# case, rather than growing a second `install.openssh.enable`/`install.waypipe.enable` pair that
# would just be this same mechanism re-invented per entry.
#
# `tssh` DELIBERATELY HAS NO ENTRY HERE, and never should. Evaluated 2026-08-04 as a candidate
# alongside openssh/waypipe (it was hand-installed on both Arch hosts, same as they were) and
# rejected: its one distinctive feature over plain openssh is `tsshd`, a mosh-like UDP roaming
# mode -- and `tsshd` is installed on NEITHER host, so that feature is inert everywhere it could
# matter. Everything tsshd would provide is already solved elsewhere in this fleet: roaming by
# the WireGuard-based overlay (the overlay IP does not change when a laptop moves networks),
# session survival by tmux/zellij, file transfer by rsync/scp and the NFS/SMB shares already in
# place. Zero shell-history hits for `tssh` across fish and zsh on the laptop, for what it's
# worth as a secondary signal. Uninstalled from both hosts the same pass this catalogue was
# added; see this repo's commit history rather than a host file for that action, since neither
# host ever had a Nix declaration for it to remove.
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

        Empty for the current catalogue -- both openssh and waypipe are official-repo packages --
        but the mechanism stays for whatever this catalogue grows next.
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

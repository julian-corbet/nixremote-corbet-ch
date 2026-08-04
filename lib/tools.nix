#
# The tool catalogue: one entry per selectable binary this repo declares, naming it on each
# platform. Same family shape as nixdev's lib/tools.nix and nixfs's lib/catalogue.nix (see either
# for the fuller reasoning on why a selection resolves to a package NAME rather than a role) —
# deliberately not reproduced again here.
#
# `arch` is the pacman package. `nixpkgs` is the attribute under a nixpkgs instance, or `null`
# where none exists. `aur = true` (default false, same nixdev/nixfs convention) means the Arch
# name lives in the AUR rather than an official repo.
#
# HARD INVARIANT FOR THIS CATALOGUE: on Arch, every entry below comes from pacman and NEVER from
# nixpkgs, even though nixpkgs happens to carry an attribute for both. See
# ../modules/system-manager.nix's own header for why a second, independently-versioned copy in a
# Nix profile loses the $PATH race against the distro package and just sits unused — the same
# shadowing class nixfs's own catalogue header documents at length.
#
{ ... }:
{
  transport = {
    # Official repo, confirmed 2026-08-04 (`pacman -Si openssh` -> `Repository: cachyos-core-v3`
    # on a CachyOS host, CachyOS's own mirror of Arch's `core`). The transport everything else in
    # this repo rides on: home/forward.nix's ssh tunnel, home/rustdesk-client.nix's relay auth,
    # plain interactive login. No AUR needed.
    openssh = { arch = "openssh"; nixpkgs = "openssh"; };

    # Official repo, confirmed 2026-08-04 (`pacman -Si waypipe` -> `Repository:
    # cachyos-extra-v3`, CachyOS's own mirror of Arch's `extra`). What this repo's own
    # home/forward.nix (declarative, address-cascading Wayland app forwarding) runs on. No AUR
    # needed.
    waypipe = { arch = "waypipe"; nixpkgs = "waypipe"; };
  };
}

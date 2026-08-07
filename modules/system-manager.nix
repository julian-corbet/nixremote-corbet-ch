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
#
# `install.rustdesk` (rustdesk-bin) sits alongside `install.moonlight` here, not in the `transport`
# catalogue above: both are interactive GUI apps a human launches directly and both have their own
# home-manager-side companion module (`home/moonlight.nix`, `home/rustdesk-client.nix`) — exactly
# the "app-shaped package with its own knobs" case `transport` is deliberately NOT built for (see
# modules/tools.nix's own header). `home/rustdesk-client.nix` in particular already declines to
# manage package installation itself ("this family's real-world installs are Arch/AUR ..., never
# nixpkgs" — see that module's header), the same "host decides" split `install.moonlight` already
# occupies for Moonlight.
#
# UNLIKE moonlight-qt, rustdesk-bin has NO official-repo build: `pacman -Si rustdesk-bin` finds it
# in no repo (confirmed 2026-08-07), and the AUR RPC confirms the name only exists there
# (https://aur.archlinux.org/rpc/v5/info?arg[]=rustdesk-bin → one result, PackageBase
# "rustdesk-bin", Provides "rustdesk", upstream github.com/rustdesk/rustdesk). Feeding an AUR-only
# name into `nixarch.packages.pacman` is the "target not found" failure that aborts pacman's WHOLE
# transaction and takes every unrelated package on the host down with it — so `rustdesk.package` is
# routed to `nixarch.packages.aur` below, never `.pacman`, which is why `config` below is a
# `mkMerge` of two independent branches rather than the single `mkIf` this file used to be.
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

    rustdesk = {
      enable = lib.mkEnableOption "installing RustDesk (rustdesk-bin) on an Arch/CachyOS host via nixarch's package reconciler";

      package = lib.mkOption {
        type = lib.types.str;
        default = "rustdesk-bin";
        description = ''
          AUR package providing RustDesk (github.com/rustdesk/rustdesk) — one binary that is both
          the client and a self-hostable host/relay, the natural install-side companion to this
          repo's own `nixosModules.rustdesk` self-hosted server and `nixremote.rustdeskClient`
          (which configures an already-installed client to point at one — see that module's own
          header for why it deliberately has no `package`/`binary` option of its own). AUR-only,
          unlike `moonlight.package` above — routed to `nixarch.packages.aur`, never `.pacman`; see
          this file's own header for why that split exists and what breaks if it doesn't.

          NO SOUND NIXPKGS EQUIVALENT, hence no matching option here for a NixOS install path
          either: nixpkgs does carry a `rustdesk` attribute (same upstream project, confirmed via
          its own `meta.homepage`), but FORCING it throws by default — it pulls in `libsciter`,
          which carries an unfree license, so a plain `environment.systemPackages` entry would fail
          the build on any host that hasn't separately opted into `nixpkgs.config.allowUnfree`
          (verified live 2026-08-07 by forcing `p.drvPath`, not merely checking the attribute
          exists — the same throwing-alias trap `pkgs.ghostwriter` sprang elsewhere in this family;
          `hasAttrByPath` alone would have reported nixpkgs' `rustdesk` as perfectly fine). Not a
          default this repo should hand a caller silently, so RustDesk stays Arch-only here —
          matching `home/rustdesk-client.nix`'s own independently-stated stance on the same
          question ("Arch/AUR ..., never nixpkgs"), now with the concrete reason why.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.moonlight.enable {
      nixarch.packages.pacman = [ cfg.moonlight.package ];
    })
    (lib.mkIf cfg.rustdesk.enable {
      nixarch.packages.aur = [ cfg.rustdesk.package ];
    })
  ];
}

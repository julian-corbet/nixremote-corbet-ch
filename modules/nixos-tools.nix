# NixOS backend — resolves nixremote's selected transport tools into
# environment.systemPackages. The catalogue remains the single source of package names; Arch
# hands its names to nixarch's reconciler, while NixOS can resolve the nixpkgs attributes directly
# in the same evaluation.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixremote;
  tools = import ../lib/tools.nix { };
  wanted = lib.filter (t: t.nixpkgs != null) (map (k: tools.transport.${k}) cfg.transport);
  resolves = t: lib.hasAttrByPath (lib.splitString "." t.nixpkgs) pkgs;
  missingAttrs = lib.filter (t: !(resolves t)) wanted;
in
{
  imports = [ ./tools.nix ];

  config = {
    environment.systemPackages =
      map (t: lib.getAttrFromPath (lib.splitString "." t.nixpkgs) pkgs) (lib.filter resolves wanted);

    warnings =
      lib.optional (cfg.unavailableOnNixos != [ ]) ''
        nixremote: ${toString (builtins.length cfg.unavailableOnNixos)} selected transport tool(s) have no nixpkgs equivalent and will NOT be installed on this host: ${lib.concatStringsSep ", " cfg.unavailableOnNixos}.
      ''
      ++ lib.optional (missingAttrs != [ ]) ''
        nixremote: ${toString (builtins.length missingAttrs)} transport tool(s) name a nixpkgs attribute that does not exist in this nixpkgs: ${lib.concatStringsSep ", " (map (t: t.nixpkgs) missingAttrs)}. Fix lib/tools.nix rather than pinning around it.
      '';
  };
}

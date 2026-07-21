{
  description = "nixremote — declarative, address-cascading native Wayland app forwarding over Nix (pre-alpha scaffold)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      lib = { };

      homeManagerModules = {
        forward = ./home/forward.nix;
        fishDispatch = ./home/fish-dispatch.nix;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}

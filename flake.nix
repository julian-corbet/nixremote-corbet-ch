{
  description = "nixremote — declarative, address-cascading native Wayland app forwarding over Nix, plus a self-hosted RustDesk remote-desktop server (pre-alpha scaffold)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixhost IS an input, for exactly one thing: `lib.probeFact` (github:julian-corbet/
    # nixhost-corbet-ch, `lib/facts.nix`) -- the shared, plain-function fix for the
    # cross-namespace defensive-read defect class (a bare `config.nixfoo.bar or fallback` cannot
    # tell "nixfoo not composed here" from "nixfoo composed but `bar` moved/renamed/rejected" --
    # see nixhost's own `lib/facts.nix` header). Two modules here take it closed over as a plain
    # function argument (below), never `_module.args` -- so a consumer importing
    # `homeManagerModules.sunshine`/`forward` sees an ordinary module function and never needs to
    # know `nixhost` exists: `home/sunshine.nix`'s `config.nixdesktop.desktop.compositor` read,
    # and `home/forward.nix`'s `config.nixaudio.fabric.catalogue`/`resolvedDevices` read (see
    # forward.nix's own header for what that buys it, and what it deliberately does not). This is
    # the same shape nixscroll/nixarch already use this input for.
    nixhost = {
      url = "github:julian-corbet/nixhost-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixhost }:
    let
      lib = nixpkgs.lib;
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      pkgsFor = system: import nixpkgs { inherit system; };

      # `probeFact` closed over here, before the module system ever sees the result -- see the
      # `nixhost` input comment above. The exported value is a plain home-manager module function
      # taking the usual `{ lib, pkgs, config, ... }`; nothing about consuming it changes.
      sunshineModule = import ./home/sunshine.nix { inherit (nixhost.lib) probeFact; };
      forwardModule = import ./home/forward.nix { inherit (nixhost.lib) probeFact; };
    in
    {
      lib = { };

      homeManagerModules = {
        forward = forwardModule;
        fishDispatch = ./home/fish-dispatch.nix;
        sunshine = sunshineModule;

        # nixremote.console.<name> -- wayvnc + noVNC, the "full session in a browser" leg. Session
        # -scoped like sunshine, so home-manager, not NixOS -- see the module's own header for the
        # wlroots-only capability boundary and why it takes no `probeFact` (no cross-repo fact
        # needed: which compositor is in use doesn't change how this module talks to wayvnc).
        console = ./home/console.nix;

        # nixremote.moonlight -- the VIEWER half of the streaming pair `sunshine` above serves.
        # Filed here rather than under any media/playback domain because it is a transport client,
        # not a player: it has no use without a remote host, and its settings are bitrate, codec
        # and latency rather than anything about the media itself. Deliberately does not manage
        # Moonlight's pairing state, which is runtime, not config -- see the module's own header.
        moonlight = ./home/moonlight.nix;

        # nixremote.rustdeskClient -- points THIS machine's RustDesk client at a self-hosted
        # server (the natural client-side companion to `nixosModules.rustdesk` below). No
        # `probeFact`/nixhost dependency: unlike sunshine's compositor probe, nothing about
        # pointing a client at a server depends on which compositor is running.
        rustdeskClient = ./home/rustdesk-client.nix;

        default = self.homeManagerModules.forward;
      };

      # The one NixOS module here: a self-hosted RustDesk rendezvous+relay server is a
      # host-level, root-owned, always-on service, unlike the per-user home-manager modules
      # above (forward/fish-dispatch/sunshine) -- see the module's own header for the full shape.
      nixosModules.rustdesk = ./modules/rustdesk.nix;

      # Arch/CachyOS plane: declares this repo's binaries into nixarch's package reconciler. Kept
      # separate from the home-manager modules because system-manager and home-manager are
      # independent evaluations -- an enable flag set in one is invisible to the other, so a host
      # that wants Moonlight states it on both planes.
      systemManagerModules.default = ./modules/system-manager.nix;

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib system;
          rustdeskModule = self.nixosModules.rustdesk;
          inherit sunshineModule forwardModule;
          consoleModule = self.homeManagerModules.console;
          rustdeskClientModule = self.homeManagerModules.rustdeskClient;
          # Unlike nixdesktop (not an input -- home/sunshine.nix's own probe against it stays a
          # defensive, zero-flake-dependency read regardless of whether nixdesktop is composed),
          # nixhost genuinely IS a flake input, so `nix flake check` gets the real, locked
          # `nixhost.lib.probeFact` here, not a stub -- same reasoning as nixarch/nixscroll's own
          # checks wiring.
          probeFact = nixhost.lib.probeFact;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}

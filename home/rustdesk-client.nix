# home/rustdesk-client.nix — nixremote.rustdeskClient: declaratively point THIS machine's RustDesk
# client at a self-hosted server (`nixosModules.rustdesk`'s own hbbs+hbbr, or any RustDesk server),
# without fighting the app's own runtime-owned state in the same config file.
#
# THIS MODULE DOES NOT RENDER A SYSTEMD UNIT THE WAY sunshine.nix/console.nix DO -- RustDesk is a
# GUI client a human launches by hand, not a service this module spawns, so there is nothing to
# order against `graphical-session.target`. The only job here is seeding a config file.
#
# AND THAT CONFIG FILE IS NOT PURELY STATIC. RustDesk itself rewrites keys inside
# `~/.config/rustdesk/RustDesk2.toml` at runtime -- `nat_type`, `serial`, `local-ip-addr` are all
# learned/updated by the client itself after each connection (verified live against a real,
# already-working laptop install carrying exactly these keys alongside the ones this module
# does own). Managing the whole file the way home-manager's `xdg.configFile`/`home.file` normally
# would -- an immutable Nix-store symlink -- would make it READ-ONLY to the app: RustDesk would
# either fail to persist its own learned state, or every home-manager switch would silently
# discard it, depending on which half of that trade got taken. So this module does neither: a
# home-manager ACTIVATION script (`lib.hm.dag.entryAfter [ "writeBoundary" ]`, the standard
# ordering for anything writing into $HOME outside Nix's own managed files) parses the file if it
# exists, UPSERTS only the specific keys this module owns (`custom-rendezvous-server`,
# `relay-server`, `key`, anything in `extraOptions`) into its `[options]` table, and writes the
# result back -- every other key, and the file's other top-level fields (`rendezvous_server`,
# `nat_type`, `serial`, `unlock_pin`, `trusted_devices`, ...), pass through untouched. Idempotent:
# safe to re-run on every activation, converges rather than clobbers.
#
# NO EXPLICIT DAG ORDERING (`lib.hm.dag.entryAfter [ "writeBoundary" ]`, the usual idiom): unlike
# an activation script racing home-manager's OWN file-writing, this one has no ordering hazard to
# guard against -- no module here (or anywhere else in this family) manages
# `~/.config/rustdesk/RustDesk2.toml` declaratively, so there is no home-manager-written state this
# script could run before or after that would matter, and it creates its own target directory
# (`os.makedirs(..., exist_ok=True)`) regardless. A bare string is `home.activation`'s own accepted
# shorthand for an unordered ("anywhere") entry -- kept plain rather than reaching for
# `lib.hm.dag.*`, an extended `lib` only the real home-manager flake supplies (not plain
# `lib.evalModules`), matching this repo's own established rule of taking cross-cutting
# dependencies as explicit, closed-over function arguments rather than ambient module magic (see
# flake.nix's own `probeFact` comment for the fuller argument).
#
# DEVICE IDENTITY IS DELIBERATELY OUT OF SCOPE. `RustDesk.toml` (a SEPARATE file: the device's own
# generated Ed25519 keypair, encrypted ID, and pairing salt/password) is never touched by this
# module -- copying it between machines would give two different devices the same RustDesk
# identity, and regenerating it on an already-paired machine would force every peer that already
# trusts it to re-pair. RustDesk generates this file itself, once, on first real launch, if it does
# not already exist. Adopting an already-working install (this module's activation script running
# against a `~/.config/rustdesk` that already has both files) changes nothing about it -- only
# `RustDesk2.toml`'s `[options]` table is ever opened.
#
# PACKAGE INSTALLATION IS ALSO OUT OF SCOPE, on purpose, matching `forward`/`sunshine`/`console`'s
# own "host decides" split (see their headers for the full reasoning: a GPU/capture-adjacent
# package is exactly where a Nix-built copy can lose sight of the host's real driver stack --
# RustDesk itself is not GPU-adjacent, but the split is kept for consistency and because this
# family's real-world installs are Arch/AUR (`rustdesk-bin`), never nixpkgs). This module has no
# `package`/`binary` option at all: there is no binary for it to exec, only a config file to write.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.rustdeskClient;

  # Pure Python's `toml` package (stdlib `tomllib` is READ-ONLY, no dump/write support) round-trips
  # the file: load what's there (or start from `{}` if the file or its `[options]` table doesn't
  # exist yet -- a brand-new machine's first activation, before RustDesk has ever run), merge this
  # module's own keys into `options`, write back. No comments to preserve (RustDesk's own generated
  # file carries none, confirmed against a real live copy), so a full parse/re-serialize round trip
  # loses nothing a human authored by hand.
  pythonWithToml = pkgs.python3.withPackages (ps: [ ps.toml ]);

  # `builtins.toJSON` on a Nix string/attrset renders valid Python literal syntax too (JSON string
  # and object syntax are both strict subsets of Python's) -- the standard, escaping-safe way to
  # splice Nix values into a generated script without hand-rolling quoting.
  mergeScript = pkgs.writeText "nixremote-rustdesk-client-merge.py" ''
    import toml
    import os

    path = os.path.expanduser("~/.config/rustdesk/RustDesk2.toml")
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            data = toml.load(f)

    options = data.setdefault("options", {})
    options.update(${builtins.toJSON cfg.extraOptions})
    options["custom-rendezvous-server"] = ${builtins.toJSON cfg.server}
    options["relay-server"] = ${builtins.toJSON cfg.server}
    options["key"] = ${builtins.toJSON cfg.key}

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        toml.dump(data, f)
  '';
in
{
  options.nixremote.rustdeskClient = {
    enable = lib.mkEnableOption "declaratively pointing this machine's RustDesk client at a self-hosted server";

    server = lib.mkOption {
      type = lib.types.str;
      example = "rustdesk.example.com";
      description = ''
        Hostname (or IP) of the self-hosted RustDesk rendezvous+relay server -- rendered as BOTH
        `custom-rendezvous-server` and `relay-server` in the client's own `[options]` table (the
        same value in every deployment this module has been used against so far: one box running
        both hbbs and hbbr, e.g. via `nixosModules.rustdesk` in `modules/rustdesk.nix`).
      '';
    };

    key = lib.mkOption {
      type = lib.types.str;
      example = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      description = ''
        The server's own Ed25519 PUBLIC key (hbbs generates this on first start; find it under its
        state directory, e.g. `id_ed25519.pub`, or in the server's own startup log). This is what
        every client pins to trust the server's identity -- NOT secret the way a private key or
        password is (it's the public half, meant to be handed to every client), but get it wrong
        and nothing connects.
      '';
    };

    extraOptions = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { "allow-insecure-tls-fallback" = "Y"; };
      description = ''
        Any other `[options]` keys to upsert verbatim (RustDesk client-side toggles -- see a real
        client's own `RustDesk2.toml` for the full key vocabulary, which this module does not
        attempt to catalogue or type). Merged in alongside `custom-rendezvous-server`/
        `relay-server`/`key`, never replacing them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.nixremoteRustdeskClient = ''
      $DRY_RUN_CMD ${pythonWithToml}/bin/python3 ${mergeScript}
    '';
  };
}

# modules/rustdesk.nix — a self-hosted RustDesk server (hbbs ID/rendezvous +
# hbbr relay) as ONE podman container, via the upstream `rustdesk-server-s6`
# image. That image runs s6-overlay as its own init, supervising BOTH hbbs
# and hbbr inside the single container -- so this module produces exactly
# one systemd unit (`podman-<name>.service`) for both daemons, mirroring the
# image's own contract, not a design choice this module invents.
#
# NixOS-only, unlike this repo's home-manager modules (`forward.nix`,
# `fish-dispatch.nix`, `sunshine.nix`): a rendezvous+relay server is a
# host-level, root-owned, always-on service with its own firewall rules and
# persistent state directory, not something scoped to a user session the way
# an app-forward or a streaming host is.
#
# THE IMAGE IS BAKED INTO THE NIX CLOSURE (`pkgs.dockerTools.pullImage`), not
# pulled at container-start time: the pull happens at BUILD time (wherever
# this flake is evaluated/built, assumed to have ordinary internet access),
# producing a content-addressed store path substituted to the target host
# like any other closure output and `podman load`ed locally by the generated
# unit. A host with restricted or IPv6-only egress to container registries
# still gets a fully reproducible, zero-registry-contact-at-runtime
# deployment. Bump `imageTag` + `imageDigest` + `hash` together on upgrade
# (re-run `nix run nixpkgs#nix-prefetch-docker -- --image-name
# rustdesk/rustdesk-server-s6 --image-tag <v> --arch amd64 --os linux`).
#
# hbbs writes its own Ed25519 keypair (`id_ed25519`/`id_ed25519.pub` -- the
# SERVER PUBLIC KEY every paired client pins) and `db_v2.sqlite3` into its
# workdir, `/data` inside the container. `stateDir` binds that to a host path
# so both survive a reboot-less closure swap or a re-image; losing the
# keypair forces every already-paired client to re-pair against a "new"
# server identity.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixremote.rustdesk;

  rustdeskImage = pkgs.dockerTools.pullImage {
    imageName = cfg.image.name;
    imageDigest = cfg.image.digest;
    hash = cfg.image.hash;
    finalImageName = cfg.image.name;
    finalImageTag = cfg.image.tag;
    os = "linux";
    arch = "amd64";
  };

  containerName = "rustdesk-${cfg.name}";
in
{
  options.nixremote.rustdesk = {
    enable = lib.mkEnableOption ''
      a self-hosted RustDesk server (hbbs + hbbr) as a single rootful-podman
      container using the s6-overlay all-in-one image. Persists hbbs's
      keypair + database on `stateDir`; opens the RustDesk port block on the
      host firewall.
    '';

    name = lib.mkOption {
      type = lib.types.str;
      default = "server";
      description = ''
        Identifies this instance in the generated container/unit/state-dir
        names -- only matters if you ever need more than one RustDesk server
        declared on the same host (unusual; the default is fine otherwise).
      '';
    };

    relayHost = lib.mkOption {
      type = lib.types.str;
      example = "rustdesk.example.com";
      description = ''
        The public hostname hbbs advertises to clients as the relay (hbbr)
        endpoint -- wired into the image's own `RELAY` environment variable
        (the image starts `hbbs -r $RELAY`). No default: the image ships a
        `relay.example.com` PLACEHOLDER that silently sends every client to a
        dead relay on NAT fallback if this is left unset, so a wrong or
        missing value fails quietly (a session that falls back to relay mode
        just hangs) rather than loudly. This MUST be the value clients can
        actually resolve and reach -- it does not need to resolve AT
        CONTAINER START, since clients are the ones who resolve it, later,
        when they actually need the relay.
      '';
    };

    encryptedOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Wired into the image's `ENCRYPTED_ONLY` environment variable.
        `false` (the default, matching the image's own upstream default)
        accepts clients that have not pinned this server's public key yet --
        sessions are still end-to-end encrypted regardless; this only
        controls whether an UNPINNED client may connect at all. Set `true`
        to require every client to already have this server's key pinned,
        once you have verified every real client actually does.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/${containerName}";
      defaultText = lib.literalExpression ''"/var/lib/rustdesk-''${name}"'';
      description = ''
        Host directory bind-mounted at the image's `/data` workdir. Holds
        the hbbs Ed25519 keypair (`id_ed25519[.pub]`) and `db_v2.sqlite3`.
        Put this on whatever storage on your host actually survives a
        re-image/reprovision -- losing it regenerates the keypair and forces
        every already-paired client to re-pair. The container runs as root
        (the image's own `User` is unset), so this directory stays
        root-owned; no userns remap is needed.
      '';
    };

    image = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "rustdesk/rustdesk-server-s6";
        description = "Container image repository (without tag/digest).";
      };

      tag = lib.mkOption {
        type = lib.types.str;
        default = "1.1.15";
        description = "Upstream release tag. Bump alongside `digest`/`hash` together -- see this module's header.";
      };

      digest = lib.mkOption {
        type = lib.types.str;
        default = "sha256:dcf800fe269db58f00c92a3ae033bf609b98a0fc5e51144ce96ecf2111775453";
        description = ''
          The multi-arch manifest-index digest matching `tag` -- what you'd
          pull the image BY. Bump alongside `tag`/`hash` together.
        '';
      };

      hash = lib.mkOption {
        type = lib.types.str;
        default = "sha256-Ux9rjBs2lyqUzB++rG8bnf91r9nJ1PiOmlMuMPWTpiE=";
        description = ''
          The fixed-output hash of the resulting `amd64` image tarball (from
          `nix-prefetch-docker`'s own output -- see this module's header).
          Bump alongside `tag`/`digest` together; a mismatched hash here
          fails the build loudly (a FOD hash mismatch), never silently.
        '';
      };
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "96M";
      example = "128M";
      description = ''
        Hard cap on the server's memory, handed to BOTH podman's `--memory`
        and the generated unit's own `MemoryMax=` -- one string, two
        parsers, so it has to be spelled in the INTERSECTION of the two
        grammars: a number (a decimal fraction is allowed) with an
        UPPERCASE `K`/`M`/`G`/`T`/`P` suffix, or no suffix at all for plain
        bytes. Anything else fails the build; see the assertion in this
        module's `config` for why that is worth a hard failure.

        The uppercase is load-bearing. podman's parser (Docker's
        `RAMInBytes`) is case-INsensitive and takes `96m` happily; systemd's
        is not, and does not fail -- it drops the directive and keeps going:

            systemd[1]: podman-rustdesk-server.service:16: Invalid memory
                        limit '96m', ignoring: Invalid argument

        A lowercase value therefore delivers exactly one of the two layers
        this option promises, and it is the OUTER one that goes missing: the
        unit runs at `MemoryMax=infinity` while `systemctl status` stays
        green and `podman inspect` still reports the container's own cap, so
        every place you would think to look agrees the limit is on.

        Both parsers read `K`/`M`/`G` as base-1024, so `96M` is the same
        100663296 bytes on either side of the pair -- the two layers cap at
        the identical number, not merely at similar ones. Two forms systemd
        documents are deliberately outside the accepted set because podman
        has no equivalent for either: `E` (Docker's parser stops at `P`) and
        the percentage-of-RAM form `MemoryMax=50%` (podman: `invalid value
        for memory: invalid suffix: '%'`).

        hbbs + hbbr + s6 idle around 15-30 MB RSS on a real deployment, so
        96M is generous headroom for a small host. Lower it if this server
        shares a memory-constrained box with something more important (see
        `oomScoreAdjust` below for the other half of "never lets this be the
        thing that takes the box down").
      '';
    };

    oomScoreAdjust = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 500;
      description = ''
        `OOMScoreAdjust` on the generated container unit, or `null` to leave
        it at the kernel default. Set a high POSITIVE number (e.g. `500`) on
        a host that also runs something you never want an OOM killer
        reaching for BEFORE it reaches for this -- e.g. a VPN/mesh control
        plane sharing the same box, which is exactly why this option exists:
        it was born on a deployment co-located with a NetBird management
        server that must never be starved by a RustDesk memory spike.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open the RustDesk port block on `networking.firewall` --
        TCP 21115 (NAT-type test), TCP+UDP 21116 (hole-punch/heartbeat/ID
        registration), TCP 21117 (hbbr relay), TCP 21118/21119 (web client +
        its relay). Set `false` if you front this host with your own
        firewall mechanism instead and don't want this module touching
        `networking.firewall` at all.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # `memoryMax` is the only value in this module that crosses two parsers (podman's
    # `--memory` and systemd's `MemoryMax=`), and the two disagree about case, so it is
    # the only one that can be accepted by one half and dropped by the other. Everything
    # else the module hands to systemd is either an int (`oomScoreAdjust`) or a path.
    # Fail the build rather than warn: the failure mode this guards is a limit that LOOKS
    # applied from every angle (see the option's own description), so a warning scrolling
    # past a rebuild is not proportionate to a cap that silently is not there.
    assertions = [
      {
        assertion = builtins.match "[0-9]+(\\.[0-9]+)?[KMGTP]?" cfg.memoryMax != null;
        message = ''
          nixremote.rustdesk.memoryMax = "${cfg.memoryMax}" is not spelled in the
          intersection of the two parsers it is fed to -- podman's `--memory` and the
          generated unit's `MemoryMax=`. Use a number with an UPPERCASE K/M/G/T/P suffix,
          or no suffix for plain bytes: "96M", "1.5G", "100663296".

          A lowercase suffix is the trap this assertion exists for: podman accepts "96m"
          and caps the container, systemd rejects it and DISCARDS the whole directive
          ("Invalid memory limit '96m', ignoring: Invalid argument"), leaving the unit at
          MemoryMax=infinity behind a green `systemctl status`.
        '';
      }
    ];

    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
    };
    virtualisation.oci-containers.backend = "podman";

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root - -"
    ];

    virtualisation.oci-containers.containers.${containerName} = {
      imageFile = rustdeskImage;
      image = "${cfg.image.name}:${cfg.image.tag}";
      autoStart = true;

      volumes = [ "${cfg.stateDir}:/data" ];

      environment = {
        RELAY = cfg.relayHost;
        ENCRYPTED_ONLY = lib.boolToString cfg.encryptedOnly;
      };

      # Host networking -- on a small box this avoids netavark NAT + the
      # aardvark-dns daemon entirely and lets hbbs/hbbr bind their ports
      # straight onto the host; relay throughput also benefits from no NAT
      # hop. Exposure is governed by the host firewall (`openFirewall`).
      extraOptions = [
        "--network=host"
        "--memory=${cfg.memoryMax}"
        "--security-opt=no-new-privileges"
      ];
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 21115 21116 21117 21118 21119 ];
      allowedUDPPorts = [ 21116 ];
    };

    # oci-containers names the unit podman-<containerName>.service.
    systemd.services."podman-${containerName}" = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = cfg.stateDir;
      serviceConfig = {
        # The same string podman got as `--memory` above, now as systemd's own MemoryMax:
        # the outer belt to that inner suspender, enforced by the cgroup this unit owns
        # rather than by the container runtime that could be bypassed or restarted around
        # it. systemd's byte-unit suffixes are CASE-SENSITIVE (K/M/G/T/P/E) where podman's
        # are not, so a shared string is only actually shared if it is uppercase -- a
        # lowercase one is taken by podman and dropped by systemd, which is precisely the
        # half-applied cap the `memoryMax` assertion above refuses to build. The tests
        # assert this on the RENDERED unit text and the RENDERED podman argv, not on the
        # option value: an option-level test passes just as happily either way.
        MemoryMax = cfg.memoryMax;
      } // lib.optionalAttrs (cfg.oomScoreAdjust != null) {
        OOMScoreAdjust = cfg.oomScoreAdjust;
      };
    };
  };
}

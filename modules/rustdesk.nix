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
      default = "96m";
      description = ''
        Hard cap passed to podman `--memory` (defense-in-depth under the
        generated unit's own `MemoryMax`, set to the same value below).
        hbbs + hbbr + s6 idle around 15-30 MB RSS on a real deployment; 96m
        is generous headroom for a small host. Lower it if this server
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
        # Same value as the podman `--memory` cap above -- systemd's own MemoryMax as the
        # outer belt to that inner suspender (systemd byte-unit suffixes are case-insensitive,
        # so the same string podman takes is valid here unchanged).
        MemoryMax = cfg.memoryMax;
      } // lib.optionalAttrs (cfg.oomScoreAdjust != null) {
        OOMScoreAdjust = cfg.oomScoreAdjust;
      };
    };
  };
}

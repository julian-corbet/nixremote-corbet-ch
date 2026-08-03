# checks/default.nix — eval-time tests for nixosModules.rustdesk AND the home-manager modules
# (sunshine, console, forward). No VM, no container actually started: nothing here pulls an
# image or runs podman/wayvnc/sunshine, it only forces module evaluation (assertions + the
# config values the modules render) -- NixOS's own `eval-config.nix` for rustdesk, and a minimal
# `lib.evalModules` home-manager STUB (mirroring nixscroll's own `checks/startup-contract.nix`)
# for sunshine/console/forward, since `nix flake check` does not evaluate `homeManagerModules`
# at all -- it lists them as unchecked and moves on, so without this, sunshine's/console's/
# forward's own option wiring (the fail-closed output gate, the auth/tls coupling assertions,
# the nixaudio catalogue gate, ...) would be entirely untested by CI.
{ pkgs, lib, system, rustdeskModule, sunshineModule, consoleModule, forwardModule, rustdeskClientModule, probeFact }:

let
  check = name: ok: detail: { inherit name ok detail; };

  bareStubs = {
    fileSystems."/" = { device = "nodev"; fsType = "tmpfs"; };
    boot.loader.grub = { enable = true; devices = [ "nodev" ]; };
    networking.hostName = "example-node";
    system.stateVersion = "25.05";
  };

  evalNixosModules = modules:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    }).config;

  nixosBuildFails = modules:
    !(builtins.tryEval (builtins.seq (evalNixosModules modules).system.build.toplevel true)).success;

  sorted = lib.sort (a: b: a < b);
  serviceNames = cfg: sorted (lib.attrNames cfg.systemd.services);

  cfg-baseline = evalNixosModules [ bareStubs ];
  cfg-bare = evalNixosModules [ bareStubs rustdeskModule ];

  cfg-enabled = evalNixosModules [
    bareStubs
    rustdeskModule
    {
      nixremote.rustdesk = {
        enable = true;
        relayHost = "rustdesk.example.com";
      };
    }
  ];

  cfg-tuned = evalNixosModules [
    bareStubs
    rustdeskModule
    {
      nixremote.rustdesk = {
        enable = true;
        relayHost = "rustdesk.example.com";
        encryptedOnly = true;
        oomScoreAdjust = 500;
        openFirewall = false;
      };
    }
  ];

  results = [
    (check "rustdesk/disabled-adds-no-units"
      (serviceNames cfg-bare == serviceNames cfg-baseline)
      "a host that never enables nixremote.rustdesk must add zero systemd services vs. the identical system without the module composed at all -- got: ${builtins.toJSON (serviceNames cfg-bare)}, expected: ${builtins.toJSON (serviceNames cfg-baseline)}")

    (check "rustdesk/enabled-adds-the-container-unit"
      (builtins.elem "podman-rustdesk-server" (serviceNames cfg-enabled))
      "expected systemd.services.'podman-rustdesk-server' once enabled -- got: ${builtins.toJSON (serviceNames cfg-enabled)}")

    (check "rustdesk/enabled-sets-relay-env"
      (cfg-enabled.virtualisation.oci-containers.containers.rustdesk-server.environment.RELAY == "rustdesk.example.com")
      "RELAY environment variable did not reflect relayHost")

    (check "rustdesk/enabled-opens-firewall-by-default"
      (cfg-enabled.networking.firewall.allowedTCPPorts == [ 21115 21116 21117 21118 21119 ]
        && cfg-enabled.networking.firewall.allowedUDPPorts == [ 21116 ])
      "expected the RustDesk port block open by default -- got TCP ${builtins.toJSON cfg-enabled.networking.firewall.allowedTCPPorts}, UDP ${builtins.toJSON cfg-enabled.networking.firewall.allowedUDPPorts}")

    (check "rustdesk/openFirewall-false-opens-nothing"
      (cfg-tuned.networking.firewall.allowedTCPPorts == [ ] && cfg-tuned.networking.firewall.allowedUDPPorts == [ ])
      "openFirewall = false must leave networking.firewall untouched by this module -- got TCP ${builtins.toJSON cfg-tuned.networking.firewall.allowedTCPPorts}, UDP ${builtins.toJSON cfg-tuned.networking.firewall.allowedUDPPorts}")

    (check "rustdesk/encryptedOnly-true-sets-env-string-true"
      (cfg-tuned.virtualisation.oci-containers.containers.rustdesk-server.environment.ENCRYPTED_ONLY == "true")
      "ENCRYPTED_ONLY did not reflect encryptedOnly = true")

    (check "rustdesk/oomScoreAdjust-reaches-the-unit"
      (cfg-tuned.systemd.services."podman-rustdesk-server".serviceConfig.OOMScoreAdjust == 500)
      "oomScoreAdjust did not reach systemd.services.'podman-rustdesk-server'.serviceConfig.OOMScoreAdjust")

    (check "rustdesk/missing-relayHost-fails-the-build"
      (nixosBuildFails [ bareStubs rustdeskModule { nixremote.rustdesk.enable = true; } ])
      "expected nixremote.rustdesk.enable = true with relayHost unset to fail the build (no default -- see the option's own description), but it succeeded")
  ];

  # ── home-manager eval harness ──────────────────────────────────────────────────────────────
  #
  # `nix flake check` never evaluates `homeManagerModules` -- see this file's own header. The
  # stub below is a deliberately minimal stand-in for the home-manager options sunshine.nix and
  # console.nix write to (`home.packages`, `xdg.configFile`, `systemd.user.services`,
  # `assertions`, `warnings`) -- not an attempt to reimplement home-manager itself, matching
  # nixscroll's own `checks/startup-contract.nix` stub for the identical reason: exercise THIS
  # repo's module logic, not home-manager's.
  hmStubs = { lib, ... }: {
    options = {
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      home.activation = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
      xdg.configFile = lib.mkOption { type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything); default = { }; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user.targets = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalHm = modules: (lib.evalModules {
    modules = [ hmStubs ] ++ modules;
    specialArgs = { inherit pkgs; };
  }).config;

  assertionFailures = cfg: lib.filter (a: !a.assertion) cfg.assertions;

  # `tryEval`-wrapped so a module that fails to even EVALUATE (a hostile attrsOf key throwing out
  # of a `types.strMatching` check the moment something forces it, e.g. via `cfg.assertions`) is
  # ALSO reported as "the build fails", not left to crash this whole check file with an uncaught
  # Nix error. Every PRE-EXISTING use of `buildFailsHm` only ever hit a clean eval with a `false`
  # assertion entry (never a thrown type error), so wrapping in `tryEval` here changes nothing for
  # them -- `attempt.success` stays true and `attempt.value` carries the same
  # `assertionFailures == []` result as before.
  buildFailsHm = modules:
    let
      attempt = builtins.tryEval (
        let cfg = evalHm modules; in
        assertionFailures cfg == [ ]
      );
    in
    !(attempt.success && attempt.value);

  # ── sunshine: requireOutput/compositor/outputQueryCommand wiring ──────────────────────────
  #
  # `nixdesktop` is never composed in any of these fixtures (aside from the dedicated probe-
  # wiring group below), so `compositorProbe` resolves to state "absent" throughout -- exactly
  # the same "sibling repo not in the picture at all" case nixscroll's own fact-wiring group
  # exercises, and the reason none of these need a real nixdesktop checkout to run.
  sunshine-noPin = evalHm [ sunshineModule { nixremote.sunshine.enable = true; } ];
  sunshine-pinned = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; outputName = "HDMI-A-1"; }; } ];
  sunshine-pinned-explicitOff = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; outputName = "HDMI-A-1"; requireOutput = false; }; } ];
  sunshine-noPin-explicitOn = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; requireOutput = true; }; } ];
  sunshine-compositor-niri = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; compositor = "niri"; }; } ];
  sunshine-compositor-sway = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; compositor = "sway"; }; } ];
  sunshine-compositor-scroll = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; compositor = "scroll"; }; } ];
  sunshine-query-override = evalHm [ sunshineModule { nixremote.sunshine = { enable = true; outputQueryCommand = "echo my-custom-query"; }; } ];

  execStartPreOf = cfg: cfg.systemd.user.services.sunshine.Service.ExecStartPre;

  hmResults = [
    (check "sunshine/requireOutput-defaults-true-when-outputName-set"
      (sunshine-pinned.nixremote.sunshine.requireOutput == true && lib.length (execStartPreOf sunshine-pinned) == 1)
      "requireOutput must default to true, and ExecStartPre must carry exactly one gate entry, whenever outputName is pinned -- got requireOutput=${builtins.toJSON sunshine-pinned.nixremote.sunshine.requireOutput}, ExecStartPre=${builtins.toJSON (execStartPreOf sunshine-pinned)}")

    (check "sunshine/requireOutput-defaults-false-when-outputName-null"
      (sunshine-noPin.nixremote.sunshine.requireOutput == false && execStartPreOf sunshine-noPin == [ ])
      "requireOutput must default to false, and ExecStartPre must be empty, when outputName is left null -- got requireOutput=${builtins.toJSON sunshine-noPin.nixremote.sunshine.requireOutput}, ExecStartPre=${builtins.toJSON (execStartPreOf sunshine-noPin)}")

    (check "sunshine/requireOutput-true-with-no-outputName-still-gates-zero-output"
      (lib.length (execStartPreOf sunshine-noPin-explicitOn) == 1)
      "requireOutput = true with outputName left null must still render the zero-outputs gate -- got ExecStartPre=${builtins.toJSON (execStartPreOf sunshine-noPin-explicitOn)}")

    (check "sunshine/requireOutput-can-be-forced-off-even-with-outputName-pinned"
      (execStartPreOf sunshine-pinned-explicitOff == [ ])
      "requireOutput = false must render no gate at all, even with outputName pinned -- got ExecStartPre=${builtins.toJSON (execStartPreOf sunshine-pinned-explicitOff)}")

    (check "sunshine/compositor-unset-falls-back-to-the-portable-cascade"
      (lib.hasInfix "wlr-randr" sunshine-noPin.nixremote.sunshine.outputQueryCommand
        && sunshine-noPin.nixremote.sunshine.compositor == null)
      "with nixdesktop never composed, compositor must resolve to null and outputQueryCommand must fall back to the wlr-randr/niri/sway cascade -- got compositor=${builtins.toJSON sunshine-noPin.nixremote.sunshine.compositor}, outputQueryCommand=${sunshine-noPin.nixremote.sunshine.outputQueryCommand}")

    (check "sunshine/compositor-niri-selects-the-niri-query"
      (lib.hasInfix "niri msg --json outputs" sunshine-compositor-niri.nixremote.sunshine.outputQueryCommand
        && lib.hasInfix "keys[]" sunshine-compositor-niri.nixremote.sunshine.outputQueryCommand)
      "compositor = \"niri\" must select the niri-specific query -- got: ${sunshine-compositor-niri.nixremote.sunshine.outputQueryCommand}")

    (check "sunshine/compositor-sway-selects-the-swaymsg-query"
      (lib.hasInfix "swaymsg -t get_outputs" sunshine-compositor-sway.nixremote.sunshine.outputQueryCommand)
      "compositor = \"sway\" must select the swaymsg-specific query -- got: ${sunshine-compositor-sway.nixremote.sunshine.outputQueryCommand}")

    (check "sunshine/compositor-scroll-selects-the-scrollmsg-query"
      (lib.hasInfix "scrollmsg -t get_outputs" sunshine-compositor-scroll.nixremote.sunshine.outputQueryCommand)
      "compositor = \"scroll\" must select the scrollmsg-specific query -- got: ${sunshine-compositor-scroll.nixremote.sunshine.outputQueryCommand}")

    (check "sunshine/outputQueryCommand-override-wins-over-the-computed-default"
      (sunshine-query-override.nixremote.sunshine.outputQueryCommand == "echo my-custom-query")
      "an explicit outputQueryCommand must win outright over compositor-derived default -- got: ${sunshine-query-override.nixremote.sunshine.outputQueryCommand}")

    # ── fact-wiring: lib.probeFact proven through the real home/sunshine.nix module, the same
    # shape as nixscroll's own `nixdesktopStartupProbe` fixture group ──────────────────────────
    (check "sunshine/nixdesktop-not-composed-at-all-produces-no-warnings"
      (sunshine-noPin.warnings == [ ])
      "state (a) -- nixdesktop never composed -- must be silent, got warnings: ${builtins.toJSON sunshine-noPin.warnings}")

    (check "sunshine/nixdesktop-composed-with-real-shape-produces-no-warnings-and-resolves-compositor"
      (let
        withNixdesktop = evalHm [
          sunshineModule
          {
            options.nixdesktop.desktop.compositor = lib.mkOption { type = lib.types.str; };
            config.nixdesktop.desktop.compositor = "niri";
          }
          { nixremote.sunshine.enable = true; }
        ];
      in
      withNixdesktop.warnings == [ ] && withNixdesktop.nixremote.sunshine.compositor == "niri")
      "a faithfully-composed nixdesktop.desktop.compositor must resolve silently into sunshine's own `compositor` default")

    (check "sunshine/nixdesktop-composed-but-compositor-renamed-warns-exactly-once"
      (let
        renamed = evalHm [
          sunshineModule
          {
            options.nixdesktop.desktop.compositorRenamed = lib.mkOption { type = lib.types.str; default = "niri"; };
          }
          { nixremote.sunshine.enable = true; }
        ];
      in
      lib.length renamed.warnings == 1
      && lib.hasInfix "nixdesktop.desktop.compositor" (lib.head renamed.warnings)
      && renamed.nixremote.sunshine.compositor == null)
      "state (c) -- nixdesktop composed but the specific leaf renamed -- must warn exactly once naming the option, and compositor must still fall back to null rather than error")
  ];

  # ── console: attrsOf wiring, unit shape, and the wayvnc auth/tls coupling assertion ────────
  console-basic = evalHm [ consoleModule { nixremote.console.office = { enable = true; }; } ];
  console-disabled = evalHm [ consoleModule { nixremote.console.office = { enable = false; }; } ];
  console-web = evalHm [ consoleModule { nixremote.console.office = { enable = true; web = { enable = true; package = pkgs.novnc; }; }; } ];

  consoleServiceNames = cfg: lib.attrNames cfg.systemd.user.services;

  # ── console: rendered command TEXT, not just option/attribute shape ───────────────────────
  #
  # `ExecStart`/`ExecStartPre` are Nix strings holding a `pkgs.writeShellScript` OUTPUT PATH, not
  # the argv itself -- the actual `wayvnc ...` invocation only exists inside the built script
  # file. `builtins.readFile` on that string (it carries derivation context from the
  # `"${wayvncStartScript ...}"` interpolation) builds the tiny script via IFD and returns its
  # real text, which is the only way to catch the class of bug that shipped here: every one of
  # the 30 pre-existing checks asserted option VALUES or unit ATTRIBUTE shape, none of them ever
  # looked at the rendered TEXT, so a config path wrapped in the wrong quote style and a stray
  # `--` swallowing every real CLI argument both evaluated clean and passed 30/30 while the
  # generated unit could not actually start (see console.nix's `wayvncStartScript` header for the
  # concrete defects this now catches directly).
  consoleUnitText = cfg: name: builtins.readFile cfg.systemd.user.services."nixremote-console-${name}".Service.ExecStart;
  consolePreText = cfg: name: builtins.readFile (lib.head cfg.systemd.user.services."nixremote-console-${name}".Service.ExecStartPre);
  # Same idea as `consoleUnitText`, for the noVNC/websockify `-web` unit -- see console.nix's
  # `webStartScript` for the `--vnc` bind-vs-connect-address defect this now reads real rendered
  # text for, matching the exact shape the wayvnc leg (`consoleUnitText`) was already burned on.
  webUnitText = cfg: name: builtins.readFile cfg.systemd.user.services."nixremote-console-${name}-web".Service.ExecStart;

  # Deliberately NON-default address/port: wayvnc's own hardcoded fallback (DEFAULT_ADDRESS
  # 127.0.0.1 / DEFAULT_PORT 5900, src/main.c) is numerically IDENTICAL to this module's own
  # option defaults, so a fixture left at the defaults would still "pass" a real-argument check
  # even with the `--`-swallows-everything bug in place -- only a non-default value proves the
  # configured address/port actually reached wayvnc rather than silently falling back.
  console-custom-bind = evalHm [ consoleModule { nixremote.console.office = { enable = true; address = "0.0.0.0"; port = 5901; }; } ];

  # Instance deliberately named "vnc-a" -- NOT "office" like every other fixture -- so the
  # rendered runtime-dir/unit-name literal ("nixremote-console-vnc-a") itself contains the raw
  # substring "-a". This is what proves the output-pinned check below is anchored on the actual
  # argv token (" -a ", space-delimited) rather than a naive whole-text `lib.hasInfix "-a"` scan:
  # the old, unanchored check only ever passed because every fixture happened to be named
  # "office" (no "-a" substring anywhere in "nixremote-console-office"); renamed to "vnc-a", the
  # old check's `!(lib.hasInfix "-a" text)` half would have INVERTED (failed) purely from this
  # name leaking into the config-path literal, with zero relation to whether wayvnc's own -a flag
  # was ever rendered.
  console-output-pinned = evalHm [ consoleModule { nixremote.console."vnc-a" = { enable = true; output = "HDMI-A-1"; }; } ];

  # ── console: web.connectAddress (bind vs. connect address) rendered TEXT ──────────────────
  #
  # See console.nix's header/`webStartScript` for the real bug this proves fixed: `--vnc` used to
  # be handed `address` (the BIND address) straight, so `address = "0.0.0.0"` rendered
  # `--vnc "0.0.0.0:PORT"`, telling websockify to CONNECT to a wildcard bind address -- not a
  # valid dial target. `web.connectAddress` is a distinct option/default now; these three fixtures
  # exercise its three cases (wildcard bind -> loopback connect, specific bind -> same address,
  # explicit override wins).
  console-web-wildcard-bind = evalHm [
    consoleModule
    { nixremote.console.office = { enable = true; address = "0.0.0.0"; web = { enable = true; package = pkgs.novnc; }; }; }
  ];
  console-web-specific-bind = evalHm [
    consoleModule
    { nixremote.console.office = { enable = true; address = "192.168.50.7"; web = { enable = true; package = pkgs.novnc; }; }; }
  ];
  console-web-connect-override = evalHm [
    consoleModule
    {
      nixremote.console.office = {
        enable = true;
        address = "0.0.0.0";
        web = { enable = true; package = pkgs.novnc; connectAddress = "10.0.0.5"; };
      };
    }
  ];

  console-auth-username-optional = evalHm [
    consoleModule
    {
      nixremote.console.office = {
        enable = true;
        auth = { enable = true; passwordFile = "/p"; };
        tls = { enable = true; certFile = "/c"; keyFile = "/k"; };
      };
    }
  ];

  # A parked (enable = false) instance with an otherwise-INVALID shape (auth enabled, tls not,
  # and a package set) -- must be a complete no-op: no failed assertions, no installed package.
  # See console.nix's `assertions`/`home.packages` header for why these two need the same
  # `c.enable` guard `mkUnitsFor` already had.
  console-disabled-invalid = evalHm [
    consoleModule
    { nixremote.console.office = { enable = false; auth.enable = true; package = pkgs.hello; }; }
  ];

  # ── rustdeskClient: activation-script rendering, not just option shape ────────────────────────
  #
  # Reads the ACTUAL rendered Python merge-script text the same way `consoleUnitText`/`consolePreText`
  # above read real ExecStart/ExecStartPre text -- `home.activation.nixremoteRustdeskClient` is a
  # bare string carrying `pkgs.writeText`'s OWN store path interpolated into a shell one-liner
  # (`$DRY_RUN_CMD <python> <script-path>`), so `builtins.readFile` on the SCRIPT PATH inside that
  # string (extracted below) is what actually forces the Python file to build and reads its real
  # content, not merely the option's Nix-level value.
  rustdeskClient-disabled = evalHm [ rustdeskClientModule ];
  rustdeskClient-basic = evalHm [
    rustdeskClientModule
    { nixremote.rustdeskClient = { enable = true; server = "rustdesk.example.org"; key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }; }
  ];
  rustdeskClient-extra = evalHm [
    rustdeskClientModule
    {
      nixremote.rustdeskClient = {
        enable = true;
        server = "rustdesk.example.com";
        key = "some-key==";
        extraOptions."allow-insecure-tls-fallback" = "Y";
      };
    }
  ];

  # The rendered activation string is `$DRY_RUN_CMD <python-bin> <script-store-path>` -- the
  # trailing whitespace-delimited token is the script's own store path, extracted by splitting on
  # spaces/newlines and taking the last non-empty element (mirrors how a shell would parse it).
  rustdeskClientScriptText = cfg:
    let
      activation = cfg.home.activation.nixremoteRustdeskClient;
      tokens = lib.filter (s: s != "") (lib.splitString " " (lib.replaceStrings [ "\n" ] [ " " ] activation));
      scriptPath = lib.last tokens;
    in
    builtins.readFile scriptPath;

  # ── forward: nixaudio catalogue-informed audio resolution ──────────────────────────────────
  #
  # `nixaudio` is never a real flake input here (`forward.nix` takes `probeFact` as a plain
  # function argument -- see flake.nix), so these fixtures compose a MINIMAL stand-in
  # `nixaudio.fabric.catalogue`/`nixaudio.resolvedDevices` option pair directly into the hm-stub
  # tree -- the same shape sunshine's own `nixdesktop.desktop.compositor`-renamed fixture uses
  # above, so `probeFact`'s presence test (`config ? nixaudio`) sees a real composed namespace
  # without needing nixaudio's own flake.
  #
  # NOT found by derivation `.name` -- verified live (not assumed) that `writeShellScriptBin`
  # SANITISES "@" out of the derivation's own `name` attribute for the store path ("waypipe@x"
  # -> "waypipe-x"), while the FILE actually placed at `$out/bin/` keeps the literal "@" (it is
  # a plain path-inside-the-output string, unrelated to store-path name sanitisation). So this
  # looks for the real, literal `bin/${scriptName}` file across every package instead -- exact,
  # and it is also the only test of "is this really what ends up importable on $PATH", which a
  # `.name`-based lookup would not have been. Reading the OUTPUT (not the Nix option value) is
  # what proves the RENDERED shell text, not just that the module evaluated (see this file's own
  # header on why `console/*` already reads real script text the same way).
  forwardWrapperText = cfg: scriptName:
    let
      matches = builtins.filter (p: builtins.pathExists "${p}/bin/${scriptName}") cfg.home.packages;
    in
    if matches == [ ]
    then throw "forward check fixture: no package in home.packages provides bin/${scriptName} (got: ${builtins.toJSON (map (p: p.name or "?") cfg.home.packages)})"
    else builtins.readFile "${builtins.head matches}/bin/${scriptName}";

  # nixaudio NEVER composed: state (a), silent, and the wrapper must render the ORIGINAL
  # string-matching implementation unconditionally -- see forward.nix's header for why that
  # fallback exists at all.
  forward-noAudio = evalHm [
    forwardModule
    { nixremote.forward.testpeer = { addresses = [{ address = "10.0.0.5"; }]; }; }
  ];
  forward-audioFallback = evalHm [
    forwardModule
    { nixremote.forward.testpeer = { addresses = [{ address = "10.0.0.5"; }]; audio.localAddress = "192.168.1.14"; }; }
  ];

  # nixaudio composed with ONE declared local device ("hyperx"): state (b)/resolved, exercises
  # the catalogue-gated path with a real case arm.
  forward-audioCatalogue = evalHm [
    forwardModule
    {
      options.nixaudio.fabric.catalogue = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      options.nixaudio.resolvedDevices = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      config.nixaudio.fabric.catalogue.hyperx = {
        origin = "local"; peer = null; device = "hyperx";
        description = "HyperX Cloud III S Wireless headset"; known = "declared";
      };
      config.nixaudio.resolvedDevices = [
        { name = "hyperx"; description = "HyperX Cloud III S Wireless headset"; source = "usb"; match = { "device.vendor.id" = "0x03f0"; }; }
      ];
    }
    { nixremote.forward.testpeer = { addresses = [{ address = "10.0.0.5"; }]; audio.localAddress = "192.168.1.14"; }; }
  ];

  # nixaudio composed but `fabric.catalogue` renamed underneath it: state (c)/unresolved --
  # must still render the GATED shape (nixaudioComposed stays true, since the presence test is
  # only the top-level "nixaudio" attribute) with an EMPTY device table (falls back to the
  # probe's own `fallback = { }`), and must warn exactly once.
  forward-audioRenamed = evalHm [
    forwardModule
    {
      options.nixaudio.fabric.catalogueRenamed = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      options.nixaudio.resolvedDevices = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
    }
    { nixremote.forward.testpeer = { addresses = [{ address = "10.0.0.5"; }]; audio.localAddress = "192.168.1.14"; }; }
  ];

  # Two peers, two DISTINCT localAddress values, nixaudio absent: proves nothing about the
  # rendered resolution is shared/cached across peers -- each wrapper carries its own
  # independent destination, never a single per-machine constant (the central invariant this
  # task's design doc states as "audio follows its windows around", not the machine).
  forward-twoPeers = evalHm [
    forwardModule
    {
      nixremote.forward = {
        peera = { addresses = [{ address = "10.0.0.1"; }]; audio.localAddress = "192.168.1.10"; };
        peerb = { addresses = [{ address = "10.0.0.2"; }]; audio.localAddress = "192.168.1.20"; };
      };
    }
  ];

  forwardResults = [
    (check "forward/audio-disabled-by-default-renders-no-resolve-block-at-all"
      (!(lib.hasInfix "pactl get-default-sink" (forwardWrapperText forward-noAudio "waypipe@testpeer")))
      "audio.localAddress left null (the default) must render no sink-resolution code at all -- got: ${forwardWrapperText forward-noAudio "waypipe@testpeer"}")

    (check "forward/nixaudio-absent-falls-back-to-the-original-string-match-unchanged"
      (let text = forwardWrapperText forward-audioFallback "waypipe@testpeer"; in
      lib.hasInfix "pactl get-default-sink" text
      && lib.hasInfix "Tunnel to tcp:192.168.1.14:4713/$local_sink" text
      && lib.hasInfix "PULSE_SINK=$fabric_sink" text
      && !(lib.hasInfix "nixaudio_device" text))
      "with nixaudio never composed, the wrapper must render EXACTLY the original raw-name SSH+grep match (no 'nixaudio_device' catalogue machinery anywhere) -- got: ${forwardWrapperText forward-audioFallback "waypipe@testpeer"}")

    (check "forward/nixaudio-composed-gates-through-the-catalogue-before-the-fabric-lookup"
      (let text = forwardWrapperText forward-audioCatalogue "waypipe@testpeer"; in
      # `lib.escapeShellArg` only adds quotes when the content actually needs them (verified
      # live: a bare alnum word like "hyperx" renders unquoted, "HyperX Cloud III..." with
      # spaces renders single-quoted) -- these expectations match the REAL rendered output, not
      # an assumption that every escaped value is always quoted.
      lib.hasInfix "'HyperX Cloud III S Wireless headset')" text
      && lib.hasInfix "nixaudio_device=hyperx" text
      && lib.hasInfix "nixaudio_source=usb" text)
      "with nixaudio composed and a matching local device declared, the wrapper must contain a case arm naming that device's nixaudio description and stable name -- got: ${forwardWrapperText forward-audioCatalogue "waypipe@testpeer"}")

    (check "forward/nixaudio-composed-still-reaches-PULSE_SINK-through-the-gate"
      (let text = forwardWrapperText forward-audioCatalogue "waypipe@testpeer"; in
      lib.hasInfix "Tunnel to tcp:192.168.1.14:4713/$local_sink" text
      && lib.hasInfix "PULSE_SINK=$fabric_sink" text)
      "the catalogue gate must still fall through to the SAME live SSH+grep fabric lookup and assign PULSE_SINK from its result (a live shell variable, never a value baked in at build time) -- got: ${forwardWrapperText forward-audioCatalogue "waypipe@testpeer"}")

    (check "forward/nixaudio-renamed-leaf-warns-exactly-once-naming-the-option"
      (lib.length forward-audioRenamed.warnings == 1
        && lib.hasInfix "nixaudio.fabric.catalogue" (lib.head forward-audioRenamed.warnings))
      "nixaudio composed but fabric.catalogue renamed underneath it, with a peer actually consuming audio resolution, must warn exactly once naming the unresolved option path -- got: ${builtins.toJSON forward-audioRenamed.warnings}")

    (check "forward/nixaudio-renamed-leaf-still-renders-the-gated-shape-with-an-empty-table"
      (let text = forwardWrapperText forward-audioRenamed "waypipe@testpeer"; in
      lib.hasInfix ''case "$local_desc" in'' text && !(lib.hasInfix "nixaudio_device=hyperx" text))
      "a renamed (unresolved) leaf must still take the GATED code path (nixaudioComposed stays true off state != \"absent\") but with no device case arms, since the probe's own fallback ({ }) is empty -- got: ${forwardWrapperText forward-audioRenamed "waypipe@testpeer"}")

    (check "forward/two-peers-render-two-independent-destinations-not-one-shared-one"
      (let
        textA = forwardWrapperText forward-twoPeers "waypipe@peera";
        textB = forwardWrapperText forward-twoPeers "waypipe@peerb";
      in
      lib.hasInfix "192.168.1.10" textA && !(lib.hasInfix "192.168.1.20" textA)
      && lib.hasInfix "192.168.1.20" textB && !(lib.hasInfix "192.168.1.10" textB))
      "two peers forwarded to at once must each resolve audio against THEIR OWN localAddress, never a single machine-wide destination -- got peera: ${forwardWrapperText forward-twoPeers "waypipe@peera"}, peerb: ${forwardWrapperText forward-twoPeers "waypipe@peerb"}")

    (check "forward/no-audio-consumer-keeps-probeFact-warnings-silent"
      (forward-noAudio.warnings == [ ])
      "no peer here sets audio.localAddress, so warnings must stay empty regardless (audioConsumed is false) -- got: ${builtins.toJSON forward-noAudio.warnings}")
  ];
in
{
  eval-tests =
    let
      allResults = results ++ hmResults ++ forwardResults ++ [
        (check "console/disabled-instance-adds-no-units"
          (consoleServiceNames console-disabled == [ ])
          "enable = false must add zero systemd --user units -- got: ${builtins.toJSON (consoleServiceNames console-disabled)}")

        (check "console/disabled-instance-with-an-invalid-shape-does-not-fail-the-build"
          (!(buildFailsHm [
            consoleModule
            { nixremote.console.office = { enable = false; auth.enable = true; package = pkgs.hello; }; }
          ]))
          "enable = false must be a complete no-op, even with an otherwise-invalid auth/tls shape -- assertions must be guarded by c.enable the same way mkUnitsFor already is, but evaluation failed")

        (check "console/disabled-instance-does-not-install-its-package"
          (console-disabled-invalid.home.packages == [ ])
          "enable = false with package set must install nothing -- home.packages must be guarded by c.enable the same way mkUnitsFor already is -- got: ${builtins.toJSON (builtins.map (p: p.pname or p.name or "?") console-disabled-invalid.home.packages)}")

        (check "console/enabled-instance-adds-the-wayvnc-unit-ordered-on-graphical-session"
          (let unit = console-basic.systemd.user.services."nixremote-console-office"; in
          unit.Unit.PartOf == [ "graphical-session.target" ]
          && unit.Unit.After == [ "graphical-session.target" ]
          && lib.length unit.Service.ExecStartPre == 1)
          "the base wayvnc unit must be PartOf/After graphical-session.target and carry exactly one ExecStartPre (the runtime-config renderer) -- got: ${builtins.toJSON (console-basic.systemd.user.services."nixremote-console-office" or null)}")

        (check "console/web-disabled-by-default-adds-no-web-unit"
          (!(lib.elem "nixremote-console-office-web" (consoleServiceNames console-basic)))
          "web.enable defaults to false and must add no '-web' unit -- got: ${builtins.toJSON (consoleServiceNames console-basic)}")

        (check "console/web-enabled-adds-the-web-unit-depending-on-the-base-unit"
          (let unit = console-web.systemd.user.services."nixremote-console-office-web"; in
          lib.elem "nixremote-console-office.service" unit.Unit.Requires
          && lib.elem "nixremote-console-office.service" unit.Unit.After)
          "web.enable = true must add a '-web' unit that Requires/After's the base wayvnc unit -- got: ${builtins.toJSON (console-web.systemd.user.services."nixremote-console-office-web" or null)}")

        (check "console/web-enabled-without-a-package-fails-the-build"
          (buildFailsHm [ consoleModule { nixremote.console.office = { enable = true; web.enable = true; }; } ])
          "web.enable = true with web.package left null must fail evaluation (asserted), but it evaluated cleanly")

        (check "console/auth-enabled-without-password-file-fails-the-build"
          (buildFailsHm [ consoleModule { nixremote.console.office = { enable = true; auth.enable = true; tls.enable = true; tls.certFile = "/c"; tls.keyFile = "/k"; }; } ])
          "auth.enable = true with passwordFile left null must fail evaluation (wayvnc's own enable_auth requires it), but it evaluated cleanly")

        (check "console/auth-enabled-with-only-username-set-still-fails-the-build"
          (buildFailsHm [ consoleModule { nixremote.console.office = { enable = true; auth = { enable = true; usernameFile = "/u"; }; tls.enable = true; tls.certFile = "/c"; tls.keyFile = "/k"; }; } ])
          "usernameFile set but passwordFile left null must still fail evaluation -- passwordFile is the one auth.* file wayvnc actually requires")

        (check "console/auth-enabled-without-usernameFile-evaluates-cleanly-username-is-optional"
          (!(buildFailsHm [
            consoleModule
            {
              nixremote.console.office = {
                enable = true;
                auth = { enable = true; passwordFile = "/p"; };
                tls = { enable = true; certFile = "/c"; keyFile = "/k"; };
              };
            }
          ]))
          "wayvnc.scd documents username as optional (defaults to an empty string) -- auth.enable = true with passwordFile set but usernameFile left null must evaluate with no failed assertions, but it did not")

        (check "console/tls-enabled-without-files-fails-the-build"
          (buildFailsHm [ consoleModule { nixremote.console.office = { enable = true; tls.enable = true; auth.enable = true; auth.usernameFile = "/u"; auth.passwordFile = "/p"; }; } ])
          "tls.enable = true with certFile/keyFile left null must fail evaluation, but it evaluated cleanly")

        (check "console/auth-without-tls-fails-the-build-wayvnc-requires-both-together"
          (buildFailsHm [ consoleModule { nixremote.console.office = { enable = true; auth = { enable = true; usernameFile = "/u"; passwordFile = "/p"; }; }; } ])
          "auth.enable = true with tls.enable left false must fail evaluation -- wayvnc's own enable_auth requires certificate_file/private_key_file too (see console.nix's header), so half-enabling must not silently evaluate")

        (check "console/auth-and-tls-together-with-all-files-evaluates-cleanly"
          (!(buildFailsHm [
            consoleModule
            {
              nixremote.console.office = {
                enable = true;
                auth = { enable = true; usernameFile = "/u"; passwordFile = "/p"; };
                tls = { enable = true; certFile = "/c"; keyFile = "/k"; };
              };
            }
          ]))
          "auth and tls enabled together, with all four files set, is the one valid paired configuration and must evaluate with no failed assertions")

        (check "console/multiple-instances-render-independently-named-units"
          (let
            multi = evalHm [
              consoleModule
              {
                nixremote.console = {
                  office = { enable = true; };
                  lab = { enable = true; output = "DP-2"; };
                };
              }
            ];
          in
          lib.elem "nixremote-console-office" (consoleServiceNames multi)
          && lib.elem "nixremote-console-lab" (consoleServiceNames multi))
          "two distinct nixremote.console.<name> entries must render two distinctly-named unit sets, not collide")

        # ── rendered command TEXT (see `consoleUnitText`/`consolePreText` above for why this is
        # the layer the previous 30 checks never reached) ──────────────────────────────────────

        (check "console/exec-start-config-path-is-double-quoted-and-unexpanded"
          (let text = consoleUnitText console-basic "office"; in
          lib.hasInfix ''-C "$XDG_RUNTIME_DIR/"nixremote-console-office"/config"'' text
          && !(lib.hasInfix "-C '$XDG_RUNTIME_DIR" text))
          "the rendered ExecStart must pass -C a path built from a DOUBLE-quoted \"$XDG_RUNTIME_DIR/\" segment (expands at runtime) -- lib.escapeShellArg's SINGLE quotes on the whole thing would pass the variable name literally and wayvnc would hard-exit; the name fragment in between is deliberately its own lib.escapeShellArg-passed segment (console.nix's `configPath`, the second-layer defense against an injectable instance name -- see consoleModule's `_instanceName`) -- got: ${consoleUnitText console-basic "office"}")

        (check "console/exec-start-has-no-double-dash-separator"
          (!(lib.hasInfix " -- " (consoleUnitText console-basic "office")))
          "the rendered ExecStart must not contain a bare '--' before address/port -- wayvnc's option parser diverts everything after '--' to remaining_argv, which main.c never reads, silently discarding the configured address/port -- got: ${consoleUnitText console-basic "office"}")

        (check "console/exec-start-carries-the-configured-non-default-address-and-port"
          (let text = consoleUnitText console-custom-bind "office"; in
          lib.hasInfix "0.0.0.0" text && lib.hasInfix "5901" text && !(lib.hasInfix " -- " text))
          "address = \"0.0.0.0\"/port = 5901 (deliberately non-default, since wayvnc's own DEFAULT_ADDRESS/DEFAULT_PORT equal this module's defaults) must appear as real trailing arguments in ExecStart -- got: ${consoleUnitText console-custom-bind "office"}")

        # Anchored on the actual argv TOKEN (" -a "/" -o ", space-delimited on both sides), not a
        # naive whole-text `lib.hasInfix "-a"` scan -- see `console-output-pinned`'s own comment
        # (renamed to instance "vnc-a" for exactly this reason) for why the old, unanchored form
        # was fragile: the rendered runtime-dir/unit-name literal is built from the instance's OWN
        # name, so any fixture whose name happens to contain the substring "-a" (as "vnc-a" now
        # deliberately does) would make a naive scan see "-a" regardless of which flag wayvnc
        # actually got.
        (check "console/output-null-renders-desktop-capture-all-outputs"
          (let text = consoleUnitText console-basic "office"; in
          lib.hasInfix " -a " text && !(lib.hasInfix " -o " text))
          "output = null (the default) must render wayvnc 0.10.1's -a/--desktop (capture ALL outputs, matching this module's 'full session in a browser' purpose) as its own argv token, not omit the flag -- got: ${consoleUnitText console-basic "office"}")

        (check "console/output-pinned-renders-dash-o-and-not-dash-a"
          (let text = consoleUnitText console-output-pinned "vnc-a"; in
          lib.hasInfix " -o HDMI-A-1 " text && !(lib.hasInfix " -a " text))
          "output = \"HDMI-A-1\" must render -o HDMI-A-1 as its own argv token and must NOT also render a bare ' -a ' token (wayvnc rejects both together) -- this fixture's instance is deliberately named \"vnc-a\" (see its own definition above) specifically so the rendered path literal 'nixremote-console-vnc-a' contains the raw substring '-a' without a real -a/--desktop flag ever being rendered, proving the anchored ' -a ' check does not false-positive on it the way an unanchored lib.hasInfix \"-a\" scan would have -- got: ${consoleUnitText console-output-pinned "vnc-a"}")

        (check "console/exec-start-pre-reads-secrets-via-a-checked-variable-not-inline-cat"
          (let text = consolePreText console-auth-username-optional "office"; in
          lib.hasInfix "read_secret" text && !(lib.hasInfix ''"$(cat '' text))
          "the render-config script must assign a secret read to a variable (and check it) before using it, never inline `\"$(cat ...)\"` as another command's argument -- under set -e that swallows a failed read as an EMPTY secret instead of aborting -- got: ${consolePreText console-auth-username-optional "office"}")

        (check "console/exec-start-pre-omits-the-username-line-when-usernameFile-is-unset"
          (!(lib.hasInfix "username=" (consolePreText console-auth-username-optional "office")))
          "usernameFile left null (auth.enable = true, only passwordFile set) must render no username= line at all -- got: ${consolePreText console-auth-username-optional "office"}")

        # ── EVERY default-shape (auth.enable/tls.enable both false) fixture's ExecStartPre must
        # actually BUILD -- this is the coverage gap that hid the empty-command-group blocker:
        # `consolePreText` was previously only ever called against `console-auth-username-optional`
        # (auth+tls both true, so its `{ ... }` command group was never empty), so the
        # `pkgs.writeShellScript` `bash -n` checkPhase failure on the far more common
        # auth=false/tls=false shape went completely untested. `builtins.readFile` here forces the
        # real IFD build of each one; a `bash -n` syntax error surfaces as a build failure of this
        # whole derivation, not a quiet `ok = false` entry -- reverting console.nix's `:` no-op
        # filler makes `nix build` on this check FAIL TO EVALUATE AT ALL rather than merely report
        # a failed check, which is still a clear, unambiguous red signal.
        (check "console/pre-script-builds-for-console-basic-default-shape"
          (lib.hasInfix "install -d -m 0700" (consolePreText console-basic "office"))
          "the default-shape (auth.enable/tls.enable both false, this module's documented minimal usage) render-config script must actually BUILD -- got: ${consolePreText console-basic "office"}")

        (check "console/pre-script-builds-for-console-web"
          (lib.hasInfix "install -d -m 0700" (consolePreText console-web "office"))
          "web.enable = true alone (auth/tls both still false) must not change whether the render-config script builds -- got: ${consolePreText console-web "office"}")

        (check "console/pre-script-builds-for-console-custom-bind"
          (lib.hasInfix "install -d -m 0700" (consolePreText console-custom-bind "office"))
          "a non-default address/port (auth/tls both still false) must not change whether the render-config script builds -- got: ${consolePreText console-custom-bind "office"}")

        (check "console/pre-script-builds-for-console-output-pinned"
          (lib.hasInfix "install -d -m 0700" (consolePreText console-output-pinned "vnc-a"))
          "a pinned output (auth/tls both still false) must not change whether the render-config script builds -- got: ${consolePreText console-output-pinned "vnc-a"}")

        # ── web.connectAddress: bind address vs. connect address (real rendered TEXT) ─────────
        #
        # See console.nix's header/`webStartScript` for the bug this closes: `--vnc` used to be
        # handed `address` (the BIND address) straight through, so a wildcard bind rendered a
        # `--vnc` argument websockify could never actually dial.
        (check "console/web-connect-address-defaults-to-loopback-when-bind-is-wildcard"
          (let text = webUnitText console-web-wildcard-bind "office"; in
          lib.hasInfix "127.0.0.1:5900" text && !(lib.hasInfix "0.0.0.0:5900" text))
          "address = \"0.0.0.0\" (a BIND wildcard) must make web.connectAddress default to 127.0.0.1 -- websockify's --vnc DIALS this value, and 0.0.0.0 is not a valid dial target the way it is a valid bind target -- got: ${webUnitText console-web-wildcard-bind "office"}")

        (check "console/web-connect-address-defaults-to-the-specific-bind-address-otherwise"
          (let text = webUnitText console-web-specific-bind "office"; in
          lib.hasInfix "192.168.50.7:5900" text)
          "a specific (non-wildcard) address must make web.connectAddress default to that same address verbatim -- a bind IP configured on this host's own interface is reachable by dialing that exact address from the same host -- got: ${webUnitText console-web-specific-bind "office"}")

        (check "console/web-connect-address-explicit-override-wins"
          (let text = webUnitText console-web-connect-override "office"; in
          lib.hasInfix "10.0.0.5:5900" text && !(lib.hasInfix "0.0.0.0:5900" text) && !(lib.hasInfix "127.0.0.1:5900" text))
          "an explicit web.connectAddress must win outright over the computed default, even with address left at a wildcard bind -- got: ${webUnitText console-web-connect-override "office"}")

        # ── PRIMARY defense: the attrsOf key itself is type-constrained, rejected at eval time ──
        #
        # `_instanceName`'s `types.strMatching "[A-Za-z0-9_-]+"` (consoleModule, console.nix) is
        # what makes each of these throw. Mutation-proof: loosening that type back to a bare
        # `lib.types.str` makes every one of these three checks go from `ok = true` back to
        # `ok = false` (the hostile name sails through, `buildFailsHm` returns false) -- verified
        # by hand against a temporarily-reverted copy of console.nix, not asserted here.
        (check "console/hostile-instance-name-with-a-backtick-is-rejected-at-eval-time"
          (buildFailsHm [
            consoleModule
            { nixremote.console."office`touch /tmp/pwned`" = { enable = true; }; }
          ])
          "an attrsOf key containing a backtick must be REJECTED at eval time -- this exact key is spliced into real double-quoted shell context in renderConfigScript's out_dir=/echo lines and wayvncStartScript's configPath, where a backtick still expands and executes at every service start (proven with a real touch(1) side effect while diagnosing this defect) -- but evaluation succeeded instead")

        (check "console/hostile-instance-name-with-a-dollar-paren-is-rejected-at-eval-time"
          (buildFailsHm [
            consoleModule
            { nixremote.console."office$(touch /tmp/pwned)" = { enable = true; }; }
          ])
          "an attrsOf key containing a $( ) command substitution must also be rejected at eval time, for the identical reason as the backtick case above -- but evaluation succeeded instead")

        (check "console/hostile-instance-name-with-a-path-separator-is-rejected-at-eval-time"
          (buildFailsHm [
            consoleModule
            { nixremote.console."office/../etc" = { enable = true; }; }
          ])
          "an attrsOf key containing '/' must also be rejected -- it is used verbatim as a directory-name component under $XDG_RUNTIME_DIR (runtimeSubdir), so a value like 'office/../etc' would escape the intended per-instance runtime directory entirely -- but evaluation succeeded instead")

        (check "console/instance-name-using-only-the-allowed-character-class-still-evaluates-cleanly"
          (!(buildFailsHm [ consoleModule { nixremote.console."vnc_office-1" = { enable = true; }; } ]))
          "an attrsOf key using only [A-Za-z0-9_-] (letters, digits, '-', '_') must NOT be rejected -- _instanceName's constraint must reject hostile characters without also rejecting ordinary, safe instance names -- got a build failure for \"vnc_office-1\"")

        # ── rustdeskClient ──────────────────────────────────────────────────────────────────────

        (check "rustdeskClient/disabled-renders-no-activation-entry"
          (rustdeskClient-disabled.home.activation == { })
          "enable left at its default (false) must add zero home.activation entries -- got: ${builtins.toJSON (builtins.attrNames rustdeskClient-disabled.home.activation)}")

        (check "rustdeskClient/enabled-renders-exactly-one-activation-entry"
          (builtins.attrNames rustdeskClient-basic.home.activation == [ "nixremoteRustdeskClient" ])
          "enable = true must render exactly the one named activation entry -- got: ${builtins.toJSON (builtins.attrNames rustdeskClient-basic.home.activation)}")

        (check "rustdeskClient/rendered-script-sets-server-and-key-on-both-option-keys"
          (let text = rustdeskClientScriptText rustdeskClient-basic; in
          lib.hasInfix ''options["custom-rendezvous-server"] = "rustdesk.example.org"'' text
          && lib.hasInfix ''options["relay-server"] = "rustdesk.example.org"'' text
          && lib.hasInfix ''options["key"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="'' text)
          "the rendered merge script must set BOTH custom-rendezvous-server and relay-server to `server`, and key to `key`, as real Python literal assignments -- got: ${rustdeskClientScriptText rustdeskClient-basic}")

        (check "rustdeskClient/rendered-script-never-touches-device-identity-file"
          (!(lib.hasInfix "RustDesk.toml" (rustdeskClientScriptText rustdeskClient-basic))
            && lib.hasInfix "RustDesk2.toml" (rustdeskClientScriptText rustdeskClient-basic))
          "the merge script must open RustDesk2.toml (the server-pointer file) and must NEVER reference RustDesk.toml (the device's own generated identity/keypair) -- got: ${rustdeskClientScriptText rustdeskClient-basic}")

        (check "rustdeskClient/rendered-script-loads-before-writing-so-existing-keys-survive"
          (let text = rustdeskClientScriptText rustdeskClient-basic; in
          lib.hasInfix "toml.load(f)" text && lib.hasInfix "os.path.exists(path)" text)
          "the merge script must LOAD the existing file (gated on it existing) before writing it back -- a script that always starts from `{}` would silently discard an already-paired device's other fields (rendezvous_server, nat_type, serial, ...) on every activation -- got: ${rustdeskClientScriptText rustdeskClient-basic}")

        (check "rustdeskClient/extraOptions-merge-in-without-replacing-the-owned-keys"
          (let text = rustdeskClientScriptText rustdeskClient-extra; in
          lib.hasInfix ''options.update({"allow-insecure-tls-fallback":"Y"})'' text
          && lib.hasInfix ''options["custom-rendezvous-server"] = "rustdesk.example.com"'' text
          && lib.hasInfix ''options["key"] = "some-key=="'' text)
          "extraOptions must render as a real options.update(...) call, ADDITIONAL to (never replacing) the module's own custom-rendezvous-server/relay-server/key assignments -- got: ${rustdeskClientScriptText rustdeskClient-extra}")
      ];

      failed = builtins.filter (r: !r.ok) allResults;
      report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
    in
    if failed != [ ]
    then
      throw ''
        nixremote eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length allResults)}):
        ${report}
      ''
    else
      pkgs.runCommand "nixremote-eval-tests"
        { passedCount = toString (builtins.length allResults); }
        ''
          echo "all $passedCount nixremote eval tests passed"
          touch $out
        '';
}

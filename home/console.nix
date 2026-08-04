# home/console.nix — nixremote.console.<name>: wayvnc + noVNC, the "full session in a browser"
# leg neither forward.nix (pull one window FROM a peer) nor sunshine.nix (game-stream THIS
# session to a purpose-built client) covers: an ordinary VNC client, or nothing more than a
# browser tab, reaching the whole Wayland session (or one output of it).
#
# `output = null` MEANS "CAPTURE ALL OUTPUTS", MATCHING THIS MODULE'S OWN "full session in a
# browser" PURPOSE -- verified against wayvnc 0.10.1 (the version nixpkgs pins here; re-checked
# via `wayvnc.scd`'s OPTIONS section and `src/main.c` directly this session, not assumed from a
# stale reading of 0.9.1's docs). 0.10.1 ships `-a, --desktop` ("Capture all outputs."), which did
# not exist when this file was first written; without it (and without `-o`), wayvnc instead
# captures exactly ONE output -- whichever it happens to enumerate first, not guaranteed stable
# across a compositor restart (its own "MULTIPLE OUTPUTS" section: "If the Wayland session
# consists of multiple outputs, only one will be captured."). Since single-output, non-deterministic
# capture is never what this module's stated purpose wants, `output = null` below renders `-a`
# (all outputs), and `output = "HDMI-A-1"` renders `-o HDMI-A-1` (a specific one) -- main.c rejects
# passing both together (`"desktop and output are conflicting options"`), so the two are kept
# mutually exclusive here too.
#
# WHY WLROOTS-ONLY, AND WHY THIS MODULE CANNOT RELAX THAT. wayvnc captures frames through
# `zwlr_screencopy_manager_v1` — a wlr-* protocol extension, not core Wayland, and not something
# every compositor implements. Every compositor this repo's family targets (niri, sway, scroll)
# is wlroots or a wlroots fork and implements it; a non-wlroots session (GNOME/Mutter,
# KDE/KWin) exposes no equivalent surface at all, and there is no portable substitute — this is a
# hard capability boundary of wayvnc itself, not a config knob this module could route around.
#
# ATTACHES TO AN ALREADY-RUNNING SESSION, exactly like sunshine.nix. wayvnc needs WAYLAND_DISPLAY
# and XDG_RUNTIME_DIR to find the compositor's socket, both exported into the systemd --user
# manager's GLOBAL environment by the compositor's own `--session`-equivalent launch (confirmed
# live for niri, see sunshine.nix's header for the full mechanism) — hence `PartOf` +
# `After = [ "graphical-session.target" ]` on every unit this module renders, the same ordering
# sunshine.nix uses for the identical reason.
#
# SECRETS ARE FILES, NEVER LITERAL STRINGS IN THE STORE — and specifically never *paths typed as
# Nix path literals* either. `auth.usernameFile`/`auth.passwordFile` and `tls.certFile`/
# `tls.keyFile` are all `str` (not `path`) options: a Nix `path` value gets COPIED INTO THE STORE
# the moment anything string-interpolates it (`"${somePath}"` forces `builtins.toString`'s
# store-copying cousin for path values, unlike `builtins.toString` itself, which never copies) —
# so accepting these as `path` would silently exfiltrate the referenced file into the
# world-readable Nix store the first time this module rendered anything with it, which is exactly
# the leak "secrets are files" exists to avoid. Pass these options a STRING
# (`"/run/secrets/wayvnc-password"`), never a bare unquoted Nix path expression pointing at the
# same file — the module's own option type refuses a real `path` value outright, but only a `str`
# actually guarantees no copy ever happens regardless of what a future edit here does with it.
#
# Given that, this module never reads these files at Nix EVAL time either: doing so would bake
# the secret's *contents* into a derivation the store still keeps world-readable, which is no
# better than baking in the path would have been. Instead, `renderConfigScript` below runs at
# every service START (an `ExecStartPre`), reading the files FRESH each time and writing a
# minimal wayvnc config to `$XDG_RUNTIME_DIR` — tmpfs, per-user, mode 0700, wiped every
# boot/logout, and never a Nix store path. A rotated credential file therefore takes effect on
# the unit's next restart, with nothing in this module to re-render.
#
# WLR_RENDERER=pixman IS A PRECONDITION THIS MODULE CANNOT SET FOR YOU. A session served ONLY
# through this module (no physical seat — `delivery = "headless"` in nixdesktop's own
# vocabulary) has no legitimate reason to touch a real DRM render node, but a wlroots compositor's
# renderer auto-detection picks one anyway unless told otherwise — and on this estate the only
# render node present belongs to the shared RX 6800, which a headless session is
# expressly forbidden to touch (see the estate's own GPU-tenancy contract). The fix,
# `WLR_RENDERER=pixman` (software rendering), belongs on the COMPOSITOR's OWN systemd unit —
# `niri.service`, `sway.service`, whichever this instance's `graphical-session.target` actually
# depends on — NOT on any unit this module renders: wayvnc is a Wayland *client* of the
# compositor via `zwlr_screencopy_manager_v1`; it links no wlroots rendering code itself and does
# not read `WLR_RENDERER` at all, so setting it on wayvnc's own unit would be a no-op that reads
# as enforcement while providing none. This module has no handle on a sibling unit it did not
# create, so this is a manual, one-time, documented-not-automated precondition — the same class
# of gap as forward.nix's own `Include ~/.ssh/conf.d/nixremote.conf` line. Set it yourself, on
# whichever unit launches the headless compositor this console instance is meant to serve.
#
# THE NOVNC/WEBSOCKIFY WEB FRONT (`web.*`) IS A SEPARATE PROCESS, NOT WAYVNC ITSELF. wayvnc 0.10.1
# (the version packaged in nixpkgs here) DOES have its own native `-w`/`--websocket` flag, but
# this module doesn't use it: the task's own `web.*` shape (one `package` producing both the
# static UI and the proxy) matches nixpkgs' `novnc` package far more directly than wiring wayvnc's
# native websocket mode up to a hand-rolled static file server would, and it keeps the frontend
# swappable independently of whatever websocket support any given wayvnc build happens to ship.
# `web.package` (`pkgs.novnc`) fronts wayvnc's plain RFB TCP port with noVNC's static web UI plus
# a websockify proxy, in ONE process (nixpkgs installs noVNC's `utils/novnc_proxy` script as
# `$out/bin/novnc` — note the renamed binary, confirmed by reading the package derivation itself
# this session, not assumed from upstream's own script name). wayvnc's own optional TLS
# (`tls.*`, VeNCrypt — negotiated *inside* the RFB byte stream after the initial handshake, not a
# raw TLS-wrapped socket) is unaffected by sitting behind a byte-level proxy for exactly that
# reason: the TLS session is end-to-end between the real VNC client and wayvnc, and websockify
# never has to understand it. `web` has no bind address of its own in this module's option shape
# (only `port`) — `novnc`'s own default listen behaviour (all interfaces) applies; front it with
# your own reverse proxy/firewall before exposing it past loopback, the same caution `address`'s
# own description gives for wayvnc's raw RFB port. Nixpkgs' own build already patches
# `novnc_proxy`'s `--web` default to point at its bundled `vnc.html`/etc (`$out/share/webapps/
# novnc`, confirmed by reading `pkgs.novnc`'s own `fix-paths.patch` this session) — this module
# does not pass `--web` itself, deliberately, so it keeps working if that package is swapped for
# something that patches its own default differently.
#
# `web.connectAddress` IS NOT `address`, EVEN THOUGH BOTH DEFAULT TO THE SAME VALUE MOST OF THE
# TIME. `address` is the address wayvnc BINDS (a listen()-side concept: `0.0.0.0`/`::` are valid
# "accept from anywhere" wildcards there). `web.connectAddress` is the address websockify DIALS
# (a connect()-side concept: you cannot literally dial the wildcard `0.0.0.0`/`::` the way you can
# bind to it -- there is no "connect to everywhere"). Novnc/websockify runs colocated with wayvnc
# on the same host in every shape this module supports, so a wildcard `address` still means
# "loopback works" for connectAddress's purposes -- `web.connectAddress` defaults to `127.0.0.1`
# whenever `address` is a wildcard bind, and to `address` verbatim otherwise (a specific bind IP
# configured on one of this host's own interfaces is always reachable by dialing that exact same
# address from the same host). Conflating the two (passing `address` straight to websockify's
# `--vnc`) used to mean `address = "0.0.0.0"` rendered `--vnc "0.0.0.0:5900"`, which told
# websockify to CONNECT to 0.0.0.0 -- not "connect to whatever this host owns", just a malformed
# destination most TCP stacks refuse outright. See `webStartScript` below and `connectAddress`'s
# own option doc.
#
# CONFIG KEYS RENDERED BELOW (`enable_auth`, `username`, `password`, `private_key_file`,
# `certificate_file`) and the auth/TLS coupling asserted below are both taken directly from
# wayvnc's own `wayvnc.scd` (0.10.1, re-read this session): `enable_auth=true` is documented as
# requiring `certificate_file`, `private_key_file` AND `password` -- but *not* `username`, which
# the same section spells out as "optional and defaults to an empty string if not set." So despite
# this module's option shape splitting `auth.*` and `tls.*` into two independently-toggleable
# groups (matching what was asked for), wayvnc itself does not treat them as independent for the
# three keys that actually are required together, and `certificate_file`/`private_key_file` are
# themselves documented as "only applicable when enable_auth=true" — i.e. a silent no-op without
# it. The assertions below enforce `auth.enable == tls.enable` for exactly this reason: either one
# set without the other is not a valid wayvnc configuration, just one wayvnc would silently
# half-apply. `auth.usernameFile` itself stays optional (see its own option doc) -- only
# `passwordFile` is asserted required. (wayvnc also supports a separate, legacy
# `rsa_private_key_file`/`relax_encryption` RSA-AES auth mode, per the same man page section — not
# modeled here, since nothing in the task's own option shape asked for it and it is documented as
# the weaker of wayvnc's two auth mechanisms.)
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.console;

  consoleModule = { name, config, ... }: {
    options = {
      # ── PRIMARY DEFENSE against an injectable attrsOf key ──────────────────────────────────
      #
      # `name` (this instance's own `nixremote.console.<name>` attrsOf key) reaches REAL,
      # double-quoted shell context below -- `renderConfigScript`'s `out_dir=` assignment and its
      # `read_secret` diagnostic `echo`, and `wayvncStartScript`'s `configPath` -- where backticks
      # and `$( )` still expand even though the surrounding text was written by this module, not
      # by wayvnc. It is ALSO used, unescaped, as a systemd unit-name fragment (`unitName`) and an
      # `$XDG_RUNTIME_DIR` subdirectory name (`runtimeSubdir`). Escaping at each of those call
      # sites is necessary but is a defense you have to remember EVERY TIME a new use site is
      # added -- and one of them (the `out_dir=`/`echo` lines) shipped without it. So the PRIMARY
      # fix constrains the TYPE itself, here: `_instanceName` forces `name` through
      # `types.strMatching` for a safe character class -- alphanumerics, `-` and `_` only -- which
      # is simultaneously safe as a raw double-quoted shell fragment (no backtick/`$`/quote/`/`/
      # whitespace can ever reach that context), a valid single path component under
      # `$XDG_RUNTIME_DIR`, and a valid systemd unit-name fragment with no need for systemd's own
      # unit-name escaping rules (which exist for characters this class already excludes).
      # `lib.escapeShellArg` is STILL applied at each shell call site below -- the SECOND layer,
      # not the first -- precisely because a type constraint someone could loosen later must never
      # be the only thing standing between an attrsOf key and code execution.
      _instanceName = lib.mkOption {
        internal = true;
        readOnly = true;
        type = lib.types.strMatching "[A-Za-z0-9_-]+";
        default = name;
        description = ''
          Internal: this instance's own attrsOf key (`nixremote.console.<name>`), forced through
          `types.strMatching` so a hostile key (shell metacharacters, path separators, whitespace,
          ...) is REJECTED at Nix eval time -- see the comment above this option for the full
          reasoning. Not meant to be set directly; it always mirrors the attrsOf key itself, and
          reading it is what actually triggers the type check (see this file's top-level
          `assertions` for the unconditional read that forces it for every instance).
        '';
      };

      enable = lib.mkEnableOption "this wayvnc + noVNC console instance";

      output = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "HDMI-A-1";
        description = ''
          Capture only this output (wayvnc's `-o`/`--output`), or `null` (the default) to capture
          ALL outputs via wayvnc 0.10.1's `-a`/`--desktop` -- matching this module's own "full
          session in a browser" purpose (see this file's header for the version history: earlier
          wayvnc releases had no whole-session mode at all, so this used to mean something
          weaker). Set this to a specific output name to capture only that one instead; wayvnc
          rejects passing both `-a` and `-o` together, so this module only ever renders one or
          the other.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = ''
          Address wayvnc's RFB server binds. Defaults to LOOPBACK on purpose — unlike Sunshine
          (a purpose-built, authenticated streaming protocol), plain RFB has a long history of
          weak-or-absent auth by default, so this module refuses to default to a public bind.
          Widen this only alongside `auth.enable = true` (and ideally `tls.enable = true` too),
          and only once you've actually verified the result — see `auth`'s own description.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5900;
        description = "TCP port for wayvnc's own RFB server — wayvnc's own upstream default.";
      };

      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        example = lib.literalExpression "pkgs.wayvnc";
        description = ''
          A nixpkgs wayvnc to install via home.packages, or null (the default) to install
          nothing and use whatever `binary` resolves through $PATH — the same host-decides split,
          for the same reason (a GPU-adjacent capture stack is exactly where a Nix-built copy can
          lose sight of the host's real driver stack), as sunshine.nix's own `package`/`binary`;
          see that module's header for the full diagnosis.
        '';
      };

      binary = lib.mkOption {
        type = lib.types.str;
        default = "wayvnc";
        example = "/usr/bin/wayvnc";
        description = "Path (or bare $PATH name) to the actual wayvnc binary the generated unit execs.";
      };

      auth = {
        enable = lib.mkEnableOption "wayvnc's own username/password RFB auth (its `enable_auth` config key)";

        usernameFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/nixremote-console-username";
          description = ''
            ABSOLUTE PATH, as a plain string, to a file holding the RFB username — read fresh at
            every service start, never at Nix eval time. OPTIONAL even when `auth.enable` is
            true: wayvnc's own `wayvnc.scd` documents `username` as "optional and defaults to an
            empty string if not set" (unlike `passwordFile`, which IS required -- asserted
            below). Pass this as a quoted string, never a bare Nix path literal — see this
            module's header for why an actual `path` value would leak the file into the
            world-readable Nix store the moment it were used.
          '';
        };

        passwordFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/nixremote-console-password";
          description = ''
            Same handling as `usernameFile`, for the RFB password. Required when `auth.enable`
            is true (asserted below).
          '';
        };
      };

      tls = {
        enable = lib.mkEnableOption "wayvnc's own TLS (VeNCrypt, negotiated inside the RFB stream, not a raw TLS-wrapped socket)";

        certFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/nixremote-console-cert.pem";
          description = ''
            ABSOLUTE PATH, as a plain string, to the TLS certificate (wayvnc's
            `certificate_file`). Required when `tls.enable` is true (asserted below). A path is
            not secret in the same way a password is, but this stays `str` for the same reason
            as `auth.*` above: consistency, and no surprise store copy regardless.
          '';
        };

        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/run/secrets/nixremote-console-key.pem";
          description = ''
            ABSOLUTE PATH, as a plain string, to the TLS private key (wayvnc's
            `private_key_file`). Required when `tls.enable` is true (asserted below). Genuinely
            secret, unlike `certFile` — never pass this as a Nix path literal; see this module's
            header.
          '';
        };
      };

      web = {
        enable = lib.mkEnableOption "a noVNC/websockify web front for this instance — browser access, no VNC client installed";

        port = lib.mkOption {
          type = lib.types.port;
          default = 6080;
          description = "TCP port the noVNC web UI + websocket proxy listens on — noVNC's `novnc_proxy` (installed as `bin/novnc` by nixpkgs) own upstream default.";
        };

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          example = lib.literalExpression "pkgs.novnc";
          description = ''
            A package providing a `bin/novnc` (nixpkgs' own name for noVNC's `novnc_proxy`
            script — see this file's header), or null (the default) to install nothing — the
            same host-decides split as `package` above. Required when `web.enable` is true
            (asserted below); nothing installs it implicitly.
          '';
        };

        connectAddress = lib.mkOption {
          type = lib.types.str;
          default = if lib.elem config.address [ "0.0.0.0" "::" ] then "127.0.0.1" else config.address;
          defaultText = lib.literalExpression ''"127.0.0.1" if address is a wildcard bind, else address'';
          example = "127.0.0.1";
          description = ''
            Address websockify actually DIALS (its own `--vnc` flag) to reach wayvnc's RFB port --
            deliberately NOT the same option as `address` (the address wayvnc BINDS). See this
            file's header for why conflating the two was a real bug: `address = "0.0.0.0"` (or
            `"::"`) is a valid BIND wildcard but not something you can literally CONNECT to.
            Defaults to `127.0.0.1` whenever `address` is such a wildcard (websockify and wayvnc
            always run on the same host here, and a wildcard bind always accepts loopback
            connections too), or to `address` verbatim otherwise. Override explicitly if
            websockify runs on a different host than wayvnc.
          '';
        };
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra CLI arguments appended verbatim to the generated wayvnc invocation.";
      };
    };
  };

  unitName = name: "nixremote-console-${name}";
  runtimeSubdir = name: "nixremote-console-${name}";

  # Runs as `ExecStartPre`, at every start, writing ONLY the auth/TLS lines wayvnc needs into a
  # runtime-only config under $XDG_RUNTIME_DIR (tmpfs, 0700, per-user, gone at boot/logout) --
  # never a Nix store path. `address`/`port`/`output` are NOT secret, so they're passed as plain
  # CLI arguments in `wayvncStartScript` below instead of duplicated here -- one source of truth
  # for each value, secret or not.
  #
  # `install`/`cat` BELOW ARE INTERPOLATED STORE PATHS, NOT BARE NAMES -- found live 2026-08-04:
  # this unit carries no `Environment=PATH=`, and a systemd --user manager's own default PATH is
  # not guaranteed to include a nix-built coreutils (confirmed on the devhome host: it does not),
  # so a bare `install`/`cat` here failed with a bare exit 127 and no other diagnostic, crash-
  # looping the unit indefinitely under `Restart=on-failure`. Exactly the same class of bug (and
  # fix) this repo's own `sunshine.nix`/`hosts/nixnas-devhome.nix` already document for a bare
  # `ExecStart=` name -- see either for the fuller mechanism.
  renderConfigScript = name: c: pkgs.writeShellScript "nixremote-console-${name}-render-config" ''
    set -euo pipefail
    # SECOND LAYER escaping (see consoleModule's `_instanceName` option for the PRIMARY defense,
    # which already restricts `name` to a safe character class at Nix eval time): `name` is
    # spliced below via `lib.escapeShellArg`, concatenated directly against the surrounding
    # DOUBLE-quoted `$XDG_RUNTIME_DIR` segment -- bash concatenates adjacent quoted/bare words
    # with no whitespace between them into one word/argument, so this keeps `$XDG_RUNTIME_DIR`
    # expanding at runtime (the earlier defect this file's header already documents) while making
    # the name fragment immune to backtick/`$( )` expansion no matter what characters ever reach
    # this Nix string. `lib.escapeShellArg` only wraps its argument in single quotes when the
    # string contains something outside its OWN safe set (`[[:alnum:],._+:@%/-]`); since the
    # PRIMARY defense's charset is a strict subset of that, this call is a harmless passthrough
    # for every name that reaches here today -- it is still the right thing to call, because it
    # is the layer that actually engages (wrapping in real quotes, escaping any embedded `'`) the
    # moment anyone ever loosens `_instanceName`'s type without also revisiting this call site.
    out_dir="''${XDG_RUNTIME_DIR:?nixremote console: XDG_RUNTIME_DIR is not set -- this unit must run inside a real user session}/"${lib.escapeShellArg (runtimeSubdir name)}
    umask 077
    ${pkgs.coreutils}/bin/install -d -m 0700 "$out_dir"

    # Read a secret file into a shell VARIABLE first, then use the variable -- never inline a
    # `$(cat ...)` command substitution directly as another command's argument. Under `set -e`,
    # a failing command inside a substitution used that way does NOT abort the script: the
    # substituting command (e.g. `printf`) still exits 0 regardless of what `cat` returned, so an
    # unreadable secret used to render an EMPTY value into the runtime config instead of failing
    # closed. `var=$(cmd)` as its own statement DOES make the command's exit status the
    # statement's own, so `set -e` fires -- the explicit `-r` test on top gives a named,
    # actionable error instead of a bare `cat: No such file or directory`.
    read_secret() {
      local file="$1" label="$2"
      if [ ! -r "$file" ]; then
        # Same second-layer splice as `out_dir` above: `name` passed through `lib.escapeShellArg`
        # between two double-quoted segments, rather than interpolated straight into one
        # continuous double-quoted run.
        echo "nixremote console "${lib.escapeShellArg name}": $label file is not readable: $file" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/cat "$file"
    }

    {
      # BLOCKER FIX: `:` (a real, no-op command) so this group is NEVER syntactically empty. With
      # auth.enable and tls.enable both false -- this module's documented default/minimal shape --
      # every `lib.optionalString` below renders "", and bash rejects a literally empty `{ }`
      # compound command with a syntax error; `pkgs.writeShellScript`'s own `bash -n` checkPhase
      # then fails the WHOLE derivation build before this script can ever run or even be read.
      :
      ${lib.optionalString c.auth.enable ''
        echo "enable_auth=true"
        ${lib.optionalString (c.auth.usernameFile != null) ''
          username="$(read_secret ${lib.escapeShellArg c.auth.usernameFile} username)"
          printf 'username=%s\n' "$username"
        ''}
        password="$(read_secret ${lib.escapeShellArg c.auth.passwordFile} password)"
        printf 'password=%s\n' "$password"
      ''}
      ${lib.optionalString c.tls.enable ''
        echo "private_key_file=${c.tls.keyFile}"
        echo "certificate_file=${c.tls.certFile}"
      ''}
    } > "$out_dir/config"
  '';

  wayvncStartScript = name: c:
    let
      # A Nix string containing a literal, unexpanded `$XDG_RUNTIME_DIR` reference, DOUBLE-quoted
      # (so it expands at runtime -- see the header comment on the earlier defect this fixed:
      # single-quoting the whole path made wayvnc hard-exit against a path that could never
      # exist). The name fragment in the middle is DELIBERATELY split out of that double-quoted
      # run and passed through `lib.escapeShellArg` on its own -- the SECOND layer of defense
      # against an injectable attrsOf key (see consoleModule's `_instanceName` option for the
      # PRIMARY one): bash concatenates adjacent quoted/bare words with no whitespace between them
      # into a single word, so `"$XDG_RUNTIME_DIR/"` + escapeShellArg's output + `"/config"` is
      # one argument, exactly as `"$XDG_RUNTIME_DIR/name/config"` would have been -- except the
      # name fragment can never be re-parsed as shell syntax (backticks/`$( )`) no matter what
      # characters ever reach this Nix string: `escapeShellArg` passes safe names through bare
      # (a no-op here, since the PRIMARY defense's charset is a strict subset of what it considers
      # already-safe) but wraps and escapes anything else in real single quotes the moment
      # `_instanceName`'s type is ever loosened without this call site being revisited too.
      # `configPath` carries its OWN complete quoting below (unlike the old shape, where the call
      # site wrapped a single Nix string in one pair of double quotes), so the call site below
      # does not wrap it in another pair of quotes.
      configPath = ''"$XDG_RUNTIME_DIR/"'' + lib.escapeShellArg (runtimeSubdir name) + ''"/config"'';
      # `null` -> capture ALL outputs (`-a`); a name -> capture that one (`-o <name>`). Never
      # both -- wayvnc's option parser rejects the combination. See the `output` option's own
      # doc and this file's header for why `null` no longer means "omit the flag entirely".
      outputArgs = if c.output != null then [ "-o" c.output ] else [ "-a" ];
    in
    # DELIBERATELY no `--` anywhere before address/port (kept out of the shell script body
    # itself, below, so it can never show up in a raw-text scan of the rendered ExecStart):
    # wayvnc 0.10.1's option parser treats a bare `--` token as "stop parsing options, hand
    # everything after it to remaining_argv" (src/option-parser.c), and main.c never reads
    # remaining_argv for anything -- it only ever consults the "address" POSITIONAL slots it
    # recorded during parsing (option_parser_get_value_with_offset(..., "address", 0/1)). With a
    # `--` in front, address/port used to be silently discarded and every instance fell back to
    # wayvnc's own hardcoded DEFAULT_ADDRESS (127.0.0.1) and DEFAULT_PORT (5900) regardless of
    # configuration. Address and port are ordinary trailing positional arguments; nothing needs
    # to separate them from the preceding flags.
    pkgs.writeShellScript "nixremote-console-${name}-start" ''
      set -euo pipefail
      exec ${c.binary} -C ${configPath} ${lib.escapeShellArgs (outputArgs ++ c.extraArgs)} ${lib.escapeShellArg c.address} ${toString c.port}
    '';

  # `bin/novnc`, NOT `bin/novnc_proxy` -- nixpkgs installs noVNC's `utils/novnc_proxy` script
  # under the renamed path `$out/bin/novnc` (`mainProgram = "novnc"`; confirmed by reading
  # `pkgs.novnc`'s own package derivation this session, not assumed from upstream's script name).
  # No `--web` passed: nixpkgs' own `fix-paths.patch` already bakes in the correct default
  # (`$out/share/webapps/novnc`, where its `vnc.html` actually lives) — passing a second,
  # possibly-stale path here would only fight that patch.
  webStartScript = name: c: pkgs.writeShellScript "nixremote-console-${name}-web-start" ''
    set -euo pipefail
    exec ${c.web.package}/bin/novnc --vnc ${lib.escapeShellArg "${c.web.connectAddress}:${toString c.port}"} --listen ${toString c.web.port}
  '';

  mkUnitsFor = name: c:
    lib.optionalAttrs c.enable ({
      "${unitName name}" = {
        Unit = {
          Description = "nixremote console (wayvnc) -- ${name}";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };
        Service = {
          ExecStartPre = [ "${renderConfigScript name c}" ];
          ExecStart = "${wayvncStartScript name c}";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    } // lib.optionalAttrs c.web.enable {
      "${unitName name}-web" = {
        Unit = {
          Description = "nixremote console noVNC web front -- ${name}";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" "${unitName name}.service" ];
          Requires = [ "${unitName name}.service" ];
        };
        Service = {
          ExecStart = "${webStartScript name c}";
          Restart = "on-failure";
          RestartSec = 5;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    });
in
{
  options.nixremote.console = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule consoleModule);
    default = { };
    description = ''
      Declare a wayvnc + noVNC "console" instance: a Wayland session (or one output of it)
      reachable over plain VNC (wayvnc's own RFB server) and, optionally, a browser (noVNC's web
      UI fronting a websockify proxy). See this file's header for the wlroots-only capability
      boundary, the secrets-as-files handling, and the WLR_RENDERER=pixman precondition this
      module cannot enforce for you. An empty attrset is a complete no-op.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    # Both `assertions` and `home.packages` below are guarded by `c.enable`, matching
    # `mkUnitsFor`'s own `lib.optionalAttrs c.enable` -- a parked (`enable = false`) instance is a
    # deliberately-inert declaration, so it must not fail the build over an otherwise-invalid
    # auth/tls/web shape it will never actually run, and it must not install packages either.
    assertions = lib.concatLists (lib.mapAttrsToList
      (name: c: [
        {
          # Forces `_instanceName`'s `types.strMatching` check to actually RUN, unconditionally --
          # NOT gated by `c.enable` like every assertion below this one, because the attrsOf key
          # is fixed at eval time regardless of whether the instance is turned on (a parked
          # instance can be enabled later without ever re-typing its name). Nix's laziness means
          # nothing evaluates `_instanceName` on its own; reading it here (via this equality,
          # itself always true for any name that passes the type check) is what makes a hostile
          # key throw HERE, at eval time, with a clear message -- instead of surviving unnoticed
          # until `renderConfigScript`/`wayvncStartScript` read it far later, deep inside a build.
          assertion = c._instanceName == name;
          message = "unreachable: nixremote.console.${name}: _instanceName/name mismatch (internal consistency check only -- a genuinely hostile name throws from the type check itself, before this assertion's own equality is even reached).";
        }
      ] ++ lib.optionals c.enable [
        # wayvnc's own `enable_auth=true` requires certificate_file/private_key_file/password
        # together (wayvnc.scd, see this file's header) -- so despite `auth` and `tls` being
        # independently toggleable OPTIONS here, they are not independently toggleable in wayvnc
        # itself. One enabled without the other is not a degraded-but-valid config, it's one
        # wayvnc silently fails to apply in full.
        {
          assertion = c.auth.enable == c.tls.enable;
          message = ''
            nixremote.console.${name}: auth.enable (${lib.boolToString c.auth.enable}) and
            tls.enable (${lib.boolToString c.tls.enable}) disagree. wayvnc's own enable_auth key
            requires certificate_file, private_key_file AND password to ALL be set together
            (wayvnc.scd's own CONFIGURATION section; username is optional) -- enable both
            together or neither.
          '';
        }
        {
          assertion = !c.auth.enable || c.auth.passwordFile != null;
          message = "nixremote.console.${name}.auth.enable is true but passwordFile is not set (usernameFile is optional -- wayvnc defaults it to an empty string).";
        }
        {
          assertion = !c.tls.enable || (c.tls.certFile != null && c.tls.keyFile != null);
          message = "nixremote.console.${name}.tls.enable is true but certFile/keyFile are not both set.";
        }
        {
          assertion = !c.web.enable || c.web.package != null;
          message = "nixremote.console.${name}.web.enable is true but web.package is null -- set it to a package providing a novnc-style websocket proxy + web UI (e.g. pkgs.novnc).";
        }
      ])
      cfg);

    home.packages = lib.concatLists (lib.mapAttrsToList
      (name: c: lib.optionals c.enable (
        lib.optional (c.package != null) c.package
        ++ lib.optional (c.web.enable && c.web.package != null) c.web.package))
      cfg);

    systemd.user.services = lib.mkMerge (lib.mapAttrsToList mkUnitsFor cfg);
  };
}

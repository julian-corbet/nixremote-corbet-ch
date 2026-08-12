# home/launcher.nix — homeManagerModules.launcher: an application launcher whose tabs are MACHINES.
#
# ── WHAT IT IS ────────────────────────────────────────────────────────────────────────────────
#
# A rofi script mode, one mode per machine, categories inside each. You open it, click (or arrow
# to) another machine's tab, and you are looking at that machine's real application list — read
# live off its own `.desktop` files. Pick one and it opens on your screen, forwarded, as an
# ordinary window. Or type `firefox.archlxc` and skip the tabs entirely.
#
# The discovery half is the point, and it is what a plain "forward this command" wrapper cannot do:
# you do not have to already know what the other machine has installed.
#
# ── IT LAUNCHES THROUGH `nixremote.forward`, IT DOES NOT REIMPLEMENT IT ───────────────────────
#
# This module spawns no `waypipe` of its own. A remote launch execs the peer's own generated
# wrapper (`nixremote.forward.<peer>.scriptName`), which is what already owns:
#
#   · the ADDRESS CASCADE — LAN first, overlay when you are not home;
#   · AUDIO RETURN — the forwarded app's sound comes out of the speakers in front of the person
#     looking at the window, resolved per launch;
#   · the VIDEO codec and any `extraOptions` that peer needs (`--no-gpu` for a host with no GPU
#     userspace, for instance);
#   · ORPHAN REAPING, via the `NIXREMOTE_PEER` tag on the remote command line;
#   · and ORIGIN MARKING — `NIXREMOTE_ORIGIN` on the local waypipe process, plus an `<app>@<peer>`
#     app_id for apps that can carry one.
#
# That last one deserves emphasis, because it is where a launcher is most tempted to invent
# something. Marking a forwarded window with the machine it came from is a COMPOSITOR concern: the
# compositor already has a per-window rule engine, and `for_window [app_id="@<peer>$"]` gives every
# window from that machine a title-bar badge and a coloured shadow, whether it was launched from
# this launcher, from a shell, or from anything else. A launcher that instead walked the process
# tree after spawning and tagged what it found would be a second, worse implementation of that —
# racy, bounded by a timeout, and blind to every window it did not personally start. So this module
# does not do it, and deliberately has no colour option at all.
#
# ── THE INVENTORY IS A CACHE, NOT A STORE ────────────────────────────────────────────────────
#
# There is no database of remote applications. Every machine already maintains an authoritative
# list of its own applications — its `.desktop` files — so the inventory is read live over SSH and
# kept in `$XDG_RUNTIME_DIR` for `cacheTtl` seconds. It dies with the boot. A store would need
# invalidation, would go stale exactly when a machine changed, and would answer a question the
# machine itself answers correctly for free.
#
# ── ONE MODE-SWITCHER, SO MACHINES WIN THE TABS ──────────────────────────────────────────────
#
# rofi permits exactly one mode-switcher per layout ("Mode-switcher can only be added once"), so
# only ONE axis can be real clickable tabs. Machines take it, because seeing what another box has
# to offer is the whole purpose; categories are one keystroke in. `tabs` chooses whether that
# switcher runs across the top or down the side — the vertical layout needs a widget rofi does not
# ship (naming an unknown name in `children:` creates it), which is exactly the sort of thing worth
# generating rather than remembering.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixremote.launcher;
  forwardPeers = config.nixremote.forward;

  tomlFormat = pkgs.formats.toml { };

  # Each tab's `ssh` and `launch` filled in from the `nixremote.forward` peer it names, unless the
  # consumer stated them. Resolved HERE rather than as submodule defaults because a `listOf
  # submodule` cannot see the top-level config it needs (`nixremote.forward`), and writing the
  # resolved list back into the option it was read from is an infinite recursion, not a shortcut.
  resolveHost = h:
    let
      peer =
        if h.forward != null && forwardPeers ? ${h.forward}
        then forwardPeers.${h.forward}
        else null;
    in
    h // {
      ssh = if h.ssh != null then h.ssh else (if peer != null then peer.sshAlias else null);
      # ⚠ ABSOLUTE, NOT `peer.scriptName` ON ITS OWN. The peer script is a real executable in the
      # user's profile, and a BARE name here resolves only for a process whose PATH contains that
      # profile. rofi's does not: it is started from the compositor/systemd user session, whose
      # PATH is systemd's own default, and `~/.nix-profile/bin` is not on it. An interactive shell
      # PATH does contain it -- which is exactly why this bug survives every test run from a
      # terminal and fails only for the person actually using the launcher.
      #
      # The symptom is total silence. rlaunch's `launch()` hands argv straight to `Popen`, so the
      # missing name raises out of the whole script and the mode dies mid-launch:
      #
      #   FileNotFoundError: [Errno 2] No such file or directory: 'waypipe@devhome'
      #
      # rofi swallows a script mode's stderr, so the window simply closes with nothing started,
      # nothing logged where anyone would look, and no error on screen. Caught only by watching a
      # real user do it with this file's own `log()` output open.
      #
      # `home.profileDirectory` rather than a hardcoded `~/.nix-profile`: home-manager answers this
      # correctly on both planes, and the NixOS-module plane (`useUserPackages`) puts packages in
      # /etc/profiles/per-user/<name> instead -- a host where the hardcoded path is simply wrong.
      # forward.nix's own `mkAppWrapper` already reaches the peer script by absolute path for the
      # identical reason; this was the one consumer still passing a bare name.
      launch =
        if h.launch != null then h.launch
        else if peer != null then "${config.home.profileDirectory}/bin/${peer.scriptName}"
        else null;
    };

  resolvedHosts = map resolveHost cfg.hosts;

  # ── generated config ────────────────────────────────────────────────────────────────────────
  settings = {
    layout = {
      tabs = cfg.tabs;
      cache_ttl = cfg.cacheTtl;
      terminal = cfg.terminal;
    };
    hosts = map
      (h: lib.filterAttrs (_: v: v != null) {
        inherit (h) name ssh launch;
        local = if h.local then true else null;
      })
      resolvedHosts;
    hide.desktop_files = cfg.hide;
    categories = map (c: { inherit (c) label tags; }) cfg.categories;
    assign = map (a: { inherit (a) match label; }) cfg.assign;
  };

  configFile = tomlFormat.generate "rlaunch-config.toml" settings;

  # ── the rofi theme ──────────────────────────────────────────────────────────────────────────
  #
  # STRUCTURE is generated, COLOUR is supplied. The structural difference between the two tab
  # orientations is not cosmetic and is not obvious: horizontal is one vertical `mainbox` with the
  # mode-switcher as its second child, while vertical needs the mainbox turned horizontal and a
  # SECOND container for everything to the right of the switcher — a container rofi has no name
  # for, which you create by naming it in `children:`. That is mechanism. The palette is not.
  varLines = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "    ${k}: ${v};") cfg.theme.variables);

  themeText = ''
    /* GENERATED by nixremote's homeManagerModules.launcher. Do not edit — the next
       home-manager generation overwrites it. Structure comes from `tabs`; every
       colour comes from `theme.variables`. */

    * {
    ${varLines}

        background-color: transparent;
        text-color:       @fg;
        font:             ${builtins.toJSON cfg.theme.font};
    }

    window {
        background-color: @ground;
        border:           1px;
        border-color:     @accent;
        border-radius:    14px;
        width:            ${cfg.theme.width};
        padding:          14px;
    }

    ${if cfg.tabs == "vertical" then ''
      mainbox {
          orientation: horizontal;
          spacing:     12px;
          children:    [ mode-switcher, mainright ];
      }

      /* a widget rofi does not know about — naming it in children: creates it */
      mainright {
          orientation: vertical;
          spacing:     10px;
          children:    [ inputbar, message, listview ];
      }

      mode-switcher {
          orientation: vertical;
          spacing:     6px;
          width:       ${toString cfg.theme.tabWidth}px;
          expand:      false;
      }

      button { padding: 9px 12px; }
    '' else ''
      mainbox {
          orientation: vertical;
          spacing:     10px;
          children:    [ inputbar, mode-switcher, message, listview ];
      }

      mode-switcher {
          orientation: horizontal;
          spacing:     6px;
      }

      button { padding: 7px 0px; }
    ''}

    inputbar {
        background-color: @surface;
        border:           1px;
        border-color:     @muted;
        border-radius:    9px;
        padding:          8px 12px;
        spacing:          8px;
        children:         [ prompt, entry ];
    }

    prompt { text-color: @prompt-fg; }
    entry  { text-color: @bright; placeholder: ${builtins.toJSON cfg.theme.placeholder}; }

    button {
        background-color: @surface;
        border-radius:    9px;
        text-color:       @fg;
        cursor:           pointer;
    }

    button selected {
        background-color: @accent;
        text-color:       @ground;
    }

    message {
        background-color: @surface;
        border-radius:    9px;
        padding:          7px 12px;
    }

    textbox { text-color: @fg; }

    listview {
        lines:        ${toString cfg.theme.lines};
        scrollbar:    false;
        spacing:      2px;
        fixed-height: false;
    }

    element {
        padding:       7px 12px;
        border-radius: 8px;
        cursor:        pointer;
    }

    element selected { background-color: @accent; text-color: @ground; }

    element-text {
        background-color: transparent;
        text-color:       inherit;
        /* rofi rejects a @variable inside highlight, so the accent is written out */
        highlight:        bold ${cfg.theme.variables.accent or "#22C55E"};
    }

    ${cfg.theme.extra}
  '';

  themeFile = pkgs.writeText "rlaunch.rasi" themeText;

  # ── the scripts ─────────────────────────────────────────────────────────────────────────────
  #
  # Written as store files with `interpreter` on the shebang rather than built against a nixpkgs
  # Python, for the reason spelled out on that option: this module installs no interpreter. The
  # BUILD still syntax-checks them with a real Python, which is free and catches the one class of
  # error a text file otherwise ships happily.
  pyScript = name: text: pkgs.writeTextFile {
    inherit name;
    destination = "/bin/${name}";
    executable = true;
    text = "#!${cfg.interpreter}\n" + text;
    checkPhase = ''
      ${pkgs.python3}/bin/python3 -m py_compile $out/bin/${name}
    '';
  };

  rlaunch = pyScript "rlaunch" ''
    """rlaunch — rofi script mode. One mode per MACHINE; categories live inside.

    Invoked by rofi as:  rlaunch <host>             (initial, ROFI_RETV=0)
                         rlaunch <host> <selection> (ROFI_RETV=1 selected, 2 typed)

    GENERATED by nixremote's homeManagerModules.launcher. Do not edit.
    """
    import glob
    import json
    import os
    import re
    import shlex
    import subprocess
    import sys
    import time
    import tomllib

    ESC, NUL = "\x1f", "\0"
    CONF = ${builtins.toJSON "${config.xdg.configHome}/rlaunch/config.toml"}
    RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "rlaunch")
    LOCAL_DIRS = ["~/.local/share/applications", "/usr/local/share/applications",
                  "/usr/share/applications"]
    REMOTE_DIRS = ["/usr/share/applications", "$HOME/.local/share/applications",
                   "/run/current-system/sw/share/applications",
                   # home-manager-as-NixOS-module puts a user's apps here, and it is
                   # NOT on the PATH of an ssh command run as anyone else
                   "/etc/profiles/per-user/*/share/applications"]
    WANT = "^(Name|Exec|Categories|Icon|Terminal|NoDisplay|Hidden|Type)="
    FIELD_CODES = re.compile(r"%[fFuUickvmdDnN]")
    BACK = "‹ back"


    def cfg():
        with open(CONF, "rb") as f:
            return tomllib.load(f)


    def meta(k, v):
        print(f"{NUL}{k}{ESC}{v}")


    def log(msg):
        """Every invocation is recorded. rofi swallows stderr from script modes, so
        without this a mode that dies is simply a window that closed."""
        try:
            os.makedirs(RUN, exist_ok=True)
            with open(os.path.join(RUN, "log"), "a") as f:
                f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
        except OSError:
            pass


    # ── inventory ────────────────────────────────────────────────────────────────

    def entries_from_grep(text):
        """grep -H output -> {path: {key: value}}. First value per key wins, which is
        correct because [Desktop Entry] precedes any [Desktop Action ...] group."""
        files = {}
        for line in text.splitlines():
            if ":" not in line:
                continue
            path, kv = line.split(":", 1)
            if "=" not in kv:
                continue
            k, v = kv.split("=", 1)
            files.setdefault(path, {}).setdefault(k.strip(), v.strip())
        return files


    def to_apps(files, hidden):
        out = []
        seen = set()
        for path, e in files.items():
            base = os.path.basename(path)
            if base in seen or base in hidden:
                continue
            seen.add(base)
            if (e.get("Type") != "Application" or not e.get("Exec")
                    or e.get("NoDisplay", "").lower() == "true"
                    or e.get("Hidden", "").lower() == "true"):
                continue
            out.append({"name": e.get("Name", base),
                        # The desktop-entry FILENAME, which is the only stable identity an
                        # application has here. `Name` is a display string: it is translated, it is
                        # chosen by upstream rather than by the packager, and nothing stops two
                        # entries from sharing one -- `org.kde.foo.desktop` and `foo.desktop` both
                        # calling themselves "Foo" is ordinary. A consumer that keys state on the
                        # display name therefore collapses them into one row, and whichever loses
                        # becomes unreachable.
                        #
                        # It costs nothing to emit: `base` is already computed above, and is
                        # already what the dedupe here keys on -- so this is publishing the
                        # identity this function ALREADY treats as authoritative, rather than
                        # inventing one.
                        "id": base,
                        "exec": e["Exec"],
                        "terminal": e.get("Terminal", "").lower() == "true",
                        # `Icon` was already in WANT and already fetched over the wire; it was
                        # simply dropped here, because rofi's script mode was the only consumer and
                        # this mode never rendered icons. A front-end that DOES render them needs
                        # the name, and `rlaunch-icons` has always synced the matching remote icon
                        # FILES into the local hicolor theme, so a name is all it needs.
                        "icon": e.get("Icon", ""),
                        "cats": [c for c in e.get("Categories", "").split(";") if c]})
        return sorted(out, key=lambda a: a["name"].lower())


    def fetch_local(hidden):
        args = []
        for d in LOCAL_DIRS:
            args += glob.glob(os.path.join(os.path.expanduser(d), "*.desktop"))
        if not args:
            return []
        p = subprocess.run(["grep", "-H", "-E", WANT] + args,
                           capture_output=True, text=True)
        return to_apps(entries_from_grep(p.stdout), hidden)


    def fetch_remote(host, ttl, hidden):
        """Live read, with a short-lived cache. Returns (apps, error_or_None)."""
        os.makedirs(RUN, exist_ok=True)
        cache = os.path.join(RUN, f"{host['name']}.json")
        if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < ttl:
            try:
                with open(cache) as f:
                    return json.load(f), None
            except (OSError, ValueError):
                pass
        # Wrapped in `sh -c` and using find, NOT shell globs: the remote login shell
        # may be fish, which aborts the whole command on a wildcard that matches
        # nothing — and /run/current-system only exists on the NixOS hosts.
        inner = (f"find {' '.join(REMOTE_DIRS)} -name '*.desktop' "
                 f"-exec grep -H -E '{WANT}' {{}} + 2>/dev/null")
        p = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host["ssh"],
             "sh -c " + shlex.quote(inner)],
            capture_output=True, text=True)
        if not p.stdout.strip():
            err = (p.stderr.strip().splitlines() or ["no applications found"])[-1]
            return [], err
        apps = to_apps(entries_from_grep(p.stdout), hidden)
        try:
            with open(cache, "w") as f:
                json.dump(apps, f)
        except OSError:
            pass
        return apps, None


    def inventory(c, host):
        hidden = set(c.get("hide", {}).get("desktop_files", []))
        if host.get("local"):
            return fetch_local(hidden), None
        return fetch_remote(host, c.get("layout", {}).get("cache_ttl", 60), hidden)


    # ── launching ────────────────────────────────────────────────────────────────

    def launch(app, host, layout):
        """Local: run it. Remote: hand it to that peer's own nixremote forward
        wrapper, which owns the address cascade, audio return, video codec, orphan
        reaping and origin marking. Nothing about waypipe is decided here."""
        cmd = FIELD_CODES.sub("", app["exec"]).strip()
        argv = shlex.split(cmd)
        if app["terminal"]:
            argv = shlex.split(layout.get("terminal", "foot")) + argv
        if not host.get("local"):
            argv = [host["launch"]] + argv
        subprocess.Popen(argv, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


    def resolve_typed(c, text, default_host):
        """`firefox` -> the tab you are in. `firefox.archlxc` / `firefox@archlxc` ->
        that host. Parsed right-to-left, and the suffix must EXACTLY match a
        configured host — otherwise `org.telegram.desktop` would resolve to a host
        called 'desktop'."""
        hosts = {h["name"]: h for h in c["hosts"]}

        def find(name, host):
            apps, _ = inventory(c, host)
            low = name.lower()
            for a in apps:                                # 1. exact name
                if a["name"].lower() == low:
                    return a
            for a in apps:                                # 2. name prefix
                if a["name"].lower().startswith(low):
                    return a
            for a in apps:                                # 3. name contains
                if low in a["name"].lower():
                    return a
            for a in apps:                                # 4. last resort: the binary
                if low == os.path.basename(a["exec"].split()[0]).lower():
                    return a
            return None

        for sep in (".", "@"):
            if sep in text:
                head, tail = text.rsplit(sep, 1)
                if tail in hosts and head:
                    hit = find(head, hosts[tail])
                    if hit:
                        return hit, hosts[tail]
                    break   # suffix looked like a host but nothing matched there;
                            # fall through and try the whole string in this tab, so
                            # an app literally named foo.<hostname> still launches
        return find(text, default_host), default_host


    # ── the mode ─────────────────────────────────────────────────────────────────

    def bucket(app, cats, assigns):
        # THE OVERRIDES RUN FIRST, and they exist because `Categories=` is written by whoever
        # packaged the application, not by whoever uses it. Two live examples: Moonlight declares
        # `Qt;Game;` when what it does is drive another machine's desktop, and Zoom declares
        # `Network;Application;` when it is a chat client. Both are defensible readings of the
        # spec and both put the application somewhere nobody would look for it, and no reordering
        # of the tag table fixes either -- the tag that would carry the right answer is simply
        # not there.
        for a in assigns:
            m = a.get("match", "").lower()
            if m and (m in app["id"].lower() or m in app["name"].lower()):
                return a["label"]
        for c in cats:
            if any(t in app["cats"] for t in c["tags"]):
                return c["label"]
        return "Other"


    def main():
        # NOTE for anyone editing this Python: it lives inside a Nix indented string, where two
        # adjacent single quotes END that string. Always use "" for an empty literal here — a
        # Python empty single-quoted literal terminates the Nix string and the error it produces
        # points at a line far away from the one that caused it.
        retv = int(os.environ.get("ROFI_RETV", 0))
        state = os.environ.get("ROFI_DATA", "")
        log(f"RETV={retv} DATA=[{state}] argv={sys.argv[1:]}")
        c = cfg()

        # Leading flags are stripped before the positional arguments, because rofi APPENDS the
        # selection to whatever command line the mode was declared with — so the flag has to sit
        # in front of the host name, where rofi will never touch it.
        args = sys.argv[1:]
        flat = False
        as_json = False
        while args and args[0].startswith("--"):
            f = args.pop(0)
            if f == "--flat":
                flat = True
            elif f == "--json":
                as_json = True

        hosts = {h["name"]: h for h in c["hosts"]}
        fallback = next(h for h in c["hosts"] if h.get("local"))
        host = hosts.get(args[0] if args else "", fallback)
        sel = args[1] if len(args) > 1 else ""
        cats = c.get("categories", [])
        assigns = c.get("assign", [])
        layout = c.get("layout", {})

        typed_error = ""
        if retv == 2 and sel:                             # typed, not selected
            # Default to the host whose tab we are in, so a bare `helix` in the
            # devhome tab means devhome, not local.
            app, h = resolve_typed(c, sel, host)
            if app:
                launch(app, h, layout)
                return
            typed_error = f"no app matching <b>{sel}</b> on <b>{h['name']}</b>"

        apps, err = inventory(c, host)
        grouped = {}
        for a in apps:
            grouped.setdefault(bucket(a, cats, assigns), []).append(a)
        order = [k for k in [c["label"] for c in cats] + ["Other"] if k in grouped]

        # ── THE SEAM: the same inventory, without rofi's protocol wrapped around it ───────────
        # A front-end that is not rofi needs exactly what the code above just computed -- this
        # host's real applications, already deduplicated, already bucketed into the operator's own
        # folder table, already in the operator's own folder ORDER -- and needs it without
        # re-implementing the SSH round trip, the cache, or the grouping. Emitting it here rather
        # than from a second entry point is what keeps the two front-ends honest: there is one
        # inventory path, and a divergence between what rofi shows and what anything else shows is
        # not expressible.
        #
        # `err` is carried rather than raised. An unreachable peer is a normal, frequent state on a
        # roaming laptop, and a front-end wants to draw the tab greyed out with a reason on it, not
        # to be handed an empty list it cannot distinguish from "this machine has no apps".
        if as_json:
            json.dump({
                "host": host["name"],
                "error": err,
                "folders": [
                    {"label": k, "apps": [
                        {"id": a.get("id", a["name"]), "name": a["name"],
                         "icon": a.get("icon", ""),
                         "exec": a["exec"], "terminal": a["terminal"]}
                        for a in grouped[k]]}
                    for k in order
                ],
            }, sys.stdout)
            sys.stdout.write("\n")
            return

        def show_categories(note=""):
            meta("prompt", host["name"])
            if note:
                meta("message", note)
            elif err:
                meta("message", f"<b>{host['name']}</b> unreachable — {err}")
            else:
                meta("message",
                     f"<b>{host['name']}</b> — {len(order)} groups, {len(apps)} apps")
            for k in order:
                print(f"{k}  ({len(grouped[k])})")

        def show_apps(cat):
            print(f"{NUL}data{ESC}{cat}")
            meta("prompt", f"{host['name']}/{cat}")
            meta("message", f"<b>{cat}</b> on <b>{host['name']}</b> — "
                            f"{len(grouped.get(cat, []))} apps")
            print(BACK)
            for a in grouped.get(cat, []):
                print(a["name"])

        # FLAT MODE: every application at once, no groups to drill into. This is the shape a
        # keystroke-launcher wants — you already know the name, you are typing it, and a category
        # list is a screen of things you have to dismiss first. The grouped view stays for the
        # other question ("what does this machine even have?"), which is what the bar button is
        # for.
        def show_flat(note=""):
            meta("prompt", host["name"])
            meta("message", note or f"<b>{host['name']}</b> — {len(apps)} apps")
            for a in apps:
                print(a["name"])

        if flat:
            if typed_error:
                show_flat(typed_error)
                return
            if retv == 1 and sel:
                for a in apps:
                    if a["name"] == sel:
                        launch(a, host, layout)
                        return
                # An unrecognised pick is not necessarily a miss: with `-matching fuzzy` the row
                # text can differ from any exact name. Fall back to the same resolver typing uses,
                # so a selection never silently does nothing.
                app, h = resolve_typed(c, sel, host)
                if app:
                    launch(app, h, layout)
                    return
                show_flat(f"no app matching <b>{sel}</b>")
                return
            show_flat()
            return

        if typed_error:
            show_categories(typed_error)
            return

        if state and retv == 1 and sel:                   # inside a category
            if sel == BACK:
                show_categories()
                return                                    # no data line -> state cleared
            for a in grouped.get(state, []):
                if a["name"] == sel:
                    launch(a, host, layout)
                    return
            show_apps(state)                              # unknown pick: never exit silently
            return

        if retv == 1 and sel:                             # a category was picked
            cat = sel.split("  (")[0]
            if cat in grouped:
                show_apps(cat)
            else:
                show_categories(f"no group <b>{cat}</b> on <b>{host['name']}</b>")
            return

        show_categories()


    if __name__ == "__main__":
        try:
            main()
        except Exception:
            import traceback
            log("CRASH " + traceback.format_exc().replace("\n", " | "))
            raise
  '';

  rlaunchIcons = pyScript "rlaunch-icons" ''
    """rlaunch-icons <host> — pull the icons a remote machine has and we do not.

    Most icons already resolve locally, because both boxes install many of the same
    apps. Only the remote-ONLY ones need fetching, so this does nothing at all for
    the common case and stays cheap.

    Installed under THREE names, because the consumer decides which one it looks up:
    a dock resolves a task by the window's app_id, rofi uses Icon=, and the two are
    frequently different (Icon=io.github.qarmin.krokiet vs app_id=krokiet). Writing
    all three costs a few KB and removes the guess.

    GENERATED by nixremote's homeManagerModules.launcher. Do not edit.
    """
    import base64
    import os
    import re
    import shlex
    import subprocess
    import sys
    import tomllib

    CONF = ${builtins.toJSON "${config.xdg.configHome}/rlaunch/config.toml"}
    HICOLOR = os.path.expanduser("~/.local/share/icons/hicolor")
    LOCAL_ICON_ROOTS = [os.path.expanduser("~/.local/share/icons"),
                        "/usr/share/icons", "/usr/share/pixmaps",
                        "/run/current-system/sw/share/icons"]
    SEARCH = ["/run/current-system/sw/share/icons", "/usr/share/icons",
              "/usr/share/pixmaps", "$HOME/.local/share/icons",
              "/etc/profiles/per-user/*/share/icons"]
    SIZE_RE = re.compile(r"/(\d+)x\d+/")
    EXTS = (".svg", ".png", ".xpm")


    def local_icon_names():
        """Every icon basename this machine can already resolve.

        A filesystem scan rather than Gtk.IconTheme.has_icon: the answer is the same
        for this purpose, and it removes a PyGObject import that is not present on
        every distro this module runs on — an ImportError here would abort an
        entirely optional background task.
        """
        have = set()
        for root in LOCAL_ICON_ROOTS:
            if not os.path.isdir(root):
                continue
            for _dirpath, _dirnames, files in os.walk(root):
                for f in files:
                    stem, ext = os.path.splitext(f)
                    if ext in EXTS:
                        have.add(stem)
        return have


    def ssh(host, cmd):
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                               host, "sh -c " + shlex.quote(cmd)],
                              capture_output=True, text=True).stdout


    def rank(path):
        """Prefer scalable SVG, then the largest raster."""
        if path.endswith(".svg"):
            return 10_000
        m = SIZE_RE.search(path)
        return int(m.group(1)) if m else 1


    def main():
        host_name = sys.argv[1]
        with open(CONF, "rb") as f:
            conf = tomllib.load(f)
        host = next((h for h in conf["hosts"] if h["name"] == host_name), None)
        if not host or not host.get("ssh"):
            sys.exit(f"no ssh host named {host_name}")

        # 1. what does that machine reference, and what do we already have?
        want = "^(Icon|Exec|Type|NoDisplay|Hidden)="
        dirs = ["/usr/share/applications", "$HOME/.local/share/applications",
                "/run/current-system/sw/share/applications",
                "/etc/profiles/per-user/*/share/applications"]
        out = ssh(host["ssh"], f"find {' '.join(dirs)} -name '*.desktop' "
                               f"-exec grep -H -E '{want}' {{}} + 2>/dev/null")
        files = {}
        for line in out.splitlines():
            if ":" not in line:
                continue
            path, kv = line.split(":", 1)
            if "=" not in kv:
                continue
            k, v = kv.split("=", 1)
            files.setdefault(path, {}).setdefault(k.strip(), v.strip())

        have = local_icon_names()
        wanted = {}                       # icon name -> [aliases to install it under]
        for path, e in files.items():
            if e.get("Type") != "Application" or e.get("NoDisplay", "").lower() == "true":
                continue
            ic = e.get("Icon")
            if not ic:
                continue
            base = os.path.basename(path)[:-len(".desktop")]
            binary = os.path.basename(e.get("Exec", "").split()[0]) if e.get("Exec") else ""
            stem = (ic if not ic.startswith("/")
                    else os.path.splitext(os.path.basename(ic))[0])
            names = {n for n in (stem, base, binary) if n}
            # THE ORIGIN-TAGGED NAMES, which are the whole reason a dock shows a
            # placeholder for a forwarded window. nixremote's forward wrapper rewrites
            # an app's own id to "<app>@<peer>" so the compositor can mark where the
            # window came from -- and an icon lookup is BY THAT ID. No icon theme has
            # ever heard of "foot@devhome", so a taskbar or dock falls through to its
            # own icon-missing artwork, which reads as an error rather than as a
            # window from another machine.
            #
            # Writing each alias a second time under "<alias>@<host>" closes that: the
            # forwarded window finds the same icon its local twin uses. Costs one extra
            # copy of a few-KB svg per app, and only for apps this host does not
            # already have -- the local-shadowing guard below applies to these too.
            names |= {f"{n}@{host_name}" for n in names}
            # PER-ALIAS, not all-or-nothing. Skipping an app only when EVERY alias
            # resolved meant one missing alias caused all of them to be written,
            # which shadowed local system icons (foot, thunar, Nautilus...) with a
            # remote host's copies — a user icon dir outranks /usr/share, so that
            # silently replaced native app icons.
            missing = sorted(n for n in names if n not in have)
            if not missing:
                continue
            wanted[ic] = missing

        if not wanted:
            print("  nothing to fetch — every icon already resolves locally")
            return

        # 2. ask the remote where those files live
        names = [n for n in wanted if not n.startswith("/")]
        paths_abs = [n for n in wanted if n.startswith("/")]
        finder = ""
        if names:
            pat = " -o ".join(f"-name {shlex.quote(n + ext)}"
                              for n in names for ext in EXTS)
            finder = f"find {' '.join(SEARCH)} \\( {pat} \\) 2>/dev/null"
        listing = ssh(host["ssh"], finder) if finder else ""
        candidates = [p for p in listing.splitlines() if p.strip()] + paths_abs

        best = {}
        for name in wanted:
            if name.startswith("/"):
                best[name] = name
                continue
            opts = [p for p in candidates
                    if os.path.splitext(os.path.basename(p))[0] == name]
            if opts:
                best[name] = max(opts, key=rank)

        if not best:
            print(f"  {len(wanted)} missing, none found on {host_name}")
            return

        # 3. pull them (base64, one round trip — icons are a few KB each)
        dump = "; ".join(f"echo '===FILE {p}'; base64 {shlex.quote(p)}"
                         for p in best.values())
        blob = ssh(host["ssh"], dump)

        data, cur = {}, None
        for line in blob.splitlines():
            if line.startswith("===FILE "):
                cur = line[len("===FILE "):].strip()
                data[cur] = []
            elif cur:
                data[cur].append(line)

        n = 0
        for name, src in best.items():
            chunks = data.get(src)
            if not chunks:
                continue
            try:
                raw = base64.b64decode("".join(chunks))
            except Exception:
                continue
            ext = os.path.splitext(src)[1] or ".png"
            if ext == ".svg":
                sub = "scalable/apps"
            else:
                m = SIZE_RE.search(src)
                sub = f"{m.group(1)}x{m.group(1)}/apps" if m else "48x48/apps"
            d = os.path.join(HICOLOR, sub)
            os.makedirs(d, exist_ok=True)
            for alias in wanted[name]:
                with open(os.path.join(d, alias + ext), "wb") as f:
                    f.write(raw)
                n += 1
        subprocess.run(["gtk-update-icon-cache", "-f", "-q", HICOLOR],
                       capture_output=True)
        with open(os.path.join(HICOLOR, ".rlaunch-manifest"), "a") as mf:
            for name in best:
                for alias in wanted[name]:
                    mf.write(alias + "\n")
        print(f"  fetched {len(best)} icons from {host_name}, wrote {n} files "
              f"(name + desktop-id + binary aliases)")


    if __name__ == "__main__":
        main()
  '';

  remoteHosts = lib.filter (h: !h.local) resolvedHosts;
  firstHost = if cfg.hosts == [ ] then "local" else (lib.head cfg.hosts).name;
  localHost =
    let l = lib.filter (h: h.local) cfg.hosts;
    in if l == [ ] then "local" else (lib.head l).name;

  # The quick view's theme is the same slab with the tab bar taken out of `children:`. Removing it
  # is not cosmetic tidying: rofi still DRAWS a mode-switcher for a single mode, so leaving it in
  # gives a flat launcher one full-width button labelled with the machine you are already on.
  # The quick view uses the SAME theme as the full one. It briefly did not: while it declared a
  # single mode, the tab bar was a button naming the machine you were already on, so the theme
  # removed it. Now that every machine is a tab again the switcher carries real information, and a
  # second theme would only be a second thing to keep in sync.
  quickThemeText = themeText;
  quickThemeFile = themeFile;

  showText = ''
    # Entry point: one rofi mode per configured machine, and a background warm of
    # every remote inventory so a tab click usually lands on data that is already
    # there. GENERATED by nixremote's homeManagerModules.launcher.
    set -u
    ${lib.concatMapStringsSep "\n" (h: ''
      ROFI_RETV=0 ${rlaunch}/bin/rlaunch ${lib.escapeShellArg h.name} >/dev/null 2>&1 &
      ${lib.optionalString cfg.iconSync.enable
        "${rlaunchIcons}/bin/rlaunch-icons ${lib.escapeShellArg h.name} >/dev/null 2>&1 &"}
    '') remoteHosts}

    exec ${cfg.rofiCommand} \
      -show ${lib.escapeShellArg firstHost} \
      -modi ${lib.escapeShellArg (lib.concatMapStringsSep "," (h: "${h.name}:${rlaunch}/bin/rlaunch ${h.name}") cfg.hosts)} \
      -theme ${themeFile}
  '';

  show = pkgs.writeShellScriptBin "rlaunch-show" showText;

  # ── the quick view ──────────────────────────────────────────────────────────────────────────
  #
  # THE OTHER QUESTION. `rlaunch-show` above answers "what does this machine have?" — categories,
  # discovery, browsing. This answers "open the thing I am already typing", which wants an opposite
  # shape: one flat list, no groups to dismiss, and open NOW.
  #
  # WHAT IT DROPS IS THE CATEGORIES, AND ONLY THE CATEGORIES. Every machine is still a tab and
  # still reachable, because "no categories" and "no other machines" are entirely different
  # reductions and only the first one was ever wanted. An earlier version of this declared the
  # local mode alone, reasoning that a keystroke launcher should not fire SSH round trips on every
  # press — which is true of the WARM-UP and false of the tabs. The result was a launcher that had
  # silently forgotten the other machines, and it was only wrong on the keystroke, not on the bar
  # button, which is a genuinely confusing way for a launcher to behave.
  #
  # SO: all the modes, and no warm-up. Opening costs a filesystem read of the local inventory and
  # nothing else; a peer's inventory is fetched at the moment its tab is actually clicked. Typing
  # `firefox.archlxc` still resolves through the same dot-notation path either way.
  quickText = ''
    # GENERATED by nixremote's homeManagerModules.launcher. The quick, FLAT view -- see the
    # module's own header for what it drops and, just as importantly, what it does not.
    exec ${cfg.rofiCommand} \
      -show ${lib.escapeShellArg localHost} \
      -modi ${lib.escapeShellArg (lib.concatMapStringsSep "," (h: "${h.name}:${rlaunch}/bin/rlaunch --flat ${h.name}") cfg.hosts)} \
      -theme ${quickThemeFile}
  '';

  quick = pkgs.writeShellScriptBin "rlaunch-quick" quickText;

  # `{ config, ... }` and no `name`: a `listOf submodule` passes no `name` argument (only
  # `attrsOf` does), which is why the tab's own name is a stated option here rather than a key.
  hostModule = { config, ... }: {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Tab label, and the suffix `<app>.<name>` resolves against.";
      };

      local = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this tab is THIS machine. A local tab reads `.desktop` files off the local disk
          and runs what you pick directly; every other tab goes over SSH and through a forward
          wrapper. Exactly one host must set this.
        '';
      };

      forward = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if config.local then null else config.name;
        description = ''
          Which `nixremote.forward.<peer>` this tab launches through. `ssh` and `launch` are both
          derived from it, so a peer that is already forwardable needs nothing else stated.

          Set to null and supply `ssh`/`launch` by hand only for a machine that is deliberately
          not a forward peer — a case that mostly does not exist, since a machine you cannot
          forward from is a machine whose applications you can list but never open.
        '';
      };

      ssh = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          SSH destination used to READ this machine's inventory (and its icons). Defaults to the
          referenced peer's `sshAlias`, which is the alias nixremote's own generated SSH config
          already resolves through the address cascade — so listing and launching take the same
          route, and a machine that has moved onto the overlay does not become listable but
          unlaunchable.
        '';
      };

      launch = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The command a remote launch is prefixed with. Defaults to the referenced peer's
          `scriptName` — nixremote's own forward wrapper. See this module's header for everything
          that wrapper owns and this launcher therefore does not.
        '';
      };
    };
  };

  assignModule = {
    options = {
      match = lib.mkOption {
        type = lib.types.str;
        description = ''
          Case-insensitive SUBSTRING of the `.desktop` basename or the display name. The shortest
          unambiguous word wins, so `moonlight` catches `com.moonlight_stream.Moonlight.desktop`
          without anyone needing to know the reverse-DNS spelling a packager chose.
        '';
      };
      label = lib.mkOption {
        type = lib.types.str;
        description = ''
          The group it goes in. Nothing checks this against `categories`: a label with no matching
          category is a group of its own, which is occasionally what you want and always visible
          on screen if it is not.
        '';
      };
    };
  };

  categoryModule = {
    options = {
      label = lib.mkOption {
        type = lib.types.str;
        description = "Group heading shown in the launcher.";
      };
      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          `.desktop` `Categories=` values that fall into this group. Not restricted to the XDG
          registered set — an application may declare anything, and matching whatever they actually
          declare is the point.
        '';
      };
    };
  };
in
{
  options.nixremote.launcher = {
    enable = lib.mkEnableOption ''
      rlaunch, an application launcher whose tabs are machines: each tab lists a peer's real
      application inventory, read live off its own .desktop files, and launches through that peer's
      `nixremote.forward` wrapper
    '';

    interpreter = lib.mkOption {
      type = lib.types.str;
      default = "/usr/bin/env python3";
      example = "/nix/store/…-python3-3.12.8/bin/python3";
      description = ''
        What runs the generated scripts — written verbatim onto their shebang lines.

        This module installs no interpreter, the same way the rest of this repo installs no
        compositor: the default suits every distro that ships Python in its base system, and a
        NixOS consumer (where `/usr/bin/env python3` does not resolve) sets
        `"''${pkgs.python3}/bin/python3"`. The scripts are still syntax-checked at BUILD time with
        a real Python regardless of what ends up on the shebang.
      '';
    };

    rofiCommand = lib.mkOption {
      type = lib.types.str;
      default = "rofi";
      description = ''
        How to invoke rofi. A bare name resolves through $PATH; give an absolute path on a host
        where the launcher runs from a systemd unit with a restricted environment.

        rofi specifically, and not a sharper alternative: it is the only menu with a
        MODE-SWITCHER, which is what makes machines into clickable tabs at all. fuzzel and wofi
        render more crisply on a fractional-scale output and can do none of this.
      '';
    };

    terminal = lib.mkOption {
      type = lib.types.str;
      default = "foot";
      description = ''
        Terminal used to run an application whose `.desktop` entry sets `Terminal=true`. Prefixed
        to that application's own command, locally or remotely — so the REMOTE machine needs this
        terminal installed, not this one.
      '';
    };

    tabs = lib.mkOption {
      type = lib.types.enum [ "horizontal" "vertical" ];
      default = "horizontal";
      description = ''
        Whether the machine tabs run across the top or down the left. Horizontal reads as a tab
        bar and costs no width; vertical gives each machine a full-width row, which stays legible
        with more machines than fit across a narrow window.
      '';
    };

    cacheTtl = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Seconds a fetched remote inventory stays usable. This is a CACHE, not a store: it lives in
        `$XDG_RUNTIME_DIR` and dies with the boot, and the remote machine's own `.desktop` files
        remain the only source of truth. Long enough that clicking through several tabs costs one
        SSH round trip each; short enough that installing something on another machine shows up
        while you still remember doing it.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule hostModule);
      default = [ ];
      example = lib.literalExpression ''
        [ { name = "local"; local = true; }
          { name = "archlxc"; }
          { name = "devhome"; }
        ]
      '';
      description = ''
        The tabs, IN ORDER. The first is the one the launcher opens on.

        A list rather than an attrset because the order is visible and meaningful — an attrset
        would silently alphabetise the tab bar. Every entry but the local one refers to a
        `nixremote.forward` peer of the same name by default, so a machine that is already a
        forward peer needs only its name here.
      '';
    };

    hide = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "avahi-discover.desktop" "qv4l2.desktop" ];
      description = ''
        `.desktop` file basenames to leave out of every machine's list.

        Matched on the FILENAME rather than on `Name=`, because the filename is the stable
        identifier — a display name is localised and can change with a package update. Applications
        that set `NoDisplay=true` or `Hidden=true` are already excluded and need no entry here;
        this is for the ones that ask to be shown but that nobody wants to see.
      '';
    };

    categories = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule categoryModule);
      default = [ ];
      example = lib.literalExpression ''
        [ { label = "Terminals"; tags = [ "TerminalEmulator" ]; }
          { label = "Code";      tags = [ "Development" ]; }
        ]
      '';
      description = ''
        How applications are grouped, IN PRIORITY ORDER — the FIRST group whose tags match wins,
        so specific tags must come before broad ones. `TerminalEmulator` before `System`, or every
        terminal lands in System.

        A list, not an attrset, for exactly that reason: an attrset would alphabetise the priority
        order and quietly change which group an application falls into.

        Anything unmatched lands in a group called `Other`, which is always last and needs no
        entry. An empty list therefore puts everything in `Other` — usable, but the categories are
        where a several-hundred-application list becomes navigable.
      '';
    };

    assign = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule assignModule);
      default = [ ];
      example = lib.literalExpression ''
        [ { match = "moonlight"; label = "Remote"; }
          { match = "zoom";      label = "Chat"; }
        ]
      '';
      description = ''
        Applications whose `Categories=` is wrong, and where they actually go. Checked BEFORE
        `categories`, so an entry here beats every tag the application declares.

        This is an escape hatch and it earns its place: `Categories=` is written by whoever built
        the package, and no amount of reordering the tag table can fix an entry whose tags simply
        do not include the fact you care about. Moonlight declares `Qt;Game;` — true, and useless
        to someone looking for the thing that drives another machine's desktop. Zoom declares
        `Network;Application;` — also true, and it is a chat client.

        Keep it short. A long list here means the `categories` table is fighting the data rather
        than reading it, and the tag table is the thing that scales.
      '';
    };

    iconSync = {
      enable = lib.mkEnableOption ''
        fetching icons a remote machine has and this one does not, in the background when the
        launcher opens. Without it a remote-only application shows up with a generic placeholder,
        because the icon NAME in its .desktop file resolves against the LOCAL icon theme
      '';
    };

    theme = {
      variables = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          ground = "#0A0A0A";
          surface = "#1A1A1A";
          fg = "#F0F0F0";
          bright = "#FFFFFF";
          accent = "#22C55E";
          prompt-fg = "#B91322";
          muted = "rgba(255, 255, 255, 0.10)";
        };
        description = ''
          rasi variables, written verbatim into the generated theme's `*` block and referenced as
          `@name` by the structural rules. `ground`, `surface`, `fg`, `bright`, `accent`,
          `prompt-fg` and `muted` are the ones those rules use; anything else you add is available
          to `theme.extra`.

          The default is a working dark set so the launcher is usable out of the box, NOT a house
          palette — override it with whatever the rest of your desktop already uses, so this looks
          like part of the same product rather than a second one.
        '';
      };

      font = lib.mkOption {
        type = lib.types.str;
        default = "monospace 11";
        example = "Geist Mono 11";
        description = "Pango font description for the whole window.";
      };

      width = lib.mkOption {
        type = lib.types.str;
        default = "46%";
        description = ''
          Window width, as a rasi length — a percentage of the output, or an absolute `800px`.
          Vertical tabs want more of it, since the switcher takes a fixed column out of the middle.
        '';
      };

      tabWidth = lib.mkOption {
        type = lib.types.ints.positive;
        default = 150;
        description = "Width of the machine column, in px. Vertical tabs only.";
      };

      lines = lib.mkOption {
        type = lib.types.ints.positive;
        default = 12;
        description = "Visible rows in the application list before it scrolls.";
      };

      placeholder = lib.mkOption {
        type = lib.types.str;
        default = "type to filter";
        description = ''
          Ghost text in the input box. Worth stating, because typing does more than filter here:
          `<app>.<machine>` launches on that machine directly, without touching the tabs.
        '';
      };

      extra = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Raw rasi appended to the generated theme, for anything the options above do not reach.";
      };
    };

    # ── what this module actually produced ──────────────────────────────────────────────────────
    #
    # Published read-only so it can be inspected with `nix eval` and asserted on WITHOUT reading
    # anything back out of the store. That is not a stylistic preference: the config file and the
    # theme are derivations, so reading their text is import-from-derivation, which a `nix flake
    # check --no-build` cannot realise — a test written that way fails with `path ... is not valid`
    # rather than with anything about the launcher.
    rendered = {
      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        readOnly = true;
        default = resolvedHosts;
        description = ''
          The tabs with `ssh` and `launch` filled in from each one's `nixremote.forward` peer. This
          is what the generated config is built from, so it is where to look when a tab lists
          nothing (wrong `ssh`) or launches nothing (wrong `launch`).
        '';
      };

      theme = lib.mkOption {
        type = lib.types.lines;
        readOnly = true;
        default = themeText;
        description = "The generated rasi, as text.";
      };

      entry = lib.mkOption {
        type = lib.types.lines;
        readOnly = true;
        default = showText;
        description = "The generated entry point, as text: the mode list, the warm-up, the rofi call.";
      };

      quick = lib.mkOption {
        type = lib.types.lines;
        readOnly = true;
        default = quickText;
        description = "The quick view's entry point, as text.";
      };

      quickTheme = lib.mkOption {
        type = lib.types.lines;
        readOnly = true;
        default = quickThemeText;
        description = "The quick view's rasi, as text: the same slab with the tab bar removed.";
      };
    };

    quickCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${quick}/bin/rlaunch-quick";
      description = ''
        The QUICK view's entry point, as an absolute path: one flat list of this machine's own
        applications, no tabs and no categories, and no remote inventory fetched on open.

        Bind this to a keystroke, and bind `command` to a bar button or a dock icon. They answer
        different questions — this one assumes you already know the name and are typing it, while
        `command` is for finding out what a machine has. Typing `<app>.<machine>` here still
        launches on that machine, so nothing is given up by making the fast path the local one.

        This is the intended replacement for a separate lightweight launcher (fuzzel, wofi) bound
        to the same key: one launcher, one theme, one set of hidden-application rules.
      '';
    };

    command = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${show}/bin/rlaunch-show";
      description = ''
        The launcher's entry point, as an absolute path. Bind a key or a bar button to this rather
        than to `rofi` directly: it builds the mode list, warms every remote inventory in the
        background so the first tab click is not a cold SSH round trip, and applies the generated
        theme.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length (lib.filter (h: h.local) cfg.hosts) == 1;
        message = ''
          nixremote.launcher.hosts must contain exactly one entry with `local = true` (found ${
            toString (lib.length (lib.filter (h: h.local) cfg.hosts))
          }). The local tab is what the launcher falls back to when a mode name does not resolve,
          and it is where a typed name with no `.<machine>` suffix is looked up.
        '';
      }
    ]
    ++ (map
      (h: {
        assertion = h.forward == null || forwardPeers ? ${h.forward};
        message = ''
          nixremote.launcher: host "${h.name}" refers to forward peer "${toString h.forward}",
          which is not defined in nixremote.forward (known: ${
            lib.concatStringsSep ", " (lib.attrNames forwardPeers)
          }). A tab whose peer does not exist would list applications it can never launch.
        '';
      })
      (lib.filter (h: !h.local) cfg.hosts))
    ++ (map
      (h: {
        assertion = h.local || (h.ssh != null || h.forward != null);
        message = ''
          nixremote.launcher: host "${h.name}" is not local and names no forward peer, so there is
          no way to read its inventory. Set `forward`, or set `ssh` and `launch` explicitly.
        '';
      })
      cfg.hosts);

    home.packages = [ rlaunch show quick ] ++ lib.optional cfg.iconSync.enable rlaunchIcons;

    xdg.configFile."rlaunch/config.toml".source = configFile;
  };
}

{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "dc-ranked_queue -- Discord bot that runs a player queue and builds balanced teams. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the other forty, and a
  # hardcoded system list this repo cannot edit. That list is currently broken:
  # it still contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed set: adding a second input later would
    # otherwise fail with "called with unexpected argument '<name>'".
    #
    # `self` is bound on purpose. It is this flake's own source snapshot in the
    # store, and it is the only thing a command can anchor to when it was
    # invoked as `nix run /path/to/repo#verb` from an unrelated directory --
    # there is no runtime handle on the work tree in that case. See
    # rootPreamble. The cost is that touching any tracked file rebuilds the
    # wrappers (shellcheck reruns, ~1s); the benefit is that no verb can ever
    # read or write the caller's files.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # This repo is two Python files. `bot.py`'s only third-party import is
      # `discord`; everything else it touches (asyncio, logging, time, os) is
      # stdlib, and `logger`/`config` are local modules. discord.py is packaged
      # in nixpkgs, so the ENTIRE dependency set is expressible right here --
      # which is why there is deliberately no `setup` verb, no uv and no .venv,
      # and why this shell works with no network at all.
      #
      # Do not "modernise" that into uv + requirements.txt: the repo has no
      # manifest to pin against, so writing one would invent a second source of
      # truth for a single dependency. If a future dependency is genuinely absent
      # from nixpkgs, THEN add uv plus a `setup` verb described "(network)".
      #
      # Pin the interpreter by MAJOR (python313), never the rolling `python3`
      # alias: the default is already 3.14 territory, and discord.py's wheel and
      # native-extension support lags a new CPython by months.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        (pkgs.python313.withPackages (ps: [
          ps.discordpy
        ]))
        pkgs.ruff

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty, and that is the honest answer: every Python dependency here comes
      # from nixpkgs, already patchelf'd against the store, so there is no
      # manylinux wheel around to go looking for a libstdc++ that NixOS has no
      # /usr/lib to hold. Adding stdenv.cc.cc.lib "just in case" would export an
      # LD_LIBRARY_PATH that nothing reads, and LD_LIBRARY_PATH is a blunt
      # instrument that leaks into every binary launched from the shell.
      #
      # The moment someone does introduce a .venv full of pip wheels, this list
      # needs pkgs.stdenv.cc.cc.lib and pkgs.zlib.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # The bot reports itself exclusively through Logger's print() calls. On a
        # pipe -- which is what `nix run .#run` gives an unattended agent --
        # CPython buffers those in 8 KB blocks, so the log looks empty for
        # minutes and a live bot reads as a hung one.
        PYTHONUNBUFFERED = "1";
        # The interpreter lives in the store and cannot cache bytecode next to
        # it, so .pyc files here only ever litter the work tree.
        PYTHONDONTWRITEBYTECODE = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#run`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-run` actually runs.
      #
      # `build`, `test` and `setup` are OMITTED because this repo has no artifact
      # to produce, no test suite of any kind, and nothing to bootstrap. Absence
      # is information: `nix flake show` reports the truth, and a stub that
      # echoed "no tests here" would turn the command map into a liar. Add `test`
      # in the same commit as the first test.
      #
      # A bare `python` (rather than an absolute path) is correct in THIS repo
      # and only because there is no .venv: the sole interpreter on PATH is the
      # store one from `toolchain` above, on both surfaces. In a repo with a
      # venv the wrappers' PATH prepend makes the same bare name resolve
      # differently under `nix run` than inside `nix develop` -- which is why the
      # house rule there is to spell out "$REPO_ROOT/.venv/bin/python".
      commands = pkgs: {
        lint = {
          # "''${@:-$REPO_ROOT}" is the whole anchoring rule in one expansion:
          # explicit paths still win and are still forwarded one-arg-per-arg, but
          # no arguments means this repo rather than the caller's cwd. ruff walks
          # a directory itself, so the single anchored path IS the repo. Note the
          # deliberate absence of a `cd` in the two ruff verbs: the default is
          # already absolute, and staying put is what keeps a RELATIVE path the
          # caller typed (`dev-lint bot.py`) meaning what they typed.
          #
          # --no-cache closes the last hole in that anchoring: ruff puts
          # `.ruff_cache/` in its project root, and with no config file to find it
          # picks the CWD -- so even after the path was anchored, linting from
          # elsewhere still created a directory in the caller's tree. Pointing
          # RUFF_CACHE_DIR at $REPO_ROOT instead is not an option: on the store
          # snapshot ruff exits 2 ("Failed to initialize cache ... Read-only file
          # system") and reports nothing, which is a lying gate again. Two files
          # lint in milliseconds, so the cache buys nothing here anyway.
          description = "ruff check";
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          # The bare-"$@" version of this line rewrote source files in whatever
          # directory `nix run /path/to/repo#fmt` happened to be called from.
          # Same anchoring as lint, plus one guard: when we are defaulting to
          # $REPO_ROOT and that is the store snapshot (no work tree reachable
          # from here), say so in one line instead of letting ruff emit a
          # "Failed to write /nix/store/...: Read-only file system" per file.
          # Explicit paths skip the guard -- forwarding them is the contract.
          # --no-cache for the same reason as lint: `ruff format` writes the same
          # cwd-relative .ruff_cache/ that `ruff check` does.
          text = ''
            if [ "$#" -eq 0 ] && [ ! -w "$REPO_ROOT" ]; then
              echo "dev-fmt: $REPO_ROOT is not writable, so there is nothing here to rewrite." >&2
              echo "dev-fmt: that is this flake's store snapshot, which is what \$REPO_ROOT falls back to" >&2
              echo "dev-fmt: when no work tree for this repo is reachable from the cwd." >&2
              echo "dev-fmt: run it from inside the repo, or pass the paths to format explicitly." >&2
              exit 1
            fi
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
        run = {
          # $REPO_ROOT, not a bare bot.py: CPython puts the SCRIPT's directory on
          # sys.path, so anchoring the path is also what lets `logger` and
          # `config` import when an agent invokes this from a subdirectory.
          #
          # The `cd` is not cosmetic. bot.py constructs Logger(file_logging=True),
          # which opens "baselog_log_<asctime>.txt" RELATIVE TO THE CWD -- that is
          # what .gitignore's `*baselog*` line is for. Without the cd, `nix run
          # /path/to/repo#run` drops the bot's logs in the caller's directory.
          #
          # config.py is gitignored (see .gitignore's `*config*`) and holds
          # BOT_TOKEN plus the channel IDs, so this verb needs one to exist
          # locally and fails with a plain ImportError until it does. Nothing in
          # a flake can supply a Discord token -- and, because it is gitignored,
          # nothing puts it in the store snapshot either, so this verb only ever
          # really starts from a work tree. That is the honest boundary: from
          # anywhere else it stops on the missing import instead of half-running.
          description = "start the queue bot (needs a local, gitignored config.py)";
          text = ''
            cd "$REPO_ROOT"
            python "$REPO_ROOT/bot.py" "$@"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================
      # ...except that rootPreamble below is, right now, NOT byte-identical to
      # the other forty. It was the cwd-anchoring bug (see its comment), the fix
      # is repo-independent, and it belongs in all 41. Until it is there, this
      # header is aspirational for that one binding -- which is why it says so
      # rather than letting the next person diff two repos and distrust the
      # heading. Copy this rootPreamble verbatim into the rest; the only
      # per-repo work is the `commands` block above, whose verbs must default
      # their path argument to $REPO_ROOT in whatever way their tool spells it.

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT, and $REPO_ROOT is the ONLY thing a verb
      # may touch when it was given no arguments. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, so a verb that
      # defaults to `.` -- or to a bare `"$@"`, which is the same thing to every
      # tool here -- reads and REWRITES the caller's files. That was not
      # theoretical: `nix run /path/to/repo#fmt` from an unrelated directory
      # reformatted that directory, and `#lint` reported that directory's
      # findings (none at all, exit 0, in an empty one) while this repo's 29 went
      # unlooked-at. The flake-URL form is exactly what CI and a cold agent use.
      #
      # Resolution order. Offline, and both candidates are inside this repo:
      #   1. the git work tree we are standing in, but ONLY if it is THIS repo,
      #      proven by its flake.nix being byte-identical to the one this wrapper
      #      was built from. "Am I in some git repo" is not a check -- it is the
      #      bug above wearing a hat, and it is what makes a mutating verb pick
      #      a stranger's directory as its victim.
      #   2. otherwise ${self}: this flake's source snapshot in the store. It is
      #      the right answer for a read-only verb (same files, same findings as
      #      inside the repo) and the right failure for a mutating one -- ruff
      #      stops on "Read-only file system" instead of guessing.
      #
      # `$(<f)` rather than cmp/diff: a bash builtin, so this needs nothing on
      # PATH that runtimeInputs does not already guarantee.
      rootPreamble = ''
        REPO_ROOT="${self}"
        if _top="$(git rev-parse --show-toplevel 2>/dev/null)" &&
          [ -f "$_top/flake.nix" ] &&
          [ "$(<"$_top/flake.nix")" = "$(<"${self}/flake.nix")" ]; then
          REPO_ROOT="$_top"
        fi
        unset _top
        export REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `npm install`, no `dotnet restore`, no `read`, no `exec $SHELL`.
            # Bootstrapping in the hook makes a cold `nix develop -c pytest`
            # start downloading before it runs anything, on EVERY invocation --
            # the exact failure an unattended agent cannot diagnose. That is what
            # `dev-setup` is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "dc-ranked_queue dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}

{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "dc-ranked_queue -- Discord bot: players join a queue with buttons, and a full queue becomes two captain-drafted teams. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose. flake-utils would buy exactly one
  # thing here -- eachDefaultSystem -- and the canonical block below already has
  # it, as `forAllSystems`. In exchange it costs two more lock nodes (measured:
  # `nix flake metadata github:numtide/flake-utils --json` locks the nodes
  # ["root","systems"]) and a system list this repo cannot edit, which today is
  # [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ] --
  # x86_64-darwin included, and on this lock (nixpkgs 26.11.20260813.0e251e2)
  # every attribute of that system is a throw.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed set: adding a second input later would
    # otherwise fail with "called with unexpected argument '<name>'".
    #
    # `self` is mandatory, not decorative: the canonical block anchors every
    # verb on this flake's own source snapshot, which is the only handle a
    # command has on its repo when it was invoked as `nix run /path/to/repo#verb`
    # from an unrelated directory. See rootPreamble below.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # This repo is two tracked Python files. `git ls-files` is exactly
      # .gitignore README.md bot.py flake.lock flake.nix logger.py.
      #
      # bot.py's only third-party import is `discord` (`discord`,
      # `discord.ext.commands`, `discord.ui`); the rest is stdlib -- `asyncio`
      # in bot.py, `logging`/`time`/`os` in logger.py -- plus the local modules
      # `logger` and `config`. discord.py is packaged in nixpkgs at this lock
      # (python313Packages.discordpy is python3.13-discord.py-2.6.4), so the
      # ENTIRE dependency set is expressible right here -- which is why there is
      # deliberately no `setup` verb, no uv and no .venv, and why this shell
      # works with no network at all.
      #
      # Do not "modernise" that into uv + requirements.txt: the repo has no
      # manifest to pin against, so writing one would invent a second source of
      # truth for a single dependency. If a future dependency is genuinely
      # absent from nixpkgs, THEN add uv plus a `setup` verb described
      # "(network)".
      #
      # Pinned by MAJOR (python313), never the rolling `python3` alias, so the
      # interpreter cannot move under the repo when nixpkgs bumps its default:
      # at this lock `python3` is already 3.14.7 while `python313` is 3.13.15.
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
      # Empty, and that is the honest answer: there is no manylinux wheel
      # anywhere in this repo to go looking for a libstdc++ that NixOS has no
      # /usr/lib to hold -- every dependency is the nixpkgs build, already
      # linked against the store. Returning [ ] makes the canonical block emit
      # no LD_LIBRARY_PATH preamble at all, which is the point: LD_LIBRARY_PATH
      # is a blunt instrument that leaks into every binary launched from the
      # shell. If a .venv full of pip wheels ever appears here, this is the list
      # that would need pkgs.stdenv.cc.cc.lib.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. Anything that must READ an existing value
      # (LD_LIBRARY_PATH) or UNSET something (SOURCE_DATE_EPOCH) is the
      # canonical block's business, not this attrset's. What is here is applied
      # identically to the dev shell and to every `nix run` wrapper, so a
      # command cannot behave differently depending on how it was invoked.
      envVars = pkgs: {
        # The bot's only progress output is Logger's print() calls (console_log
        # defaults to True and bot.py's __main__ leaves it there), and CPython
        # block-buffers stdout when it is not a tty. Measured with this lock's
        # python313: a script that prints a line and then sleeps 3s, piped,
        # delivered that line only after the sleep; with PYTHONUNBUFFERED=1 it
        # arrived at once (sys.stdout.write_through flips False -> True). An
        # unattended `nix run .#run` is exactly the piped case, so without this
        # a live bot reads as a hung one.
        PYTHONUNBUFFERED = "1";
        # Measured: `python -c 'import logger'` in a work tree creates
        # __pycache__/ next to logger.py, and does not with this set. The
        # interpreter is a store path and cannot cache bytecode beside itself,
        # so the checkout is the only place those files can land -- which is
        # what .gitignore's `*pycache*` line is there to hide.
        PYTHONDONTWRITEBYTECODE = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. The canonical block turns this one attrset
      # into `apps` (so `nix run .#run` works), the `dev-*` wrappers on PATH
      # inside the shell, and `dev-help`. Nothing is written twice, so
      # `nix flake show` can never disagree with what `dev-run` actually runs.
      #
      # `build`, `test` and `setup` are OMITTED because this repo has no
      # artifact to produce, no test file of any kind (the tracked list above is
      # the whole repo) and nothing to bootstrap. Absence is information: a stub
      # that echoed "no tests here" would turn the command map into a liar. Add
      # `test` in the same commit as the first test.
      #
      # A bare `python` (rather than an absolute path) is correct in THIS repo
      # and only because there is no .venv: the only interpreter on PATH is the
      # one `toolchain` above puts there, on both surfaces -- the wrappers get
      # it through runtimeInputs and the shell through `packages`. Measured
      # inside the shell: `python --version` is 3.13.15 and `import discord`
      # reports 2.6.4. Spell out an absolute path the day a .venv appears.
      commands = pkgs: {
        lint = {
          # "''${@:-$REPO_ROOT}" is the whole anchoring rule in one expansion:
          # explicit paths still win and are still forwarded one-arg-per-arg,
          # but no arguments means this repo rather than the caller's cwd. ruff
          # walks a directory itself, so the single anchored path IS the repo.
          # Note the deliberate absence of a `cd` in the two ruff verbs: the
          # default is already absolute, and staying put is what keeps a
          # RELATIVE path the caller typed (`dev-lint bot.py`) meaning what they
          # typed.
          #
          # --no-cache closes the hole the path argument does not. Measured with
          # this lock's ruff 0.16.2: `ruff check /path/to/this/repo` run from an
          # unrelated directory creates `.ruff_cache/` in THAT directory, not in
          # the one it graded. Pointing RUFF_CACHE_DIR at $REPO_ROOT instead is
          # not an option -- with the cache dir under a store path ruff exits 2
          # with "Failed to initialize cache ...: Read-only file system" and
          # reports no findings at all, which is a lying gate again. Measured
          # price of running uncached: 0.018s wall for the whole repo.
          description = "ruff check (read-only)";
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          # Measured with ruff 0.16.2: `ruff format` with no path argument
          # rewrites the files in the process's cwd -- a scratch directory's
          # `x  =  1` came back as `x = 1`. So the no-argument case is anchored
          # to $REPO_ROOT, and the verb refuses outright when no work tree of
          # THIS repo is in reach: need_writable_checkout, from the canonical
          # block, is that refusal and it prints why. It is called
          # unconditionally rather than only for the no-argument case, because
          # an explicit path is a rewrite too, and $REPO_ROOT falling back to
          # the store snapshot is the signal that no tree of this repo is in
          # reach. Verified from a git repo that is not this one: `nix run
          # /path/to/dc-ranked_queue#fmt` refuses, and every file in that tree
          # is byte-identical afterwards.
          # --no-cache for the same reason as lint, and it is the same hole:
          # `ruff format` was measured writing `.ruff_cache/` into the cwd it
          # was invoked from while formatting a directory somewhere else.
          text = ''
            need_writable_checkout
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
        run = {
          # $REPO_ROOT, not a bare bot.py: CPython puts the SCRIPT's directory
          # on sys.path, so anchoring the path is also what lets `logger` and
          # `config` import when an agent invokes this from a subdirectory.
          #
          # The `cd` is not cosmetic, and need_writable_checkout above it is
          # what makes the `cd` safe. bot.py's __main__ constructs
          # QueueManager(...) leaving file_log at its default True, so logger.py
          # calls logging.basicConfig(filename=...) on a name it builds itself
          # -- "baselog" + "_log_" + time.asctime() + ".txt", with " " replaced
          # by "_" and ":" by "-" -- and that name is RELATIVE to the cwd. That
          # is what .gitignore's `*baselog*` line is for. Without the cd,
          # `nix run /path/to/repo#run` drops the bot's log in the caller's
          # directory; without the guard, a caller standing outside any checkout
          # would get the read-only store snapshot as that cwd instead.
          #
          # config.py is gitignored (.gitignore's `*config*`) and BOT_TOKEN is
          # the only name bot.py's `from config import *` actually needs -- the
          # two channel IDs are integer literals in bot.py's __main__, not
          # config values. Because it is gitignored, config.py is not in the
          # store snapshot either, so this verb only ever really starts from a
          # work tree.
          description = "start the queue bot -- needs a local, gitignored config.py defining BOT_TOKEN (network)";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            python "$REPO_ROOT/bot.py" "$@"
          '';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 5 -- the name in the interactive dev-shell banner
      # ======================================================================
      repoName = "dc-ranked_queue";

      # ======================================================================
      # PER-REPO BLOCK 6 -- checks that know what THIS repo's verbs do
      # ======================================================================
      # The canonical `anchoring` check proves rootPreamble and guardPreamble
      # behave; by construction it cannot prove that the three verbs above
      # actually call them. This one drives the real wrappers from inside a
      # decoy that carries this ecosystem's marker files -- a root bot.py, which
      # is exactly what a filename-based anchor would adopt.
      #
      # It asserts what was read and what was written, never a lint exit code:
      # `ruff check` exits non-zero here today (29 findings on the tracked
      # tree, measured with ruff 0.16.2) and would exit zero the day somebody
      # fixes them, which must not read as a broken check.
      extraChecks = pkgs: {
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              set -euo pipefail

              mkdir decoy
              cd decoy
              printf 'import os\nx  =1\n' > bot.py
              printf 'import json\ny  =2\n' > sibling_only.py
              printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > flake.nix
              cp -r . ../decoy.orig

              # Grep by NAME, not by directory: were the anchor to land on the
              # decoy, ruff would be printing paths under this very cwd and a
              # grep for "decoy" would match nothing. sibling_only.py is a name
              # this repo does not contain, so it cannot be spelled both ways.
              dev-lint > lint.log 2>&1 || true
              if grep -q sibling_only lint.log; then
                echo "dev-lint graded the decoy" >&2
                cat lint.log >&2
                exit 1
              fi
              # ...and it must have graded SOMETHING: a verb that read nothing
              # at all would also pass the test above. ruff prints absolute
              # paths for a target outside its cwd, so the store snapshot's own
              # path is what appears.
              if ! grep -q ${lib.escapeShellArg "${self}"} lint.log; then
                echo "dev-lint graded neither the decoy nor this repo" >&2
                cat lint.log >&2
                exit 1
              fi

              # Both mutating verbs must refuse here, loudly, not silently.
              if dev-fmt > fmt.log 2>&1; then
                echo "dev-fmt succeeded in a foreign tree; it must refuse" >&2
                cat fmt.log >&2
                exit 1
              fi
              if dev-run > run.log 2>&1; then
                echo "dev-run succeeded in a foreign tree; it must refuse" >&2
                cat run.log >&2
                exit 1
              fi

              # `*.log`, and every log file above matches it -- a file named
              # plainly `log` would not be excluded and would fail this diff.
              diff -r --exclude='*.log' . ../decoy.orig
              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
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
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
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

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
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

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<

# >>> hermes-no-compile >>>
# Compilation ban for hermes on tower (marc's policy, 25/11/2026):
# rustc, cargo, gcc, clang, make, cmake... nothing. Nix builds (daemon,
# `just build`, `nix build`) remain allowed: they do not compile as
# hermes. For rust/C, compile on the deck.
#
# Block (re)installed by activation of the modules/nixos/hermes-no-compile module:
# on every switch, the current version of no-compile.sh (nixos repo) replaces
# this block. Do not edit here, edit the repo file.
# LIST KEPT IN SYNC with toolNames (shims /etc/hermes-no-compile/bin) of the module.
#
# Shell belt (rc 97, like the purity guard above), NOT a kernel
# lock: an absolute path /nix/store/.../bin/gcc remains callable, and a cron
# job does not source this file.
if [ "$(id -un 2>/dev/null)" = "hermes" ] && [ -n "${BASH_VERSION:-}" ]; then
  _hermes_no_compile_msg() {
    printf 'DENIED: compilation forbidden for hermes on tower (marc policy, 25/11/2026).\n' >&2
    printf 'Rust/C/C++/Go/make/cmake...: compile on the deck. Nix builds (daemon, just build) remain allowed.\n' >&2
    return 97
  }

  # True if the arguments look like a compilation tool request
  # (bare tokens or nixpkgs#X packages): used by nix shell/develop/run.
  _hermes_no_compile_scan() {
    case " $* " in
      *" gcc "*|*" g++ "*|*" clang "*|*" rustc "*|*" cargo "*|*" rustup "*|*" go "*|*" zig "*|*" binutils "*|*" gfortran "*|*" make "*|*" gnumake "*|*" cmake "*|*" ninja "*|*" meson "*|*" stdenv "*|*" llvm "*|*" jdk "*|*" openjdk "*|*" kotlin "*|*" swift "*|*" ghc "*|*" distcc "*|*" ccache "*) return 0 ;;
    esac
    case " $* " in
      *"#gcc "*|*"#g++ "*|*"#clang "*|*"#rustc "*|*"#cargo "*|*"#rustup "*|*"#go "*|*"#zig "*|*"#binutils "*|*"#gfortran "*|*"#make "*|*"#gnumake "*|*"#cmake "*|*"#ninja "*|*"#meson "*|*"#stdenv "*|*"#llvm "*|*"#jdk "*|*"#openjdk "*|*"#kotlin "*|*"#swift "*|*"#ghc "*|*"#distcc "*|*"#ccache "*) return 0 ;;
    esac
    return 1
  }

  # One refusal per tool name. `export -f`: child bash shells (bash -c, just,
  # nix develop) inherit the refusal via the environment.
  for _t in gcc cc cpp gfortran clang clang-cl clang-cpp \
            rustc cargo rustup go zig javac kotlinc swiftc ghc ghci cabal stack \
            ocamlc ocamlopt dotnet msbuild tsc node-gyp \
            make gmake cmake meson ninja bazel scons xmake ccache sccache distcc \
            as ld ld.bfd ld.gold ld.lld lld lld-link ar ranlib strip objcopy gprof; do
    eval "$_t() { _hermes_no_compile_msg; }"
    export -f "$_t" 2>/dev/null
  done
  # Names with `++` do not work as `name() {}` (bash 5.3): use the `function` form.
  for _t in g++ c++ clang++; do
    eval "function $_t { _hermes_no_compile_msg; }"
    export -f "$_t" 2>/dev/null
  done
  unset _t
  export -f _hermes_no_compile_msg 2>/dev/null

  # nix() takes over the definition of the purity guard (above) and adds the
  # refusal of compiler packages on shell/develop/run. The rest passes through.
  nix() {
    if [ "$(type -t _nix_pure_guard 2>/dev/null)" = "function" ]; then
      _nix_pure_guard "$@" || return $?
    fi
    case " $* " in
      *" shell "*|*" develop "*|*" run "*)
        if _hermes_no_compile_scan "$@"; then _hermes_no_compile_msg; return 97; fi ;;
    esac
    command nix "$@"
  }
  nix-shell() {
    if _hermes_no_compile_scan "$@"; then _hermes_no_compile_msg; return 97; fi
    command nix-shell "$@"
  }

  # Shims: cover non-bash children (sh, python, node) that resolve via
  # the PATH. Idempotent.
  case ":$PATH:" in
    *":/etc/hermes-no-compile/bin:"*) ;;
    *) export PATH="/etc/hermes-no-compile/bin:$PATH" ;;
  esac
fi
# <<< hermes-no-compile <<<

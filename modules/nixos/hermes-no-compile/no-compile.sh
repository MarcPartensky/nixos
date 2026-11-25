# >>> hermes-no-compile >>>
# Interdiction de compilation pour hermes sur tower (politique marc, 25/11/2026) :
# rustc, cargo, gcc, clang, make, cmake... rien. Les builds nix (daemon,
# `just build`, `nix build`) restent permis : ils ne compilent pas en tant que
# hermes. Pour du rust/C, compiler sur le deck.
#
# Bloc (re)installe par l'activation du module modules/nixos/hermes-no-compile :
# a chaque switch, la version courante de no-compile.sh (depot nixos) remplace
# ce bloc. Ne pas editer ici, editer le fichier du depot.
# LISTE TENUE SYNCHRO avec toolNames (shims /etc/hermes-no-compile/bin) du module.
#
# Ceinture shell (rc 97, comme la garde de purete plus haut), PAS un verrou
# noyau : un chemin absolu /nix/store/.../bin/gcc reste appelable, et un job
# cron ne source pas ce fichier.
if [ "$(id -un 2>/dev/null)" = "hermes" ] && [ -n "${BASH_VERSION:-}" ]; then
  _hermes_no_compile_msg() {
    printf 'REFUS: compilation interdite pour hermes sur tower (politique marc, 25/11/2026).\n' >&2
    printf 'Rust/C/C++/Go/make/cmake... : compile sur le deck. Les builds nix (daemon, just build) restent permis.\n' >&2
    return 97
  }

  # Vrai si les arguments ressemblent a une demande d'outil de compilation
  # (tokens nus ou paquets nixpkgs#X) : utilise par nix shell/develop/run.
  _hermes_no_compile_scan() {
    case " $* " in
      *" gcc "*|*" g++ "*|*" clang "*|*" rustc "*|*" cargo "*|*" rustup "*|*" go "*|*" zig "*|*" binutils "*|*" gfortran "*|*" make "*|*" gnumake "*|*" cmake "*|*" ninja "*|*" meson "*|*" stdenv "*|*" llvm "*|*" jdk "*|*" openjdk "*|*" kotlin "*|*" swift "*|*" ghc "*|*" distcc "*|*" ccache "*) return 0 ;;
    esac
    case " $* " in
      *"#gcc "*|*"#g++ "*|*"#clang "*|*"#rustc "*|*"#cargo "*|*"#rustup "*|*"#go "*|*"#zig "*|*"#binutils "*|*"#gfortran "*|*"#make "*|*"#gnumake "*|*"#cmake "*|*"#ninja "*|*"#meson "*|*"#stdenv "*|*"#llvm "*|*"#jdk "*|*"#openjdk "*|*"#kotlin "*|*"#swift "*|*"#ghc "*|*"#distcc "*|*"#ccache "*) return 0 ;;
    esac
    return 1
  }

  # Un refus par nom d'outil. `export -f` : les bash enfants (bash -c, just,
  # nix develop) heritent du refus via l'environnement.
  for _t in gcc cc cpp gfortran clang clang-cl clang-cpp \
            rustc cargo rustup go zig javac kotlinc swiftc ghc ghci cabal stack \
            ocamlc ocamlopt dotnet msbuild tsc node-gyp \
            make gmake cmake meson ninja bazel scons xmake ccache sccache distcc \
            as ld ld.bfd ld.gold ld.lld lld lld-link ar ranlib strip objcopy gprof; do
    eval "$_t() { _hermes_no_compile_msg; }"
    export -f "$_t" 2>/dev/null
  done
  # Les noms a `++` ne passent pas en `name() {}` (bash 5.3) : forme `function`.
  for _t in g++ c++ clang++; do
    eval "function $_t { _hermes_no_compile_msg; }"
    export -f "$_t" 2>/dev/null
  done
  unset _t
  export -f _hermes_no_compile_msg 2>/dev/null

  # nix() reprend la definition de la garde de purete (plus haut) et ajoute le
  # refus des paquets compilateurs sur shell/develop/run. Le reste passe.
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

  # Shims : couvrent les enfants non-bash (sh, python, node) qui resolvent par
  # le PATH. Idempotent.
  case ":$PATH:" in
    *":/etc/hermes-no-compile/bin:"*) ;;
    *) export PATH="/etc/hermes-no-compile/bin:$PATH" ;;
  esac
fi
# <<< hermes-no-compile <<<

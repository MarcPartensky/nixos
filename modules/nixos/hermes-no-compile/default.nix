{
  config,
  lib,
  ...
}:
# Interdiction de compilation pour l'utilisateur hermes, sur tower uniquement.
#
# Politique marc du 25/11/2026 : hermes n'a plus le droit de compiler quoi que
# ce soit sur tower (rustc/cargo, gcc/clang, make/cmake/ninja...). Le CPU de
# marc ne sert pas aux builds d'agent : le rust/C se compile sur le deck, et
# les builds nix (daemon, `just build`) restent permis (ils ne compilent pas en
# tant que hermes).
#
# Deux etages, tous deux declares ici :
#  - des shims /etc/hermes-no-compile/bin/<outil> (rc 97), prepends au PATH par
#    le bloc shell : ils couvrent les enfants non-bash (sh, python, node) ;
#  - un bloc shell (no-compile.sh) (re)appose par l'activation dans
#    /var/lib/hermes/.bashrc (l'ancien bloc entre marqueurs est remplace a
#    chaque switch) : fonctions de refus + `export -f` (les bash enfants
#    heritent) + refus des paquets compilateurs via `nix shell/develop/run`
#    et `nix-shell`.
#
# Ce n'est PAS un verrou noyau : un chemin absolu /nix/store/.../bin/gcc reste
# appelable, et un job cron ne source pas .bashrc. Le verrou dur serait un LSM
# (AppArmor), non retenu — meme modele "ceinture" que la garde de purete
# (rc 97) documentee par le skill nixos-pure-eval.
#
# Le module est importe par services/hermes (partage par tous les hotes) et se
# limite a tower : sur le deck, hermes DOIT pouvoir compiler.
let
  # LISTE TENUE SYNCHRO avec le `for _t in ...` de no-compile.sh (meme
  # repertoire) : ajouter un outil ici ET la-bas.
  toolNames = [
    # compilateurs
    "gcc" "g++" "cc" "c++" "cpp" "gfortran" "clang" "clang++" "clang-cl" "clang-cpp"
    "rustc" "cargo" "rustup" "go" "zig" "javac" "kotlinc" "swiftc" "ghc" "ghci"
    "cabal" "stack" "ocamlc" "ocamlopt" "dotnet" "msbuild" "tsc" "node-gyp"
    # lanceurs de build
    "make" "gmake" "cmake" "meson" "ninja" "bazel" "scons" "xmake"
    "ccache" "sccache" "distcc"
    # binutils / editeurs de binaires
    "as" "ld" "ld.bfd" "ld.gold" "ld.lld" "lld" "lld-link" "ar" "ranlib"
    "strip" "objcopy" "gprof"
  ];

  shim = ''
    #!/bin/sh
    printf 'REFUS: compilation interdite pour hermes sur tower (politique marc, 25/11/2026).\n' >&2
    printf 'Rust/C/C++/Go/make/cmake... : compile sur le deck. Les builds nix (daemon, just build) restent permis.\n' >&2
    exit 97
  '';
in
lib.mkIf (config.networking.hostName == "tower") {
  environment.etc = builtins.listToAttrs (map (n: {
    name = "hermes-no-compile/bin/${n}";
    value = {
      mode = "0555";
      text = shim;
    };
  }) toolNames);

  system.activationScripts."hermes-no-compile" = ''
    f=/var/lib/hermes/.bashrc
    if [ ! -e "$f" ]; then
      touch "$f"
      chown hermes:hermes "$f"
      chmod 0644 "$f"
    fi
    # Le fichier du depot est la source de verite : retirer l'ancien bloc
    # (marqueurs) puis apposer la version courante. Une liste d'outils etendue
    # se propage donc au switch suivant, sans edition manuelle du .bashrc.
    if grep -qF '>>> hermes-no-compile >>>' "$f"; then
      sed -i '/^# >>> hermes-no-compile >>>$/,/^# <<< hermes-no-compile <<<$/d' "$f"
    fi
    cat ${./no-compile.sh} >> "$f"
    chown hermes:hermes "$f"
  '';
}

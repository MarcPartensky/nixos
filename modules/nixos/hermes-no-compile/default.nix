{
  config,
  lib,
  ...
}:
# Compilation ban for the hermes user, on tower only.
#
# Marc's policy of 25/11/2026: hermes is no longer allowed to compile anything
# at all on tower (rustc/cargo, gcc/clang, make/cmake/ninja...). Marc's CPU is
# not for agent builds: rust/C is compiled on the deck, and
# nix builds (daemon, `just build`) remain allowed (they do not compile as
# hermes).
#
# Two layers, both declared here:
#  - shims /etc/hermes-no-compile/bin/<tool> (rc 97), prepended to PATH by
#    the shell block: they cover non-bash children (sh, python, node);
#  - a shell block (no-compile.sh) (re)appended by the activation in
#    /var/lib/hermes/.bashrc (the old block between markers is replaced on
#    each switch): refusal functions + `export -f` (bash children
#    inherit) + refusal of compiler packages via `nix shell/develop/run`
#    and `nix-shell`.
#
# This is NOT a kernel lock: an absolute path /nix/store/.../bin/gcc remains
# callable, and a cron job does not source .bashrc. The hard lock would be an LSM
# (AppArmor), not retained - same "belt" model as the purity guard
# (rc 97) documented by the nixos-pure-eval skill.
#
# The module is imported by services/hermes (shared by all hosts) and is
# limited to tower: on the deck, hermes MUST be able to compile.
let
  # LIST KEPT IN SYNC with the `for _t in ...` of no-compile.sh (same
  # directory): add a tool here AND there.
  toolNames = [
    # compilers
    "gcc" "g++" "cc" "c++" "cpp" "gfortran" "clang" "clang++" "clang-cl" "clang-cpp"
    "rustc" "cargo" "rustup" "go" "zig" "javac" "kotlinc" "swiftc" "ghc" "ghci"
    "cabal" "stack" "ocamlc" "ocamlopt" "dotnet" "msbuild" "tsc" "node-gyp"
    # build launchers
    "make" "gmake" "cmake" "meson" "ninja" "bazel" "scons" "xmake"
    "ccache" "sccache" "distcc"
    # binutils / binary editors
    "as" "ld" "ld.bfd" "ld.gold" "ld.lld" "lld" "lld-link" "ar" "ranlib"
    "strip" "objcopy" "gprof"
  ];

  shim = ''
    #!/bin/sh
    printf 'DENIED: compilation forbidden for hermes on tower (marc policy, 25/11/2026).\n' >&2
    printf 'Rust/C/C++/Go/make/cmake... : compile on the deck. nix builds (daemon, just build) remain allowed.\n' >&2
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
    # The repo file is the source of truth: remove the old block
    # (markers) then append the current version. An extended tool list
    # therefore propagates on the next switch, without manual editing of .bashrc.
    if grep -qF '>>> hermes-no-compile >>>' "$f"; then
      sed -i '/^# >>> hermes-no-compile >>>$/,/^# <<< hermes-no-compile <<<$/d' "$f"
    fi
    cat ${./no-compile.sh} >> "$f"
    chown hermes:hermes "$f"
  '';
}

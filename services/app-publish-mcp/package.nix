# npm package of the app-publish-mcp MCP (App Store Connect + Google Play Console,
# mikusnuz/app-publish-mcp). The published tarball contains an already-compiled dist/:
# nothing to build (dontNpmBuild), just install the runtime.
#
# package-lock.json next to this file: generated from the PUBLISHED manifest
# (devDependencies and scripts removed before generation, otherwise npm breaks with
# "Cannot read properties of null (reading 'edgesOut')" and the lock does not cover
# what the build requires). Commit it, it pins the whole tree.
#
# Package engines: node >= 22 (nixpkgs 26.05 provides nodejs 24).
{ pkgs, lib ? pkgs.lib }:
pkgs.buildNpmPackage {
  pname = "app-publish-mcp";
  version = "0.7.0";
  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/app-publish-mcp/-/app-publish-mcp-0.7.0.tgz";
    hash = "sha256-cHi44/rLEKduYgCVg2vGqXbBpVUbFha7iw/hkaWVyOM=";
  };
  # npmDepsHash: obtained at the first build (fakeHash -> message "got: ...") ;
  # re-iterate if the tarball version is bumped.
  npmDepsHash = "sha256-9Od0gd41DlgfoTn92NJp7kPZeuhxokBEtODr9TTXuDE=";
  dontNpmBuild = true;
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
    ${lib.getExe pkgs.jq} 'del(.devDependencies) | del(.scripts)' \
      package.json > package.json.tmp
    mv package.json.tmp package.json
  '';
  meta = {
    description = "MCP server for App Store Connect and Google Play Console";
    homepage = "https://github.com/mikusnuz/app-publish-mcp";
    license = lib.licenses.mit;
    mainProgram = "app-publish-mcp";
  };
}

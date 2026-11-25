# Paquet npm du MCP app-publish-mcp (App Store Connect + Google Play Console,
# mikusnuz/app-publish-mcp). Le tarball publie contient dist/ deja compile :
# rien a construire (dontNpmBuild), il faut juste installer le runtime.
#
# package-lock.json a cote de ce fichier : generee depuis le manifeste PUBLIE
# (devDependencies et scripts retires avant generation, sinon npm casse en
# "Cannot read properties of null (reading 'edgesOut')" et la lock ne couvre
# pas ce que le build reclame). La committer, elle fige tout l'arbre.
#
# Engines du paquet : node >= 22 (nixpkgs 26.05 fournit nodejs 24).
{ pkgs, lib ? pkgs.lib }:
pkgs.buildNpmPackage {
  pname = "app-publish-mcp";
  version = "0.7.0";
  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/app-publish-mcp/-/app-publish-mcp-0.7.0.tgz";
    hash = "sha256-cHi44/rLEKduYgCVg2vGqXbBpVUbFha7iw/hkaWVyOM=";
  };
  # npmDepsHash : obtenu au premier build (fakeHash -> message "got: ...") ;
  # re-iterer si bump de version du tarball.
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

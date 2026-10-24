# Contrôles avant commit, dans l'ordre du projet : build du front (vite),
# svelte-check, puis cargo check du backend et de l'ingest.
# `npm run check` n'est pas appelé tel quel : son `tsc -p tsconfig.node.json`
# échoue sur TS2688 (Cannot find type definition file for 'node', @types/node
# absent de app/package.json), une dette antérieure au projet.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-verify] npm ci"
  npm ci
fi

echo "[winnie-verify] front : vite build"
npm run build

echo "[winnie-verify] front : svelte-check"
./node_modules/.bin/svelte-check --tsconfig ./tsconfig.app.json

cd "$repo"
echo "[winnie-verify] backend : cargo check"
cargo check --manifest-path backend/Cargo.toml

if [ -f ingest/Cargo.toml ]; then
  echo "[winnie-verify] ingest : cargo check"
  cargo check --manifest-path ingest/Cargo.toml
fi

echo "[winnie-verify] ok"

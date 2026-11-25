# Checks before commit, in project order: frontend build (vite),
# svelte-check, then cargo check of the backend and of ingest.
# `npm run check` is not called as-is: its `tsc -p tsconfig.node.json`
# fails on TS2688 (Cannot find type definition file for 'node', @types/node
# absent from app/package.json), a debt predating the project.
repo="$HOME/@REPO_REL@"
cd "$repo/app"

if [ ! -d node_modules ]; then
  echo "[winnie-verify] npm ci"
  npm ci
fi

echo "[winnie-verify] frontend: vite build"
npm run build

echo "[winnie-verify] frontend: svelte-check"
./node_modules/.bin/svelte-check --tsconfig ./tsconfig.app.json

cd "$repo"
echo "[winnie-verify] backend : cargo check"
cargo check --manifest-path backend/Cargo.toml

if [ -f ingest/Cargo.toml ]; then
  echo "[winnie-verify] ingest : cargo check"
  cargo check --manifest-path ingest/Cargo.toml
fi

echo "[winnie-verify] ok"

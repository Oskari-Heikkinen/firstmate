#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
# Checks the installed Pi package (the CI pin) with the installed tsc, then the
# public Pi 1.1.0 and 1.2.0 SDKs with temporary npm dependencies and
# TypeScript 5.9.3; the pinned SDK checks never use global tsc or
# FM_PI_PACKAGE_DIR.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: node"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: npm"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: tsc"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: Pi extension typecheck prerequisite not found: installed @earendil-works/pi-coding-agent package"
  exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
  echo "not ok - installed Pi package is missing pi-tui, pi-ai, typebox, or Node declarations" >&2
  exit 1
fi

DEPENDENCY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
trap 'rm -rf "$DEPENDENCY_ROOT"' EXIT

# Copy the tracked extensions and a strict NodeNext no-emit project into $1.
write_consumer() {
  local dir=$1
  mkdir -p "$dir/lib"
  cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$dir/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/fm-calm.ts" "$dir/fm-calm.ts"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$dir/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$dir/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$dir/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$dir/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$dir/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$dir/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$dir/lib/fm-calm-assistant-layout.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-preservation.ts" "$dir/lib/fm-calm-preservation.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$dir/lib/fm-calm-operational-user-layout.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts" "$dir/lib/fm-calm-pending-operational-layout.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$dir/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$dir/lib/fm-calm-working-ship.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$dir/lib/fm-calm-working-ship-sprite.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$dir/lib/fm-operational-input.ts"
  cat > "$dir/package.json" <<'JSON'
{"type":"module"}
JSON
  cat > "$dir/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["*.ts", "lib/*.ts"]
}
JSON
}

result=0

TMP_ROOT="$DEPENDENCY_ROOT/installed"
write_consumer "$TMP_ROOT"
mkdir -p "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
if tsc -p "$TMP_ROOT/tsconfig.json"; then
  printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
else
  printf 'not ok - tracked Pi extensions fail strict no-emit typecheck against installed Pi %s\n' "$version" >&2
  result=1
fi

printf 'Pi production-consumer typechecks: npm %s\n' "$(npm --version)"
for version in 1.1.0 1.2.0; do
  TMP_ROOT="$DEPENDENCY_ROOT/sdk-$version"
  write_consumer "$TMP_ROOT"

  # Pin the directly imported Pi packages together rather than allowing npm's
  # semver ranges to make the older SDK consumer resolve newer sibling types.
  if ! (cd "$TMP_ROOT" && npm install --ignore-scripts --no-audit --no-fund --save-exact \
    "@earendil-works/pi-coding-agent@$version" \
    "@earendil-works/pi-ai@$version" \
    "@earendil-works/pi-tui@$version" \
    typebox@1.3.27 @types/node@22.19.19 typescript@5.9.3); then
    printf 'not ok - npm could not install the pinned Pi %s SDK\n' "$version" >&2
    result=1
    continue
  fi

  # Emit real installed versions and npm-verified package integrity before the
  # temporary lock/vendor tree is removed; compiler diagnostics stay in CI logs.
  node - "$TMP_ROOT" <<'JS' || { result=1; continue; }
const { readFileSync } = require("node:fs");
const root = process.argv[2];
const lock = JSON.parse(readFileSync(`${root}/package-lock.json`, "utf8"));
const packages = {};
for (const [name, expected] of Object.entries(lock.packages[""].dependencies)) {
  const entry = lock.packages[`node_modules/${name}`];
  const installed = JSON.parse(readFileSync(`${root}/node_modules/${name}/package.json`, "utf8"));
  if (installed.version !== expected || entry.version !== expected || !entry.integrity) {
    throw new Error(`Unexpected package provenance for ${name}`);
  }
  packages[name] = { version: installed.version, resolved: entry.resolved, integrity: entry.integrity };
}
console.log(JSON.stringify({ node: process.version, platform: process.platform, arch: process.arch, packages }));
JS
  "$TMP_ROOT/node_modules/.bin/tsc" --version
  if "$TMP_ROOT/node_modules/.bin/tsc" -p "$TMP_ROOT/tsconfig.json"; then
    printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
  else
    printf 'not ok - tracked Pi extensions fail strict no-emit typecheck against Pi %s\n' "$version" >&2
    result=1
  fi
done
exit "$result"

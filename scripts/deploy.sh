#!/usr/bin/env bash
# Deploys apex-http-callout to a Salesforce org, with or without Nebula Logger.
#
# Nebula Logger calls are committed commented out, each line starting with the marker "// [nebula] ".
#   default        deploys the sources as committed: no dependency on Nebula Logger.
#   --with-nebula  copies the project to .build/, removes the marker, checks that the org has
#                  Nebula Logger (unlocked package, no namespace), then deploys the copy.
# NEBULA_LOGGER=true in the environment is the same as --with-nebula (handy in CI).
#
# Usage:
#   scripts/deploy.sh [-o <org alias>] [--with-nebula | --without-nebula] [--build-only] [-- <extra sf flags>]
#
# Examples:
#   scripts/deploy.sh -o mySandbox
#   scripts/deploy.sh -o mySandbox --with-nebula -- --test-level RunSpecifiedTests --tests HttpRequestUtilsTest
#   scripts/deploy.sh --with-nebula --build-only      # only writes .build/force-app, for another pipeline to deploy
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
SOURCE_DIR="force-app"
MARKER='// [nebula] '
# Only a marker at the start of a line (after indentation) is a switchable Nebula line.
MARKER_REGEX='^([[:space:]]*)// \[nebula\] '

WITH_NEBULA="${NEBULA_LOGGER:-false}"
BUILD_ONLY=false
TARGET_ORG=()
EXTRA_ARGS=()

usage() {
	sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-o | --target-org)
			[[ $# -ge 2 ]] || { echo "error: $1 needs an org alias or username" >&2; exit 1; }
			TARGET_ORG=(--target-org "$2")
			shift 2
			;;
		--with-nebula) WITH_NEBULA=true; shift ;;
		--without-nebula) WITH_NEBULA=false; shift ;;
		--build-only) BUILD_ONLY=true; shift ;;
		-h | --help) usage; exit 0 ;;
		--) shift; EXTRA_ARGS=("$@"); break ;;
		*) echo "error: unknown option $1" >&2; usage >&2; exit 1 ;;
	esac
done

# Guard: every Nebula call must carry the marker, otherwise the default deploy breaks in orgs without Nebula.
unmarked="$(grep -rnE '(^|[^A-Za-z0-9_.])Logger\.' "$ROOT/$SOURCE_DIR" --include='*.cls' --include='*.trigger' \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
if [[ -n "$unmarked" ]]; then
	echo "error: Nebula Logger calls without the \"$MARKER\" marker:" >&2
	echo "$unmarked" >&2
	echo "Prefix each of these lines with \"$MARKER\" so the deploy script can switch them on and off." >&2
	exit 1
fi

# Bash 3.2 (macOS) treats empty arrays as unset under "set -u": expand them this way.
sf_deploy() {
	sf project deploy start --source-dir "$SOURCE_DIR" \
		${TARGET_ORG[@]+"${TARGET_ORG[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
}

if [[ "$WITH_NEBULA" != "true" ]]; then
	if [[ "$BUILD_ONLY" == "true" ]]; then
		echo "Nothing to build without Nebula: deploy $ROOT/$SOURCE_DIR as is."
		exit 0
	fi
	echo "Deploying without Nebula Logger (Nebula lines stay commented)."
	cd "$ROOT"
	sf_deploy
	exit 0
fi

echo "Building a copy with Nebula Logger lines enabled in $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -R "$ROOT/$SOURCE_DIR" "$ROOT/sfdx-project.json" "$BUILD_DIR/"
[[ -f "$ROOT/.forceignore" ]] && cp "$ROOT/.forceignore" "$BUILD_DIR/"
# Keep the project's default target org (sf config set target-org ... in this folder).
[[ -d "$ROOT/.sf" ]] && cp -R "$ROOT/.sf" "$BUILD_DIR/"
[[ -d "$ROOT/.sfdx" ]] && cp -R "$ROOT/.sfdx" "$BUILD_DIR/"

enabled=0
while IFS= read -r file; do
	sed -E -e "s#$MARKER_REGEX#\\1#" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
	echo "  enabled Nebula lines in ${file#"$BUILD_DIR/"}"
	enabled=$((enabled + 1))
done < <(grep -rlE "$MARKER_REGEX" "$BUILD_DIR/$SOURCE_DIR" --include='*.cls' --include='*.trigger' || true)

if [[ $enabled -eq 0 ]]; then
	echo "warning: no \"$MARKER\" line found, the build is the same as the sources." >&2
fi

if [[ "$BUILD_ONLY" == "true" ]]; then
	echo "Build ready: $BUILD_DIR/$SOURCE_DIR"
	exit 0
fi

cd "$BUILD_DIR"
echo "Checking that the target org has Nebula Logger (class Logger, no namespace)..."
query_result="$(sf data query --use-tooling-api --json \
	--query "SELECT Id FROM ApexClass WHERE Name = 'Logger' AND NamespacePrefix = null" \
	${TARGET_ORG[@]+"${TARGET_ORG[@]}"} 2>/dev/null || true)"
if ! grep -Eq '"totalSize":[[:space:]]*[1-9]' <<<"$query_result"; then
	echo "error: Nebula Logger was not found in the target org (or the org could not be queried)." >&2
	echo "Install the unlocked package (https://github.com/jongpie/NebulaLogger), or deploy without --with-nebula." >&2
	echo "The managed package (namespace Nebula) is not supported: the code calls Logger, not Nebula.Logger." >&2
	exit 1
fi

echo "Deploying with Nebula Logger."
sf_deploy

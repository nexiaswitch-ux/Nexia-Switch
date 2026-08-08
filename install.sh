#!/usr/bin/env bash
# =============================================================================
#  NEXIA Switch — public bootstrap installer
# =============================================================================
#
#  This is the ONLY file an operator downloads directly. It does three things
#  and nothing else:
#
#    1. Downloads the latest signed release bundle from this repository's
#       Releases (the .tar.gz and its detached .sig).
#    2. Verifies the bundle's Ed25519 signature against the public key PINNED
#       BELOW — before a single byte of the bundle is extracted or executed.
#    3. Extracts the verified bundle and runs the real installer from inside it.
#
#  The application source is PRIVATE and is never downloaded. What ships is a
#  signed artifact; this script is the trust anchor that authenticates it. If
#  the signature does not verify, nothing is extracted and nothing runs.
#
#  USAGE
#  -----
#    curl -fsSLO https://raw.githubusercontent.com/nexiaswitch-ux/Nexia-Switch/main/install.sh
#    less install.sh                 # read it — it installs as root
#    sudo bash install.sh
#
#    # Install a specific version instead of the latest:
#    sudo NEXIA_VERSION=1.0.0 bash install.sh
#
#    # Download and verify only, then inspect before running the installer:
#    sudo NEXIA_FETCH_ONLY=1 bash install.sh
#
#  Any NEXIA_* variable you set (NEXIA_DOMAIN, NEXIA_ADMIN_EMAIL, …) is passed
#  straight through to the real installer.
# =============================================================================
set -euo pipefail

REPO="nexiaswitch-ux/Nexia-Switch"

# --- The pinned signing key. The private half never leaves the vendor. A
#     bundle is trusted ONLY if it verifies against this exact key. Replacing
#     this block is the one change that redefines what "genuine" means, so it
#     lives here in the file the operator reads, not in the artifact it checks.
PINNED_PUBKEY="-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAt+ZByeKRV+Xw4gtWTnuYeSZg/9jD3pmu0lw83nG2EUM=
-----END PUBLIC KEY-----"

NEXIA_VERSION="${NEXIA_VERSION:-}"
NEXIA_FETCH_ONLY="${NEXIA_FETCH_ONLY:-0}"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'
info() { printf '%s  %s\n' "${C_BLU}··${C_OFF}" "$*"; }
ok()   { printf '%s  %s\n' "${C_GRN}OK${C_OFF}" "$*"; }
die()  { printf '%s  %s\n' "${C_RED}!!${C_OFF}" "$*" >&2; exit 1; }

for tool in curl openssl tar sha256sum; do
    command -v "$tool" >/dev/null || die "required tool not found: ${tool}"
done

# --- Resolve which release to install ----------------------------------------
if [[ -z "$NEXIA_VERSION" ]]; then
    info "Resolving the latest release…"
    TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
             | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
    [[ -n "$TAG" ]] || die "Could not resolve the latest release. Set NEXIA_VERSION=x.y.z and retry."
else
    TAG="$NEXIA_VERSION"
    [[ "$TAG" == v* ]] || TAG="v${TAG}"
fi
VER="${TAG#v}"
NAME="nexia-switch-${VER}-app"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
info "Release: ${TAG}"

# --- Download the bundle and its signature into a private temp dir ------------
WORK="$(mktemp -d)"
cleanup() { [[ "${NEXIA_KEEP_WORK:-0}" == "1" ]] || rm -rf "$WORK"; }
trap cleanup EXIT
chmod 700 "$WORK"

TARBALL="${WORK}/${NAME}.tar.gz"
SIG="${WORK}/${NAME}.tar.gz.sig"

info "Downloading ${NAME}.tar.gz…"
curl -fsSL -o "$TARBALL" "${BASE}/${NAME}.tar.gz" \
    || die "Could not download the bundle from ${BASE}/${NAME}.tar.gz"
curl -fsSL -o "$SIG" "${BASE}/${NAME}.tar.gz.sig" \
    || die "Could not download the signature. Refusing to install an unsigned bundle."

# --- VERIFY BEFORE EXTRACTING. This is the whole point of the bootstrap. ------
PUB="${WORK}/pinned.pub"
printf '%s\n' "$PINNED_PUBKEY" > "$PUB"
if openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$TARBALL" -sigfile "$SIG" >/dev/null 2>&1; then
    ok "Signature verified against the pinned key."
else
    die "SIGNATURE VERIFICATION FAILED. The bundle is not genuine or was tampered with. Nothing was extracted."
fi
info "SHA-256: $(sha256sum "$TARBALL" | cut -d' ' -f1)"

# --- Extract the verified bundle into an empty dir ----------------------------
EXDIR="${WORK}/x"
mkdir -p "$EXDIR"
tar -xzf "$TARBALL" -C "$EXDIR" --no-same-owner
SRC="${EXDIR}/${NAME}"
[[ -f "${SRC}/installer/install.sh" ]] || die "Verified bundle has an unexpected layout (no installer/install.sh)."
# The application entry point is app/main — source (.py) in a source bundle, or
# a compiled extension (app/main.*.so) in a Cython-compiled release bundle.
[[ -f "${SRC}/app/main.py" ]] || compgen -G "${SRC}/app/main.*.so" >/dev/null \
    || die "Verified bundle has an unexpected layout (no app/main.py or app/main.*.so)."
ok "Bundle extracted and its layout checked."

if [[ "$NEXIA_FETCH_ONLY" == "1" ]]; then
    export NEXIA_KEEP_WORK=1
    echo
    ok "Fetch-only mode: the verified bundle is at:"
    echo "    ${SRC}"
    echo "  Inspect it, then install with:"
    echo "    sudo bash ${SRC}/installer/install.sh"
    exit 0
fi

# --- Run the real installer from inside the verified bundle. It auto-detects
#     the application tree next to it (../app) and installs from the bundle,
#     without cloning anything. All NEXIA_* variables pass through the env.
info "Starting the installer from the verified bundle…"
exec bash "${SRC}/installer/install.sh" "$@"

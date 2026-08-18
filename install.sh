#!/usr/bin/env bash
# =============================================================================
#  NEXIA Switch — public bootstrap installer
# =============================================================================
#
#  This is the ONLY file an operator downloads directly. It does four things
#  and nothing else:
#
#    1. Enrols this machine with the NEXIA licence server. Without enrolment
#       there is no download ticket, and without a ticket there is no bundle:
#       the installation cannot proceed.
#    2. Downloads the signed release bundle using that ticket.
#    3. Verifies the bundle's Ed25519 signature against the public key PINNED
#       BELOW — before a single byte of the bundle is extracted or executed.
#    4. Extracts the verified bundle and runs the real installer from inside.
#
#  The application source is PRIVATE and is never downloaded. What ships is a
#  signed artifact; this script is the trust anchor that authenticates it. If
#  the signature does not verify, nothing is extracted and nothing runs.
#
#  WHY THE ENROLMENT IS NOT OPTIONAL
#  ---------------------------------
#  The bundle is served by the licence server and by nothing else — it is not
#  on GitHub Releases, not on a CDN, nowhere a ticket is not required. Every
#  installation is therefore recorded (who, which machine, from which address)
#  BEFORE anything lands on this server. Patching this script out does not
#  help: there is no other copy of the artifact to install.
#
#  This is an INSTALL-TIME gate, not a runtime one. Once installed, the switch
#  never calls the licence server again. If that server is down your calls
#  keep flowing; the only thing you cannot do is install somewhere new.
#
#  ON TLS AND TRUST
#  ----------------
#  The licence server answers on an IP with a self-signed certificate, so the
#  transport is not verified (-k). That is deliberate and safe here: TLS is
#  not the trust boundary — the PINNED signature below is. The worst a
#  meddler on the wire can do is refuse you a bundle or hand you one that
#  fails verification and is thrown away.
#
#  USAGE
#  -----
#    curl -fsSLO https://raw.githubusercontent.com/nexiaswitch-ux/Nexia-Switch/main/install.sh
#    less install.sh                 # read it — it installs as root
#    sudo NEXIA_EMAIL=you@example.com bash install.sh
#
#    # Download and verify only, then inspect before running the installer:
#    sudo NEXIA_EMAIL=you@example.com NEXIA_FETCH_ONLY=1 bash install.sh
#
#  Any NEXIA_* variable you set (NEXIA_DOMAIN, NEXIA_ADMIN_EMAIL, …) is passed
#  straight through to the real installer.
# =============================================================================
set -euo pipefail

LICENCE_SERVER="${NEXIA_LICENCE_SERVER:-https://37.27.246.67}"

# --- The pinned signing key. The private half never leaves the vendor. A
#     bundle is trusted ONLY if it verifies against this exact key. Replacing
#     this block is the one change that redefines what "genuine" means, so it
#     lives here in the file the operator reads, not in the artifact it checks.
PINNED_PUBKEY="-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAt+ZByeKRV+Xw4gtWTnuYeSZg/9jD3pmu0lw83nG2EUM=
-----END PUBLIC KEY-----"

NEXIA_FETCH_ONLY="${NEXIA_FETCH_ONLY:-0}"
NEXIA_EMAIL="${NEXIA_EMAIL:-}"
NEXIA_NAME="${NEXIA_NAME:-}"
NEXIA_PHONE="${NEXIA_PHONE:-}"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_OFF=$'\033[0m'
info() { printf '%s  %s\n' "${C_BLU}··${C_OFF}" "$*"; }
ok()   { printf '%s  %s\n' "${C_GRN}OK${C_OFF}" "$*"; }
die()  { printf '%s  %s\n' "${C_RED}!!${C_OFF}" "$*" >&2; exit 1; }

for tool in curl openssl tar sha256sum python3; do
    command -v "$tool" >/dev/null || die "required tool not found: ${tool}"
done

# --- Who is installing -------------------------------------------------------
# Asked once, here, because the enrolment record is only worth keeping if it
# says who. An unattended run must supply NEXIA_EMAIL: prompting a script that
# nobody is watching would hang forever instead of failing.
if [[ -z "$NEXIA_EMAIL" ]]; then
    if [[ -t 0 ]]; then
        read -rp "Email to register this installation: " NEXIA_EMAIL
    else
        die "NEXIA_EMAIL is not set and there is no terminal to ask. Re-run with: NEXIA_EMAIL=you@example.com"
    fi
fi
[[ "$NEXIA_EMAIL" == *@*.* ]] || die "That does not look like an email address: ${NEXIA_EMAIL}"

# --- What machine this is ----------------------------------------------------
# Read before installing anything, so it can only use what a bare server has.
# This is NOT the licence fingerprint — nexia-licensegen does not exist here
# yet. It is enough to tell one machine from another and to recognise the same
# one coming back for a retry.
machine_id="$(cat /etc/machine-id 2>/dev/null || echo unknown)"
product_uuid="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo unknown)"
primary_if="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
primary_mac="$(cat "/sys/class/net/${primary_if:-lo}/address" 2>/dev/null || echo unknown)"
os_pretty="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"

payload="$(NEXIA_EMAIL="$NEXIA_EMAIL" NEXIA_NAME="$NEXIA_NAME" NEXIA_PHONE="$NEXIA_PHONE" \
           MID="$machine_id" PUUID="$product_uuid" MAC="$primary_mac" OSP="$os_pretty" \
           python3 - <<'PY'
import json, os
print(json.dumps({
    "email": os.environ["NEXIA_EMAIL"],
    "name":  os.environ.get("NEXIA_NAME", ""),
    "phone": os.environ.get("NEXIA_PHONE", ""),
    "fingerprint": {
        "machine_id":   os.environ.get("MID", ""),
        "product_uuid": os.environ.get("PUUID", ""),
        "mac":          os.environ.get("MAC", ""),
    },
    "os":      os.environ.get("OSP", ""),
    "version": "bootstrap-2",
}))
PY
)"

# --- 1. Enrol ----------------------------------------------------------------
info "Enrolling this machine with the licence server…"
resp="$(curl -ksS --max-time 30 -X POST "${LICENCE_SERVER}/enrol" \
        -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || true)"
[[ -n "$resp" ]] || die "Could not reach the licence server at ${LICENCE_SERVER}. Installation requires it; check outbound HTTPS and try again."

read -r ENROL_OK TICKET BUNDLE_URL SIG_URL BUNDLE_NAME VOUCHER ENROL_ERR <<<"$(
    RESP="$resp" python3 - <<'PY'
import json, os
try:
    d = json.loads(os.environ["RESP"])
except Exception:
    d = {}
print(
    "1" if d.get("ok") else "0",
    d.get("ticket", "-"),
    d.get("bundle_url", "-"),
    d.get("sig_url", "-"),
    d.get("bundle", "-"),
    d.get("voucher", "-"),
    (d.get("error", "the server refused the enrolment") or "-").replace(" ", "_"),
)
PY
)"
[[ "$ENROL_OK" == "1" ]] || die "Enrolment refused: ${ENROL_ERR//_/ }"
[[ "$VOUCHER" != "-" && -n "$VOUCHER" ]] \
    || die "The server issued no installation voucher. Refusing: without it the bundle would install anywhere."
ok "Enrolled. This installation is now on record."
info "Release: ${BUNDLE_NAME}"

# --- 2. Download the bundle and its signature into a private temp dir --------
WORK="$(mktemp -d)"
cleanup() { [[ "${NEXIA_KEEP_WORK:-0}" == "1" ]] || rm -rf "$WORK"; }
trap cleanup EXIT
chmod 700 "$WORK"

TARBALL="${WORK}/${BUNDLE_NAME}"
SIG="${TARBALL}.sig"

info "Downloading ${BUNDLE_NAME}…"
curl -ksSL --max-time 900 -o "$TARBALL" "$BUNDLE_URL" \
    || die "Could not download the bundle. The ticket lasts 15 minutes; re-run to get a new one."
curl -ksSL --max-time 60 -o "$SIG" "$SIG_URL" \
    || die "Could not download the signature. Refusing to install an unsigned bundle."

# --- 3. VERIFY BEFORE EXTRACTING. This is the whole point of the bootstrap. --
PUB="${WORK}/pinned.pub"
printf '%s\n' "$PINNED_PUBKEY" > "$PUB"
if openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$TARBALL" -sigfile "$SIG" >/dev/null 2>&1; then
    ok "Signature verified against the pinned key."
else
    die "SIGNATURE VERIFICATION FAILED. The bundle is not genuine or was tampered with. Nothing was extracted."
fi
info "SHA-256: $(sha256sum "$TARBALL" | cut -d' ' -f1)"

# --- 4. Extract the verified bundle into an empty dir ------------------------
EXDIR="${WORK}/x"
mkdir -p "$EXDIR"
tar -xzf "$TARBALL" -C "$EXDIR" --no-same-owner
SRC="$(find "$EXDIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
[[ -n "$SRC" && -f "${SRC}/installer/install.sh" ]] \
    || die "Verified bundle has an unexpected layout (no installer/install.sh)."
[[ -f "${SRC}/app/main.py" ]] || compgen -G "${SRC}/app/main.*.so" >/dev/null \
    || die "Verified bundle has an unexpected layout (no app/main.py or app/main.*.so)."
ok "Bundle extracted and its layout checked."

if [[ "$NEXIA_FETCH_ONLY" == "1" ]]; then
    export NEXIA_KEEP_WORK=1
    echo
    ok "Fetch-only mode: the verified bundle is at:"
    echo "    ${SRC}"
    umask 077
    printf '%s' "$VOUCHER" > /run/nexia-voucher
    echo "  Inspect it, then install with:"
    echo "    sudo bash ${SRC}/installer/install.sh"
    echo "  (the voucher for this machine is in /run/nexia-voucher)"
    exit 0
fi

# --- Run the real installer from inside the verified bundle. It auto-detects
#     the application tree next to it (../app) and installs from the bundle,
#     without cloning anything. All NEXIA_* variables pass through the env.
info "Starting the installer from the verified bundle…"
export NEXIA_ENROL_EMAIL="$NEXIA_EMAIL"

# The voucher authorises THIS machine and nothing else. Handed over in a file
# under /run (tmpfs, root-only, gone at reboot) rather than on a command line,
# where every process on the box could read it out of /proc.
umask 077
printf '%s' "$VOUCHER" > /run/nexia-voucher
export NEXIA_VOUCHER="$VOUCHER"
exec bash "${SRC}/installer/install.sh" "$@"

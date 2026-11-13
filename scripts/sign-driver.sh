#!/usr/bin/env bash
# =============================================================================
#  sign-driver.sh
#  Generates a self-signed code-signing certificate and Authenticode-signs
#  one or more Windows driver (.sys) files with it, on Linux, using
#  osslsigncode. See ../docs/driver-signing.md for the full explanation of
#  why this is needed (Windows 7 x64 Code 52 / STATUS_INVALID_IMAGE_HASH) and
#  how to import the resulting .cer on the Windows side.
#
#  Usage:
#     ./sign-driver.sh <output-dir> <file1.sys> [file2.sys ...]
#
#  Produces, in <output-dir>:
#     - signing-cert.pem / signing-cert.pfx / signing-cert-key.pem
#     - MyTestCert.cer                         <- import this on Windows
#     - signed/<basename of each input file>   <- the signed drivers
#
#  Needs: openssl, and osslsigncode (either installed system-wide, or
#  extractable without root from your distro's package, e.g. on an RPM
#  system with no root access:
#     dnf download --resolve osslsigncode
#     rpm2cpio osslsigncode-*.rpm | cpio -idm
#     ./usr/bin/osslsigncode --version
#  then point OSSLSIGNCODE below at that extracted binary.)
# =============================================================================
set -euo pipefail

OSSLSIGNCODE="${OSSLSIGNCODE:-osslsigncode}"
CERT_SUBJECT="${CERT_SUBJECT:-/CN=Driver Signing Test Cert/O=Local Driver Signing}"
CERT_PASS="${CERT_PASS:-changeit}"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <output-dir> <file1.sys> [file2.sys ...]" >&2
    exit 1
fi

OUT="$1"; shift
mkdir -p "$OUT/signed"

if [ ! -f "$OUT/signing-cert.pfx" ]; then
    echo "==> Generating a new self-signed code-signing certificate"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$OUT/signing-cert-key.pem" -out "$OUT/signing-cert.pem" -days 7300 \
        -subj "$CERT_SUBJECT" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
        -addext "extendedKeyUsage=codeSigning"
    openssl pkcs12 -export -out "$OUT/signing-cert.pfx" \
        -inkey "$OUT/signing-cert-key.pem" -in "$OUT/signing-cert.pem" \
        -passout "pass:$CERT_PASS"
    openssl x509 -in "$OUT/signing-cert.pem" -outform DER -out "$OUT/MyTestCert.cer"
    echo "    -> $OUT/MyTestCert.cer  (import this on the Windows side,"
    echo "       into BOTH Local Machine\\Root and Local Machine\\TrustedPublisher)"
else
    echo "==> Reusing existing certificate at $OUT/signing-cert.pfx"
    echo "    (delete it first if you want a fresh one — but then you'll need"
    echo "     to re-import the new .cer on Windows too)"
fi

for f in "$@"; do
    name="$(basename "$f")"
    echo "==> Signing $name"
    "$OSSLSIGNCODE" sign -pkcs12 "$OUT/signing-cert.pfx" -pass "$CERT_PASS" \
        -n "Re-signed: $name" \
        -in "$f" -out "$OUT/signed/$name"
done

echo
echo "Done. Signed files are in $OUT/signed/."
echo "Verify any one of them with:"
echo "  $OSSLSIGNCODE verify -in $OUT/signed/<file> -CAfile $OUT/signing-cert.pem"

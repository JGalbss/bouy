#!/bin/sh
# Vendors the root certificates that Node bundles, src/node_root_certs.h of nodejs/node at the
# tag of `.node-version`, into runtime/src/node/crypto/buoy_crypto_root_certs.erl, the source of
# tls.rootCertificates (internalBinding('crypto').getBundledRootCertificates). Each string of the
# header becomes a binary of the module, byte for byte.
#
# This script runs no node.
#
# Usage: scripts/vendor-node-root-certs.sh

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tag="v$(cat "$root/.node-version")"
out="$root/runtime/src/node/crypto/buoy_crypto_root_certs.erl"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "$0: fetching nodejs/node src/node_root_certs.h at $tag" >&2
curl -fsSL "https://raw.githubusercontent.com/nodejs/node/$tag/src/node_root_certs.h" -o "$work/certs.h"

{
  printf '%%%% The root certificates that Node %s bundles, from its src/node_root_certs.h.\n' "$tag"
  printf '%%%% scripts/vendor-node-root-certs.sh writes this file; do not edit it.\n'
  printf -- '-module(buoy_crypto_root_certs).\n\n-export([pems/0]).\n\n'
  printf -- '-spec pems() -> [binary()].\npems() ->\n    ['
  # A comment names a certificate, a quoted line continues it, and a line that ends in
  # `",` or `"` ends it.
  awk '
    /^\/\* / { sub(/^\/\* /, ""); sub(/ \*\/$/, ""); comment = $0; next }
    /^"/ {
      line = $0
      last = (line ~ /",$/ || line ~ /-----END CERTIFICATE-----"$/)
      sub(/,$/, "", line)
      if (!open) { printf "%s%%%% %s\n     <<", (count++ ? ",\n     " : ""), comment; open = 1 }
      else printf "\n       "
      printf "%s", line
      if (last) { printf ">>"; open = 0 }
    }
  ' "$work/certs.h"
  printf '].\n'
} > "$out"

echo "$0: wrote $(grep -c 'BEGIN CERTIFICATE' "$out") certificates to $out" >&2

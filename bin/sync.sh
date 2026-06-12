#!/usr/bin/env bash
# DEPRECATED stub — renomeado para bin/checkout-sync.sh (US-05). Remoção no sunset 2026-09-01.
echo "[deprecation] bin/sync.sh → use bin/checkout-sync.sh (remoção 2026-09-01)." >&2
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/checkout-sync.sh" "$@"

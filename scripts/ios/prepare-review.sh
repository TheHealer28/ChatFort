#!/bin/sh

set -eu

script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
INQALAAB_SCRUB_LIBS=1 exec bash "$script_dir/stage-rebuilt-libs.sh" "${1:-}" "${2:-}"

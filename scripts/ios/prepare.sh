#!/bin/sh

set -eu

script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
exec bash "$script_dir/stage-rebuilt-libs.sh" "${1:-}"

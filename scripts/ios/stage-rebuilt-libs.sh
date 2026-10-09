#!/bin/bash

set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
root_dir="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
libraries_dir="$root_dir/apps/ios/Libraries"
pbxproj="$root_dir/apps/ios/SimpleX.xcodeproj/project.pbxproj"
mac2ios_bin=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

discover_project_haskell_names() {
  local -a names
  local ghc_name=""
  local core_name=""

  names=($(grep -o 'libHS[^"]*\.a' "$pbxproj" | awk '!seen[$0]++'))

  for name in "${names[@]}"; do
    if [[ "$name" == *-ghc*.a ]]; then
      ghc_name="$name"
    else
      core_name="$name"
    fi
  done

  [[ -n "$ghc_name" ]] || die "Could not discover the GHC archive name from $pbxproj"
  [[ -n "$core_name" ]] || die "Could not discover the runtime archive name from $pbxproj"

  printf '%s\n%s\n' "$ghc_name" "$core_name"
}

resolve_source() {
  local arch="$1"
  local explicit="${2:-}"
  local -a candidates=()

  if [[ -n "$explicit" ]]; then
    [[ -e "$explicit" ]] || die "Source '$explicit' does not exist"
    printf '%s\n' "$explicit"
    return 0
  fi

  if [[ "$arch" == "aarch64" ]]; then
    candidates=(
      "$root_dir/result-aarch64-ios-current"
      "$root_dir/result"
      "$root_dir/result-aarch64-ios"
      "$root_dir/result-aarch64"
      "$HOME/Downloads/pkg-ios-aarch64-swift-json"
      "$HOME/Downloads/pkg-ios-aarch64-swift-json.zip"
    )
  else
    candidates=(
      "$root_dir/result-x86_64-ios-current"
      "$root_dir/result-x86_64-ios"
      "$root_dir/result-x86_64"
      "$root_dir/result-sim"
      "$HOME/Downloads/pkg-ios-x86_64-swift-json"
      "$HOME/Downloads/pkg-ios-x86_64-swift-json.zip"
    )
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

materialize_source() {
  local arch="$1"
  local source_path="$2"
  local unpack_dir="$3"

  if [[ -f "$source_path" ]]; then
    unzip -qo "$source_path" -d "$unpack_dir"
    printf '%s\n' "$unpack_dir"
    return 0
  fi

  if [[ -d "$source_path" ]]; then
    if [[ -f "$source_path/pkg-ios-$arch-swift-json.zip" ]]; then
      unzip -qo "$source_path/pkg-ios-$arch-swift-json.zip" -d "$unpack_dir"
      printf '%s\n' "$unpack_dir"
      return 0
    fi

    if find "$source_path" -maxdepth 1 -type f -name 'libHS*.a' | grep -q .; then
      printf '%s\n' "$source_path"
      return 0
    fi
  fi

  die "Could not find iOS $arch libraries in '$source_path'"
}

find_haskell_archives() {
  local source_dir="$1"
  local ghc_archive
  local runtime_archive

  ghc_archive="$(find "$source_dir" -maxdepth 1 -type f -name 'libHS*-ghc*.a' | sort | head -n 1)"
  runtime_archive="$(find "$source_dir" -maxdepth 1 -type f -name 'libHS*.a' ! -name 'libHS*-ghc*.a' | sort | head -n 1)"

  [[ -n "$ghc_archive" ]] || die "No libHS*-ghc*.a archive found in '$source_dir'"
  [[ -n "$runtime_archive" ]] || die "No libHS*.a runtime archive found in '$source_dir'"

  printf '%s\n%s\n' "$ghc_archive" "$runtime_archive"
}

resolve_mac2ios() {
  local candidate

  if command -v mac2ios >/dev/null 2>&1; then
    command -v mac2ios
    return 0
  fi

  for candidate in /nix/store/*-mac2ios/bin/mac2ios; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "mac2ios is not on PATH and was not found in /nix/store"
}

copy_supporting_archives() {
  local source_dir="$1"
  local dest_dir="$2"
  local archive

  for archive in libffi.a libgmp.a libgmpxx.a; do
    [[ -f "$source_dir/$archive" ]] || die "Missing '$archive' in '$source_dir'"
    cp -f "$source_dir/$archive" "$dest_dir/$archive"
  done
}

convert_dir() {
  local dest_dir="$1"
  local sim_flag="${2:-0}"
  local archive

  for archive in "$dest_dir"/*.a; do
    chmod u+w "$archive"
    if [[ "$sim_flag" == "1" ]]; then
      "$mac2ios_bin" -s "$archive" >/dev/null
    else
      "$mac2ios_bin" "$archive" >/dev/null
    fi
    chmod a-w "$archive"
  done
}

stage_runtime_archives() {
  local source_dir="$1"
  local vendor_dir="$2"
  local runtime_dir="$3"
  local ghc_target_name="$4"
  local runtime_target_name="$5"
  local sim_flag="${6:-0}"
  local -a hs_archives

  rm -rf "$vendor_dir" "$runtime_dir"
  mkdir -p "$vendor_dir" "$runtime_dir"

  cp -f "$source_dir"/*.a "$vendor_dir"/
  chmod -R u+w "$vendor_dir"

  hs_archives=($(find_haskell_archives "$source_dir"))

  copy_supporting_archives "$source_dir" "$runtime_dir"
  cp -f "${hs_archives[0]}" "$runtime_dir/$ghc_target_name"
  cp -f "${hs_archives[1]}" "$runtime_dir/$runtime_target_name"

  convert_dir "$runtime_dir" "$sim_flag"
}

main() {
  local aarch64_source_arg="${1:-}"
  local x86_64_source_arg="${2:-}"
  local aarch64_source
  local x86_64_source=""
  local aarch64_materialized
  local x86_64_materialized=""
  local -a project_archives
  local temp_root

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/stage-ios-libs.XXXXXX")"
  trap 'rm -rf '"'"$temp_root"'"'' EXIT
  mac2ios_bin="$(resolve_mac2ios)"

  aarch64_source="$(resolve_source aarch64 "$aarch64_source_arg")" || die "Could not resolve an aarch64 iOS rebuild source"
  if x86_64_source="$(resolve_source x86_64 "$x86_64_source_arg" 2>/dev/null)"; then
    :
  else
    x86_64_source=""
  fi

  aarch64_materialized="$(materialize_source aarch64 "$aarch64_source" "$temp_root/aarch64")"
  if [[ -n "$x86_64_source" ]]; then
    x86_64_materialized="$(materialize_source x86_64 "$x86_64_source" "$temp_root/x86_64")"
  fi

  project_archives=($(discover_project_haskell_names))

  rm -rf "$libraries_dir/mac" "$libraries_dir/mac-aarch64" "$libraries_dir/mac-x86_64" "$libraries_dir/ios" "$libraries_dir/sim"

  stage_runtime_archives \
    "$aarch64_materialized" \
    "$libraries_dir/mac-aarch64" \
    "$libraries_dir/ios" \
    "${project_archives[0]}" \
    "${project_archives[1]}" \
    0

  if [[ -n "$x86_64_materialized" ]]; then
    stage_runtime_archives \
      "$x86_64_materialized" \
      "$libraries_dir/mac-x86_64" \
      "$libraries_dir/sim" \
      "${project_archives[0]}" \
      "${project_archives[1]}" \
      1
  else
    stage_runtime_archives \
      "$aarch64_materialized" \
      "$libraries_dir/mac-aarch64" \
      "$libraries_dir/sim" \
      "${project_archives[0]}" \
      "${project_archives[1]}" \
      1
  fi

  printf 'Staged device libraries from: %s\n' "$aarch64_source"
  if [[ -n "$x86_64_source" ]]; then
    printf 'Staged simulator libraries from: %s\n' "$x86_64_source"
  else
    printf 'Staged simulator libraries from: %s (arm64 fallback)\n' "$aarch64_source"
  fi
  if [[ "${INQALAAB_SCRUB_LIBS:-0}" == "1" ]]; then
    printf 'Applying iOS library scrub (INQALAAB_SCRUB_LIBS=1)...\n'
    python3 "$root_dir/scripts/patch-ios-libraries.py"
  else
    printf 'Skipping iOS library scrub (set INQALAAB_SCRUB_LIBS=1 to enable)\n'
  fi
  printf 'Xcode-linked archives: %s, %s\n' "${project_archives[0]}" "${project_archives[1]}"
}

main "$@"

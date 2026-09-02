#!/bin/sh

set -eu

manifest_version=$(awk -F'"' '/^version = "/ { print $2; exit }' mach.toml)
source_version=$(awk -F'"' '/^pub val VERSION: str = "/ { print $2; exit }' src/hedge.mach)

if [ -z "$manifest_version" ] || [ -z "$source_version" ]; then
    echo "release version is missing" >&2
    exit 1
fi

if [ "$manifest_version" != "$source_version" ]; then
    echo "release version mismatch: mach.toml=$manifest_version src/hedge.mach=$source_version" >&2
    exit 1
fi

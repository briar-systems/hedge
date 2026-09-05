# shared by every demo runner: find a hedge binary, or build one.
#
# source this, then call `hedge_binary` and `hedge_serve <config>`.

demo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$demo_root/.." && pwd)"

hedge_binary() {
    if [ -n "${HEDGE_BINARY:-}" ]; then
        printf '%s\n' "$HEDGE_BINARY"
        return 0
    fi
    local built="$repo_root/out/linux-x86_64/release/bin/hedge"
    if [ ! -x "$built" ]; then
        echo "building hedge (release); this takes a few minutes the first time" >&2
        mach build "$repo_root" --profile release >&2 || return 1
    fi
    printf '%s\n' "$built"
}

# start hedge on a configuration and stop it when this shell exits.
hedge_serve() {
    local config="$1"
    local binary
    binary="$(hedge_binary)" || exit 1
    echo "hedge $config" >&2
    exec "$binary" "$config"
}

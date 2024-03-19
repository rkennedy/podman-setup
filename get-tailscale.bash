#!/bin/bash
# Fetch the specified version (the latest version, by default) of the Tailscale
# image and tag it as "current."
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly script_dir
. "${script_dir}/include.bash"

usage() {
    printf 'Usage: %s [VERSION]
Fetch the specified version of the Tailscale image and tag it as "current."

With no VERSION, determine the latest version and fetch that instead.

Options:
  -h, --help  Print this help.
' "$0"
}

args=$(getopt --options h --longoptions help --name $(basename "$0") -- "$@")
eval set -- "${args}"

while :; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
    esac
    shift
done

tailscale_image_version="${1-}"

if [ -z "${tailscale_image_version}" ]; then
    # No version specified. Determine the latest version.
    tailscale_image_version=$(curl --no-progress-meter --fail https://api.github.com/repos/tailscale/tailscale/releases/latest | jq --raw-output '.tag_name')
    printf 'Fetching latest version %s\n' "${tailscale_image_version}"
fi

ensure-image "${tailscale_image_base}" "${tailscale_image_version}"

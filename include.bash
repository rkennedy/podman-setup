readonly tailscale_image_base=ghcr.io/tailscale/tailscale
readonly tailscale_image_version=v1.58.2

# Create a volume if it doesn't exist.
# Arguments:
# 1. name of the application. Applied as a label on the volume.
# 2. name of the volume
# 3. volume role. Applied as a label on the volume.
ensure-volume() {
    local -r _app="$1"
    local -r _name="$2"
    local -r _role="$3"
    if ! podman volume exists "${_name}"; then
        podman volume create --label app="${_app}" --label role="${_role}" "${_name}"
    fi
}

# Create and populate a secret if it doesn't exist.
# Arguments:
# 1. name of the application. Applied as a label on the secret.
# 2. name of the secret
# 3. name of the file that holds the secret's contents
# 4. secret role. Applied as a label on the secret.
ensure-secret() {
    local -r _app="$1"
    local -r _name="$2"
    local -r _source="$3"
    local -r _role="$4"
    if ! podman secret exists "${_name}"; then
        test -f "${_source}" || test -p "${_source}"
        local -r secret_args=(
            --driver file
            --label app="${_app}"
            --label role="${_role}"
        )
        printf '%s' $(< ${_source}) | podman secret create "${secret_args[@]}" "${_name}" -
    fi
}

# Create a Kubernetes-style secret for use with `podman kube play`.
# Arguments:
# 1. name of the application. Applied as a label on the secret.
# 2. name of the secret
# 3. secret role. Applied as a label on the secret.
# 4,5,…. names and values of the secret components.
ensure-kube-secret() {
    local -r _app="${1}"
    local -r _name="${2}"
    local -r _role="${3}"
    shift 3
    if podman secret exists "${_name}"; then
        return
    fi

    local -r _secret_args=(
        --driver file
        --label app="${_app}"
        --label role="${_role}"
    )
    local _json_args=(
        --null-input
        --arg app "${_app}"
        --arg name "${_name}"
        --args
    )
    jq "${_json_args[@]}" '{
        kind: "Secret",
        apiVersion: "v1",
        metadata: {
            name: $name,
            labels: {
                app: $app
            }
        },
        data: [
            # Iterate over pairs of name/value positional arguments.
            range(0; $ARGS.positional | length; 2) | {
                ($ARGS.positional[.]): $ARGS.positional[. + 1] | @base64
            }
        ] | add
    }' "$@" | podman secret create "${_secret_args[@]}" "${_name}" -
}

# Pull an image if it's not already present. Tag it as the _current_ image.
# Arguments:
# 1. The name of the image.
# 2. The image's tag. Usually a version.
ensure-image() {
    local -r _base="$1"
    local -r _version="$2"
    if ! podman image exists "${_base}:${_version}"; then
        podman image pull "${_base}:${_version}"
    fi
    podman image tag "${_base}:${_version}" "${_base}:current"
}

# Create a container if it doesn't exist.
# Arguments:
# 1. The name of the container
# 2-N. Additional arguments for `podman container create`. This should include
#    the image name as the final item.
ensure-container() {
    local -r _name="$1"
    shift
    if ! podman container exists "${_name}"; then
        podman container create --name "${_name}" "$@"
    fi
}

# Create a pod if it doesn't exist.
# Options:
# -a, --app APP  Use APP for the application name. Required.
# -n, --name N   The friendly name of the application. sed in Systemd service
#                label.
# -t, --tailscale SECRET  Include a Tailscale sidecar. An authorization key
#                should be in a secret named SECRET. This creates a volume to
#                hold Tailscale's persistent data, and adds a container to the
#                pod.
#
# Additional arguments for `podman pod create`, such as which ports to publish,
# should follow a "--" argument..
ensure-pod() {
    local -r _args=$(getopt -o a:n:t: --long app:,name:,tailscale: --name ensure-pod -- "$@")
    eval set -- "${_args}"
    while :; do
        case "$1" in
            -a|--app)
                local -r _app="$2"
                shift
                ;;
            -n|--name)
                local -r _app_friendly_name="$2"
                shift
                ;;
            -t|--tailscale)
                local -r _ts_auth_key_secret="$2"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    if ! podman pod exists "${_app}"; then
        local _pod_args=(
            --label app="${_app}"
            --name "${_app}"
            --infra
            --infra-name "${_app}"-infra
        )
        if [[ -n "${_ts_auth_key_secret}" ]]; then
            _pod_args+=(
                --dns 100.100.100.100
                --dns-search "$(tailscale status --json | jq -r '.MagicDNSSuffix')"
            )
        fi
        _pod_args+=(
            "$@"
        )
        podman pod create "${_pod_args[@]}"
    fi
    printf '[Unit]\nDescription=%s\n' "${_app_friendly_name}" > "${script_dir}/${_app}.description.conf"

    if [[ -n "${_ts_auth_key_secret}" ]]; then
        local -r _volume="data-${_app}-tailscale"

        local -r _ts_args=(
            # Associate the sidecar with the given application pod.
            --label app="${_app}"
            --pod "${_app}"
            # The Tailscale node name matches the application name.
            --hostname "${_app}"

            --log-opt tag=TAIL
            --rm
            --secret "${_ts_auth_key_secret}",type=env,target=TS_AUTHKEY

            # Tailscale requires storage and a tunneling device.
            --env TS_STATE_DIR=/ts-state
            --volume "${_volume}":/ts-state:rw
            --device /dev/net/tun

            "${tailscale_image_base}:current"
        )

        ensure-volume "${_app}" "${_volume}" data

        ensure-image "${tailscale_image_base}" "${tailscale_image_version}"

        ensure-container "${_app}-tailscale" "${_ts_args[@]}"

        printf '[Unit]\nDescription=%s Tailscale sidecar\n' "${_app_friendly_name}" > "${script_dir}/${_app}-tailscale.description.conf"
    fi
}

# Generate .service files for all the application's containers.
# Arguments:
# 1. The name of the application. If this refers to a pod, then all the pod's
#    containers are processed, producing a .service file for each of them. If
#    the name refers to a container, then only that container is processed.
generate-systemd() {
    local -r _app="$1"

    podman generate systemd --new --name --files --container-prefix '' --pod-prefix '' "${_app}"
}

# Copy Systemd files to their installed location and activate the service. If
# there are any .conf files in the repo whose names start the same as any
# services, they are copied to a corresponding .d directory. (Useful for
# overriding the service description, which Podman always fills in with a
# generic name.
# Arguments:
# 1. The name of the application.
install-services() {
    local -r _app="$1"

    local -r _user_services="${HOME}/.config/systemd/user"

    while IFS= read -r -d $'\0' _service; do
        mkdir --parents "${_user_services}"
        cp --verbose --target-directory "${_user_services}" "${_service}"
        local _service_name="${_service%.*}"
        while IFS= read -r -d $'\0' _conf; do
            mkdir --parents "${_user_services}/${_service_name}.service.d"
            cp --verbose --target-directory "${_user_services}/${_service_name}.service.d" "${_conf}"
        done < <(git ls-files -z "${_service_name}.*.conf")
        systemctl --user enable "${_service_name}"
    done < <(git ls-files -z '*.service')
    while IFS= read -r -d $'\0' _timer; do
        mkdir --parents "${_user_services}"
        cp --verbose --target-directory "${_user_services}" "${_timer}"
        systemctl --user enable --now "${_timer}"
    done < <(git ls-files -z '*.timer')

    if systemctl --user list-unit-files "${_app}.service" >/dev/null; then
        systemctl --user start "${_app}"
    fi
}

install-files() {
    local _delete=false
    local -r _args=$(getopt -o d --long delete --name install-files -- "$@")
    eval set -- "${_args}"
    while :; do
        case "$1" in
            -d|--delete)
                _delete=:
                ;;
            --)
                shift
                break
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    local -r _destination=${1}
    shift
    mapfile -d '' _files < <(git ls-files -z -- "$@" | sort --zero-terminated)
    if [ -d "${_destination}" ]; then
        mapfile -d '' _existing_files < <(find "${_destination}" -type f -printf '%P\0' | sort --zero-terminated)
    else
        local _existing_files=()
    fi

    if ${_delete} && (( ${#_existing_files[@]} )); then
        mapfile -d '' _files_to_remove < <(comm --zero-terminated -13 <(printf '%s\0' "${_files[@]}") <(printf '%s\0' "${_existing_files[@]}"))
        if (( ${#_files_to_remove[@]} )); then
            (cd "${_destination}" && rm --verbose --force -- "${_files_to_remove[@]}")
        fi
    fi
    if (( ${#_files[@]} )); then
        install --verbose --compare --mode 0644 -D --target-directory "${_destination}" "${_files[@]}"
    fi
}

install-quadlet() {
    local -r _app="$1"
    local -r _quadlet_destination="${XDG_CONFIG_HOME-${HOME}/.config}"/containers/systemd/"${_app}"
    local -r _service_destination="${XDG_CONFIG_HOME-${HOME}/.config}"/systemd/user

    if git ls-files '*.pod' | grep -q pod; then
        local -r _service="${_app}-pod"
    else
        local -r _service="${_app}"
    fi

    systemctl --user stop "${_service}" || true

    install-files "${_quadlet_destination}" --delete '*.container' '*.volume' '*.network' '*.kube' '*.pod'
    install-files "${_service_destination}" '*.timer' '*.service'

    /usr/local/lib/systemd/system-generators/podman-system-generator -dryrun -user >/dev/null
    systemctl --user daemon-reload
    systemctl --user start "${_service}"

    mapfile -d '' _services < <(git ls-files -z -- '*.timer' '*.service')
    if (( ${#_services[@]} )); then
        systemctl --user enable --now "${_services[@]}"
    fi
}

# vim: set et sw=4:

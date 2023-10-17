# The image and version of rclone to use for copying files to Google Drive.
readonly rclone=docker.io/rclone/rclone:1.62.2
# The name of the volume that holds rclone configuration, including Google
# Drive credentials.
readonly config_volume=config-rclone-vaultwarden

# Create a staging directory to hold the files that are to ne backed up. A trap
# is configured to delete the staging directory when the script exits.
# Arguments:
# 1. The application name.
# 2. The name of a variable to hold the name of the new staging directory.
create-staging() {
    local -r _app="$1"
    local -r _var="$2"
    local -r _staging=$(mktemp --directory --suffix ".${_app}-backup")
    trap "rm -rf ${_staging@Q}" EXIT

    # We write to the caller's variable here. We can't use the "normal" way of
    # writing to stdout for the caller to receive via output capture. The
    # caller would need to use a subshell, but the trap above needs to apply to
    # the caller, not to the subshell.
    printf -v "${_var}" '%s/%s' "${_staging}" "${_app}"
    mkdir "${!_var}"
}

# Create a tarball of the staging directory and copy it to Google Drive. This
# loads Drive credentials from $config_volume written by previous rclone
# configuration. The tarball's base name will be the app name previously given
# to create-staging, and the tarball will be deleted in the exit trap along
# with the rest of the staging directory.
# Arguments:
# 1. The name of the staging directory created by create-staging.
upload-backup() {
    local -r _staging="$1"

    local -r _app=$(basename "${_staging}")
    local -r _workdir=$(dirname "${_staging}")

    tar --create --verbose --file "${_workdir}/${_app}.tar.gz" --gzip --directory "${_workdir}" "${_app}"

    local -r _backup_args=(
        --rm
        --cap-drop all
        --volume "${config_volume}":/config/rclone:rw
        --volume "${_workdir}":/data:ro
        "${rclone}"
        copy "/data/${_app}.tar.gz" gdrive:Backups --progress -vvvv
    )
    podman run "${_backup_args[@]}"
}

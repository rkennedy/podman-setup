# Podman setup

This is a collection of functions to help deploying Podman containers as
Systemd services and then running regular backups of their data..

# Conventions

Each container runs from a tag named _current_. The idea is that it's a tag
that only exists locally. It's an alias for whatever image version we want to
use. To upgrade, pull a new version of an image and re-tag it as _current_.
Then restart the service with `systemctl --user restart $service`. This avoids
having to re-generate and re-copy the .service file just for a version change.

Some functions expect a global variable `$script_dir` to be set, referring to
the directory where the calling script is running. This can probably be
derived. Here's one way to set it:

```bash
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
readonly script_dir
```

# Tailscale authorization

The Tailscale sidecar needs the `TS_AUTHKEY` environment variable set. Keep it
in a _secret_ that Podman can mount as an environment variable. The key will
only be used once on first setup, but the secret needs to continue to exist in
the event the container needs to be restarted. Create the secret like this:

```bash
printf '%s' "${key}" | podman secret create --label app=${app} --label role=credentials ${secret} -
```

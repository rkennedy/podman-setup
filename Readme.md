# Podman setup

This is a collection of functions to help deploying Podman containers as
Systemd services.

# Conventions

Each container runs from a tag named _current_. The idea is that it's a tag
that only exists locally. It's an alias for whatever image version we want to
use. To upgrade, pull a new version of an image and re-tag it as _current_.
Then restart the service with `systemctl --user restart $service`. This avoids
having to re-generate and re-copy the .service file just for a version change.

# Tailscale authorization

The Tailscale sidecar needs the `TS_AUTHKEY` environment variable set. Keep it
in a _secret_ that Podman can mount as an environment variable. The key will
only be used once on first setup, but the secret needs to continue to exist in
the event the container needs to be restarted. Create the secret like this:

```bash
printf '%s' "${key}" | podman secret create --label app=${app} --label role=credentials ${secret} -
```

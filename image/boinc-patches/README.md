# Patches for the BOINC sources

Applied in order with `git apply` after cloning `BOINC_REF` (see `image/Containerfile`).
If a patch no longer applies after changing `BOINC_REF`, the build fails: check whether
the fix is included upstream and remove the patch, or rebase it.

| Patch | Problem | Upstream |
|---|---|---|
| `0001-script_validator-strip-delimiter.patch` | `script_validator --init_script "script files result_id"` calls the script without arguments, because `split()` keeps the trailing space in each part | not yet reported |
| `0002-docker_wrapper-podman-cpu-time.patch` | with rootless Podman under the client service the container has no cgroup of its own, and `podman stats` reports the enclosing cgroup (absurd CPUPerc; CPUNano = CPU time of all BOINC tasks). On Linux the wrapper sums the CPU time of the container's processes from `/proc` instead | not yet reported |

The docker_wrapper is shipped to the volunteers with each app version and its physical
name carries a hash. A changed wrapper therefore only reaches the clients with a **new
app version** (raise `APP_VERSION` and run `boinc-app install` again).

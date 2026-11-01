# Patches for the BOINC sources

Applied in order with `git apply` after cloning `BOINC_REF` (see `image/Containerfile`).
If a patch no longer applies after changing `BOINC_REF`, the build fails: check whether
the fix is included upstream and remove the patch, or rebase it.

| Patch | Problem | Upstream |
|---|---|---|
| `0001-script_validator-strip-delimiter.patch` | `script_validator --init_script "script files result_id"` calls the script without arguments, because `split()` keeps the trailing space in each part | not yet reported |
| `0002-docker_wrapper-podman-cpu-time.patch` | with rootless Podman under the client service the container has no cgroup of its own, and `podman stats` reports the enclosing cgroup (absurd CPUPerc; CPUNano = CPU time of all BOINC tasks). On Linux the wrapper sums the CPU time of the container's processes from `/proc` instead | not yet reported |
| `0003-ops-user-administration.patch` | admin pages: project preferences per venue and the user's computers on "Manage user", status messages after updating special user status or suspensions, users by registration date with expandable details | not yet proposed |
| `0004-docker_wrapper-image-cleanup.patch` | apps with `image_name` in `job.toml` get one image per app version, but the client only removes its own `boinc__…` images: old app images and base images pile up on the volunteer's host (several GB per GPU app version). After building a new image the wrapper removes older versions of the app's image, other tags of its base image (`FROM`) and dangling images; images in use by a container are kept | not yet reported |
| `0005-docker_wrapper-podman-cdi-gpu.patch` | GPU apps always get `--gpus all`, which Podman only knows since version 5: with Podman 4.x (e.g. 4.9.3 in Ubuntu 24.04 / Linux Mint 22) no container is created ("unknown flag: --gpus"). With Podman the wrapper now uses the CDI device `--device nvidia.com/gpu=all` (Podman 4.1+, needs `nvidia-ctk cdi generate`); Docker keeps `--gpus all` | not yet reported |

The image's BOINC version string (`BOINC_REF` in the image, `.boinc_image_ref` in the
project) carries a hash of these patches, e.g. `server_release/1.6/1.6.2+p1a2b3c4d`.
When a patch is added or changed, the daemons container of every project therefore runs
the regular upgrade (database dump, `tools/upgrade`) on its next start, which copies the
patched programs and web pages into the project. `html/project/` is not touched.

The docker_wrapper is shipped to the volunteers with each app version and its physical
name carries a hash. A changed wrapper therefore only reaches the clients with a **new
app version** (raise `APP_VERSION` and run `boinc-app install` again).

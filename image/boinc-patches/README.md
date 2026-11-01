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
| `0006-docker_wrapper-timestamps.patch` | the wrapper's log in the task's stderr has no times, so it is hard to tell whether a task spent its time pulling the image, building it or running. Every wrapper line now starts with the local time, each docker/podman command logs `command finished after N s` (`DOCKER_CONN::command` in `lib/util.cpp`), and the end of the container is logged with exit code and CPU time | not yet proposed |
| `0007-docker_wrapper-assigned-gpu.patch` | all GPUs are passed into the container and the GPU the client assigned to the task is not passed on, so on hosts with several NVIDIA GPUs all tasks ran on the first one. The wrapper now sets `CUDA_VISIBLE_DEVICES` to the client's device number (CUDA device order, as used by the client). Not yet tested on a host with several GPUs | not yet reported |
| `0008-start-stop-daemons-python3.patch` | `bin/stop` (`start --stop`) never removed its PID files under Python 3 (lazy `map()`), and PID 0 from an unreadable file signalled its own process group. With PIDs reused in a new container, `tools/upgrade` failed with "Couldn't stop project!" or sent SIGHUP to unrelated processes. The entrypoint also removes leftover PID files when the daemons container starts | not yet reported |
| `0009-docker_wrapper-start-failure.patch` | a failing `podman start` (e.g. "unresolvable CDI devices nvidia.com/gpu=all" without the NVIDIA CDI specification) went unnoticed: the container stayed "Created" and the task waited until the volunteer aborted it, with the error cut off at the beginning of the log. The wrapper now fails the task when `start` reports an error or the container is still "Created" after 60 s, and repeats the error at the end of the log with a hint for GPU/CDI problems | not yet reported |

The image's BOINC version string (`BOINC_REF` in the image, `.boinc_image_ref` in the
project) carries a hash of these patches, e.g. `server_release/1.6/1.6.2+p1a2b3c4d`.
When a patch is added or changed, the daemons container of every project therefore runs
the regular upgrade (database dump, `tools/upgrade`) on its next start, which copies the
patched programs and web pages into the project. `html/project/` is not touched.

The docker_wrapper is shipped to the volunteers with each app version and its physical
name carries a hash. A changed wrapper therefore only reaches the clients with a **new
app version** (raise `APP_VERSION` and run `boinc-app install` again).

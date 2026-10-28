# Docker apps

BOINC 1.6 can ship applications as container images. The volunteer's BOINC client receives
the `docker_wrapper`, a `Dockerfile` and the app files, builds the image locally with
Docker or Podman and runs each job in a container.

The server image of boinc-stack contains:

- `docker_wrapper` for Linux x86_64, statically linked, so it also runs on older distributions
- the example app `gpucheck` under `image/apps/`
- `boinc-app`, which registers an app (plan class, app version, templates, validator and
  assimilator) and creates jobs

Science apps are kept in a separate repository,
[MBlenn/boinc-apps](https://github.com/MBlenn/boinc-apps), together with the CI that builds
their app images. `boinc-app install <app> --from <source>` installs an app from there (or
from any repository or directory with the same layout, see [App format](#app-format)).

Currently supported: **Linux hosts with an NVIDIA GPU**. Windows (WSL) and AMD GPUs are not
covered yet.

## Example app: gpucheck

`gpucheck` checks whether an NVIDIA GPU is visible inside the container and reports
`nvidia-smi` output (GPU name, driver, memory, compute capability). It is the first step
before real GPU workloads. A result like "nvidia-smi: not available" means the job ran,
but the GPU was not passed into the container.

Plan class `docker_nvidia`: only hosts that report Docker/Podman **and** an NVIDIA GPU get these jobs.

### On the server (as the project user)

```bash
podman exec <project>-daemons boinc-app list
podman exec <project>-daemons boinc-app install gpucheck
podman exec <project>-daemons boinc-app submit gpucheck 3
# after the clients have reported:
podman exec <project>-daemons boinc-app results gpucheck
```

`install` can be repeated safely. To deploy changed app files, raise `APP_VERSION` in
`image/apps/<app>/app.env`, rebuild the image and run `install` again.

### Apps from another repository

```bash
podman exec <project>-daemons boinc-app install gnina --from https://github.com/MBlenn/boinc-apps
podman exec <project>-daemons boinc-app install gnina --from https://github.com/MBlenn/boinc-apps@v1.0
podman exec <project>-daemons boinc-app install myapp --from /path/in/container/myrepo
```

The repository is downloaded as a tarball (branch, tag or commit after `@`, default `main`)
and must contain `apps/<app>/`. `install` copies the app definition into the project
(`<project dir>/boinc_apps/<app>/`, origin and time in `SOURCE`). `submit`, `results` and the
app's server scripts use that copy, so a project keeps working the same way until the app is
installed again. `boinc-app list` shows the installed apps and their origin.

### On the volunteer's host (Linux, NVIDIA)

1. **BOINC client 8.2 or newer.** At startup the client looks for Podman first, then
   Docker, and runs `hello-world` **as the user the client runs as** (`boinc` for the
   distribution packages). If that test fails, the event log may not mention Docker or
   Podman at all.
2. **Make the container runtime usable for the client user** (Podman is recommended, it runs rootless):
   - Podman: the client user needs subordinate IDs, then reset Podman's storage once:
     ```bash
     sudo usermod --add-subuids 500000-565535 --add-subgids 500000-565535 boinc
     cd /tmp && sudo -u boinc podman system migrate
     ```
     The client service has no systemd user session, so Podman prints four warnings per command
     and falls back to cgroupfs (which works). To silence them, set cgroupfs explicitly for the
     client user (home directory of `boinc` on Debian/Ubuntu: `/var/lib/boinc`):
     ```bash
     sudo -u boinc mkdir -p /var/lib/boinc/.config/containers
     printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' \
       | sudo -u boinc tee /var/lib/boinc/.config/containers/containers.conf
     ```
   - Docker: `sudo usermod -aG docker boinc`. Members of the `docker` group are effectively root.
3. **NVIDIA Container Toolkit** (package `nvidia-container-toolkit` from NVIDIA's apt repository,
   see the [installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)):
   - Podman: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, check with `nvidia-ctk cdi list`.
     Recent toolkit versions also install `nvidia-cdi-refresh.service`, which regenerates the
     CDI specification after driver updates.
   - Docker: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
4. **Test as the client user** (run it from a directory the user can access, e.g. `/tmp`):
   ```bash
   cd /tmp && sudo -u boinc podman run --rm --gpus all docker.io/library/debian:trixie-slim nvidia-smi
   # or: cd /tmp && sudo -u boinc docker run --rm --gpus all debian:trixie-slim nvidia-smi
   ```
5. Restart the BOINC client. The event log must show a line like `Docker: version 5.7.0 (podman)`.
   If there is no such line, Podman/Docker does not work for the client user (see steps 2 to 4).
   Then update the project.

## Why app images must not use RUN

The client runs as a system service (user `boinc`) without a systemd user session. Rootless
Podman falls back to cgroupfs for normal containers, but `RUN` steps during `podman build`
try to create a systemd scope and fail with "Access denied … interactive authentication".
Pulling a base image does not need that, so everything the app needs is put into a base
image on GHCR (`app-base/`, built by the same workflow). The GHCR package `boinc-app-base`
must be public.

## Where the results are

The job output goes to the output file, not to stderr. `gpucheck` writes the `nvidia-smi`
report to `out`, which is uploaded and copied by the assimilator to
`<project dir>/results/`. Show it with `boinc-app results gpucheck`. The task's stderr only
contains the docker_wrapper log (and the container's stderr, if any).

## App format

An app is a directory `apps/<app>/` (in this repository under `image/apps/`). Start from
`image/apps/gpucheck` or, for an app with input files and its own validator, from `apps/gnina`
in boinc-apps:

| File | Purpose |
|---|---|
| `app.env` | `APP_NAME`, `APP_TITLE`, `APP_VERSION`, `PLAN_CLASS` |
| `plan_class.xml` | `<plan_class>` block, added to the project's `plan_class_spec.xml` |
| `files/Dockerfile` | image built on the host. The slot directory is mounted at `/app`. **No `RUN` steps**: start `FROM ghcr.io/mblenn/boinc-app-base:trixie` (or another image that already contains everything, including `procps`) and only use `WORKDIR`, `COPY`, `ENV`, `CMD`. |
| `files/job.toml` | docker_wrapper options, e.g. `use_gpu = true`, `image_name` (without `:tag`, see the comment in gpucheck's job.toml) |
| `files/*` | further app files (scripts, binaries). `@APP_VERSION@` is substituted. |
| `templates/in.xml`, `templates/out.xml` | input and output templates for `create_work`. Values set here override `create_work` options, so leave out anything `jobs.py` sets per job (e.g. `rsc_fpops_est`, `max_error_results`). |
| `server/*` (optional) | scripts copied to the project's `bin/` (mode 755), e.g. a validator for `script_validator` |
| `jobs.py` (optional) | `make_jobs(count, rng, stamp, testdata)` returns a list of jobs for `submit`: `{"name": ..., "inputs": [files in testdata/], "options": [create_work options], "args": "command line"}`. Without it, `submit` creates jobs without input files. |
| `testdata/` (optional) | input files referenced by `jobs.py`. They are staged into the download hierarchy under a content-hashed name. |

`app.env` may also set the daemon command lines (defaults shown):

```
VALIDATOR=sample_trivial_validator --app <app>
ASSIMILATOR=sample_assimilator --app <app>
```

The trivial validator accepts every result, and the sample assimilator copies the output
files to `<project dir>/results/`. Real apps need their own validator, e.g.
`script_validator --app <app> --init_script "<script> files result_id"` with the script in
`server/` (exit 0 = valid, 3 = retry later, anything else = invalid). Changing `VALIDATOR`
or `ASSIMILATOR` and running `install` again replaces the daemon entries in `config.xml`.

App images that need more than `boinc-app-base` (binaries, libraries) are built in CI and
pulled by the clients; the app's `files/Dockerfile` then only contains `FROM` that image plus
`WORKDIR`, `COPY`, `ENV`, `CMD`. The GHCR package must be public.

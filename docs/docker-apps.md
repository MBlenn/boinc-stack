# Docker apps

BOINC 1.6 can ship applications as container images. The volunteer's BOINC client receives
the `docker_wrapper`, a `Dockerfile` and the app files, builds the image locally with
Docker or Podman and runs each job in a container.

The server image of boinc-stack contains:

- `docker_wrapper` for Linux x86_64, statically linked, so it also runs on older distributions
- the apps under `image/apps/`, installed into a project with `boinc-app`
- `boinc-app`, which registers an app (plan class, app version, templates, validator and
  assimilator) and creates jobs

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

### On the volunteer's host (Linux, NVIDIA)

1. **BOINC client 8.2 or newer.** At startup the client looks for Podman first, then
   Docker, and runs `hello-world` **as the user the client runs as** (`boinc` for the
   distribution packages). The event log shows the result, e.g. `Podman version 5.x` or
   `Podman found but 'hello-world' test failed`.
2. **Make the container runtime usable for the client user**:
   - Docker: `sudo usermod -aG docker boinc`
   - Podman (rootless): the user needs subordinate IDs, e.g.
     `sudo usermod --add-subuids 500000-565535 --add-subgids 500000-565535 boinc`
3. **NVIDIA Container Toolkit** (package `nvidia-container-toolkit` from NVIDIA's repository):
   - Docker: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
   - Podman: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
4. **Test as the client user**:
   ```bash
   sudo -u boinc podman run --rm --gpus all docker.io/library/debian:trixie-slim nvidia-smi
   # or: sudo -u boinc docker run --rm --gpus all debian:trixie-slim nvidia-smi
   ```
5. Restart the BOINC client and update the project.

## Adding an app

Copy `image/apps/gpucheck` and adapt it:

| File | Purpose |
|---|---|
| `app.env` | `APP_NAME`, `APP_TITLE`, `APP_VERSION`, `PLAN_CLASS` |
| `plan_class.xml` | `<plan_class>` block, added to the project's `plan_class_spec.xml` |
| `files/Dockerfile` | image built on the host. The slot directory is mounted at `/app`. Debian-based images need `procps`. |
| `files/job.toml` | docker_wrapper options, e.g. `use_gpu = true`, `image_name` |
| `files/*` | further app files (scripts, binaries). `@APP_VERSION@` is substituted. |
| `templates/in.xml`, `templates/out.xml` | input and output templates for `create_work` |

The trivial validator accepts every result, and the sample assimilator copies the output
files to `<project dir>/results/`. Real apps will need their own validator and assimilator.

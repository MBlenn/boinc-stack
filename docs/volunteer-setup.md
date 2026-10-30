# Running Docker apps as a volunteer (Linux)

Projects built with boinc-stack ship their applications as container images. Your BOINC
client builds and starts these containers with **Podman** (recommended) or Docker. This page
describes the one-time setup of a Linux host. Project operators find their side in
[docker-apps.md](docker-apps.md).

Supported so far: **Linux x86_64**, CPU apps and apps for **NVIDIA GPUs**. Windows (WSL) and
AMD GPUs are not supported yet.

## Requirements

- BOINC client **8.2 or newer** (e.g. package `boinc-client`), running as a system service
- Podman (or Docker)
- for GPU apps: an NVIDIA GPU with a current driver (570 or newer recommended) and the NVIDIA
  Container Toolkit
- disk space: each application image is pulled once per host and version; the GNINA docking
  image is about 4.5 GB

All commands below are for Debian/Ubuntu and are run as a user with `sudo`. The BOINC client
runs as the user `boinc`; its home directory is `/var/lib/boinc-client` (with the link
`/var/lib/boinc`), check with `getent passwd boinc`.

Run commands as `boinc` from a directory that user can access, e.g. `cd /tmp` first.
Otherwise you get errors like "cannot chdir to /root: Permission denied".

## 1. Install Podman

```bash
sudo apt install podman
```

This also installs `uidmap`, which rootless Podman needs.

## 2. Make Podman usable for the BOINC user

Rootless Podman needs subordinate user and group IDs for the client user. Then reset Podman's
storage once:

```bash
sudo usermod --add-subuids 500000-565535 --add-subgids 500000-565535 boinc
cd /tmp && sudo -u boinc podman system migrate
```

The client service has no systemd user session. Podman then prints four warnings per command
and falls back to cgroupfs, which works. To avoid the warnings (they also end up in every
task's output), set cgroupfs explicitly:

```bash
sudo -u boinc mkdir -p /var/lib/boinc/.config/containers
printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' \
  | sudo -u boinc tee /var/lib/boinc/.config/containers/containers.conf
```

Docker instead of Podman: `sudo usermod -aG docker boinc`. Note that members of the `docker`
group are effectively root on the host.

## 3. NVIDIA Container Toolkit (GPU apps only)

Install the package `nvidia-container-toolkit` from NVIDIA's apt repository, see the
[installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
Then:

- Podman: create the CDI specification and check it
  ```bash
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  nvidia-ctk cdi list
  ```
  Recent toolkit versions also install `nvidia-cdi-refresh.service`, which regenerates the
  specification after driver updates. Without it, run the `generate` command again after
  each driver update.
- Docker: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`

## 4. Test as the BOINC user

```bash
cd /tmp
sudo -u boinc podman run --rm docker.io/library/debian:trixie-slim echo container ok
# GPU apps:
sudo -u boinc podman run --rm --gpus all docker.io/library/debian:trixie-slim nvidia-smi
```

The second command must show your GPU. (With Docker: replace `podman` by `docker`.)

## 5. Restart the BOINC client

```bash
sudo systemctl restart boinc-client
```

At startup the client looks for Podman, then Docker, and runs a test container as `boinc`.
The event log (BOINC Manager → Tools → Event Log) must show a line like

```
Docker: version 5.7.0 (podman)
```

If that line is missing, Podman/Docker does not work for the client user: repeat steps 2–4.

## 6. Join the project and test step by step

1. Attach to the project with its URL (BOINC Manager → Tools → Add project).
2. Test applications are opt-in. With the default preferences you only get the GPU check
   `gpucheck`: a container that runs `nvidia-smi` for a few seconds. Wait until such a task
   is reported and **valid** (project web site → Your account → Computers → Tasks). Its
   result shows your GPU, driver and memory as seen inside the container.
3. Then enable the real test applications in the project preferences
   (Your account → Preferences → Project):
   - **Run test applications?** → yes
   - **Run only the selected applications**: e.g. only the GPU docking app first, the CPU
     variant later
   - **Use NVIDIA GPU** / **Allow CPU-only tasks** as you like
4. In the BOINC Manager, click "Update" for the project to fetch work right away.

The first task of a new application version downloads its image (several GB for GNINA) and
therefore takes longer; later tasks start within seconds.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No "Docker: version …" line in the event log | Podman/Docker does not work for `boinc`: steps 2–4 |
| Many "cgroupv2 manager is set to systemd" warnings in task output | `containers.conf` missing or in the wrong home directory (step 2) |
| GPU task fails, `nvidia-smi` missing or "no GPU" in the output | NVIDIA Container Toolkit / CDI specification missing or outdated (step 3) |
| GPU tasks stopped working after a driver update | regenerate the CDI specification (step 3) |
| Manual `podman` commands as `boinc` from a root shell fail ("unknown FS magic", runtime directory errors) | they run without the client's environment; not relevant as long as tasks run |
| Disk filling up with old images | images of old application versions stay in Podman's storage. Remove them while no task is running: `cd /tmp && sudo -u boinc podman image prune -a` (they are pulled again when needed) |

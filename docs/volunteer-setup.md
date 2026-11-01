# Running Docker apps as a volunteer (Linux)

Projects built with boinc-stack ship their applications as container images. Your BOINC
client builds and starts these containers with **Podman** (recommended) or Docker. This page
describes the one-time setup of a Linux host. Project operators find their side in
[docker-apps.md](docker-apps.md).

Supported so far: **Linux x86_64**, CPU apps and apps for **NVIDIA GPUs**. Windows (WSL) and
AMD GPUs are not supported yet.

## Requirements

- BOINC client **8.2 or newer**, running as a system service. Distribution packages are
  often older (Ubuntu 24.04 ships 7.20): then use the BOINC repository from
  [BOINC's Linux page](https://boinc.berkeley.edu/linux_install.php). Check with
  `boinccmd --client_version`.
- Podman 4.1 or newer (or Docker), installed in step 1. The Podman 4.9 of Ubuntu 24.04 and
  Linux Mint 22 works for GPU apps from app versions with the current docker_wrapper on
  (e.g. gpucheck 1.7, gnina 1.6); older versions failed with "unknown flag: --gpus"
- for GPU apps: an NVIDIA GPU of the **Pascal generation or newer**, driver **570 or newer**
  (575 or newer recommended) and the NVIDIA Container Toolkit (step 3)
- disk space: about **15 GB** that BOINC may use (BOINC Manager → Options → Computing
  preferences → Disk), on the file system of `/var/lib/boinc`. See
  [Disk space and container images](#disk-space-and-container-images) for what takes the space.

### Which NVIDIA GPUs work

The GPU apps are built for CUDA compute capability 6.0 and newer (`nvidia-smi
--query-gpu=name,compute_cap --format=csv` shows it).

| Generation | Examples | Compute capability | Supported |
|---|---|---|---|
| Blackwell | RTX 50xx | 12.0 | yes |
| Ada Lovelace | RTX 40xx, RTX 4000/6000 Ada, L4, L40 | 8.9 | yes |
| Ampere | RTX 30xx, RTX A2000–A6000, A100 | 8.0 / 8.6 | yes |
| Turing | GTX 16xx, RTX 20xx, Quadro RTX, T4 | 7.5 | yes |
| Volta | Titan V, V100 | 7.0 | yes |
| Pascal | GTX 10xx, Quadro P, Tesla P100 | 6.0 / 6.1 | yes |
| Maxwell and older | GTX 9xx, GTX 750, Quadro M | 5.x and lower | no |

### NVIDIA driver

`nvidia-smi` shows the installed driver ("Driver Version"). If it is older than 570:

- Ubuntu: `sudo ubuntu-drivers list` shows the available driver packages, e.g.
  `sudo apt install nvidia-driver-580`, then reboot.
- Debian and others: the distribution's driver is often older; use NVIDIA's CUDA
  repository (package `cuda-drivers`), see the
  [driver installation guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/).

A BOINC client that already runs CUDA tasks of other projects has a working driver; only
the version matters.

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

The same without quotes (for copying from forums or chat programs that replace quotes with
typographic ones; `\\042` is a double quote):

```bash
printf \[engine\]\\ncgroup_manager=\\042cgroupfs\\042\\nevents_logger=\\042file\\042\\n | sudo -u boinc tee /var/lib/boinc/.config/containers/containers.conf
```

Docker instead of Podman: `sudo usermod -aG docker boinc`. Note that members of the `docker`
group are effectively root on the host.

## 3. NVIDIA Container Toolkit (GPU apps only)

The NVIDIA Container Toolkit passes the GPU into containers. It is not part of the
distributions; add NVIDIA's apt repository and install it (from NVIDIA's
[installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)):

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install nvidia-container-toolkit
```

The repository line without quotes (same result as the second command):

```bash
echo deb \[signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg\] https://nvidia.github.io/libnvidia-container/stable/deb/\$\(ARCH\) / | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
```

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
sudo -u boinc podman run --rm --device nvidia.com/gpu=all docker.io/library/debian:trixie-slim nvidia-smi
```

The second command must show your GPU. With Docker: replace `podman` by `docker` and
`--device nvidia.com/gpu=all` by `--gpus all`.

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
   (Your account → Preferences → Project → Edit preferences):
   - **Run test applications?** → yes
   - **Run only the selected applications**: e.g. only the GPU docking app first, the CPU
     variant later
   - **Use NVIDIA GPU** / **Allow CPU-only tasks** as you like
   - click **Update preferences** at the bottom of the page; leaving the page without it
     discards the changes
4. Check the **venue** (location): preferences can be stored separately for "home",
   "school" and "work". A computer uses the preferences of its venue if they exist,
   otherwise the default ones (Your account → Computers → Details → Location). Edit the
   preferences of the venue your computer is in, or set the computer's location to
   "---" (default).
5. In the BOINC Manager, click "Update" for the project to fetch work right away.

The first task of a new application version downloads its image (several GB for GNINA) and
therefore takes longer; later tasks start within seconds.

## Disk space and container images

Each application brings its programs as a **container image**: a packed, read-only
directory tree with everything the program needs (libraries, CUDA runtime, the program
itself). Podman keeps images in the BOINC user's home directory
(`/var/lib/boinc/.local/share/containers`).

An image consists of **layers**, stacked on top of each other like transparent sheets:
e.g. a Debian base layer (about 100 MB), a CUDA layer (about 3 GB) and a small layer with
the docking program. Layers are stored only once per host, even if several images use
them. An application version is built on the host from a **base image** that the project
publishes in **revisions** (e.g. `boinc-app-gnina:1.3.3-1`, `1.3.3-2`), plus a few small
files (layers of a few KB).

Example, GNINA docking on one host:

| `podman images` shows | Size shown | Really new on disk |
|---|---|---|
| `ghcr.io/mblenn/boinc-app-gnina 1.3.3-2` (base image) | 4.5 GB | 4.5 GB |
| `localhost/boinc-stack-gnina-1.5` (GPU app 1.5, built from it) | 4.5 GB | a few KB |
| `localhost/boinc-stack-gnina_cpu-1.5` (CPU app 1.5, same base) | 4.5 GB | a few KB |
| `localhost/boinc-stack-gnina-1.4` (previous app version, same base) | 4.5 GB | a few KB |

`podman images` lists 18 GB, the disk holds about 4.5 GB: each line shows the full size of
its image, including the shared layers. Only a **new revision of the base image** costs
real space (another few GB), because its layers differ. `podman system df` shows the real
usage.

You do not need to clean up. When a new application version arrives, the application's
container wrapper removes the images of older versions of that application and old
revisions of its base image, as soon as no task uses them any more. In the example above,
`boinc-stack-gnina-1.4` disappears with the first task of version 1.5.

Only if the disk is full and BOINC is stopped or has no tasks running, remove all unused
images at once (they are downloaded again when needed):

```bash
cd /tmp && sudo -u boinc podman image prune -a
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No "Docker: version …" line in the event log | Podman/Docker does not work for `boinc`: steps 2–4 |
| Many "cgroupv2 manager is set to systemd" warnings in task output | `containers.conf` missing or in the wrong home directory (step 2) |
| GPU task fails after a few seconds with "unknown flag: --gpus" in the task's output | Podman older than 5 with an app version built before the fix: wait for the next app version, or run CPU apps only |
| GPU task fails, `nvidia-smi` missing or "no GPU" in the output | NVIDIA Container Toolkit / CDI specification missing or outdated (step 3) |
| GPU tasks stopped working after a driver update | regenerate the CDI specification (step 3) |
| Manual `podman` commands as `boinc` from a root shell fail ("unknown FS magic", runtime directory errors) | they run without the client's environment; not relevant as long as tasks run |
| No tasks although test applications are enabled | preferences not saved ("Update preferences"), or saved for another venue than the computer's (step 6) |
| Disk filling up with old images | normally removed automatically with the next application version; see [Disk space and container images](#disk-space-and-container-images) |

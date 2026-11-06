#!/bin/sh
# gpucheck: write what the container can see of the GPU to the output file "out"
# and to stderr, so volunteers see it on the task's page ("Stderr output") as well.
# Always exits 0, so "no GPU visible" is reported as a result instead of an error.
{
    echo "gpucheck @APP_VERSION@"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel: $(uname -r)"
    # GPU assigned by the BOINC client (set by the docker_wrapper; CUDA device number).
    # nvidia-smi below ignores it and lists all GPUs of the host.
    echo "assigned GPU (CUDA_VISIBLE_DEVICES): ${CUDA_VISIBLE_DEVICES:-not set}, PCI ${BOINC_GPU_PCI_BUS_ID:-unknown}"
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "nvidia-smi: available"
        echo "GPUs (index, name, PCI bus ID, driver, memory, compute capability):"
        nvidia-smi --query-gpu=index,name,pci.bus_id,driver_version,memory.total,compute_cap \
            --format=csv,noheader 2>&1 | while IFS= read -r line; do
            case "$line" in
                *"${BOINC_GPU_PCI_BUS_ID:-no-pci-id}"*) echo "  $line   <- assigned to this task" ;;
                *) echo "  $line" ;;
            esac
        done
        echo
        nvidia-smi 2>&1
    else
        echo "nvidia-smi: not available (no GPU passed into the container)"
    fi
    if ls /dev/nvidia* >/dev/null 2>&1; then
        echo "devices: $(ls /dev/nvidia* | tr '\n' ' ')"
    else
        echo "devices: none"
    fi
} 2>&1 | tee out >&2
exit 0

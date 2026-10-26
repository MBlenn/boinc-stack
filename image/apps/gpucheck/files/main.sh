#!/bin/sh
# gpucheck: write what the container can see of the GPU to the output file "out".
# Always exits 0, so "no GPU visible" is reported as a result instead of an error.
{
    echo "gpucheck @APP_VERSION@"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel: $(uname -r)"
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "nvidia-smi: available"
        nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap \
            --format=csv,noheader 2>&1 || echo "nvidia-smi: query failed"
    else
        echo "nvidia-smi: not available (no GPU passed into the container)"
    fi
    if ls /dev/nvidia* >/dev/null 2>&1; then
        echo "devices: $(ls /dev/nvidia* | tr '\n' ' ')"
    else
        echo "devices: none"
    fi
} > out 2>&1
exit 0

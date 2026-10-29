# Patches for the BOINC sources

Applied in order with `git apply` after cloning `BOINC_REF` (see `image/Containerfile`).
If a patch no longer applies after changing `BOINC_REF`, the build fails: check whether
the fix is included upstream and remove the patch, or rebase it.

| Patch | Problem | Upstream |
|---|---|---|
| `0001-script_validator-strip-delimiter.patch` | `script_validator --init_script "script files result_id"` calls the script without arguments, because `split()` keeps the trailing space in each part | not yet reported |

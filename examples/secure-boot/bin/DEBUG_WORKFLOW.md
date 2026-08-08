# Interactive Debug Workflow for Custom Images

This workflow allows you to iterate on custom image customization scripts (like `harden-kernel-and-os.sh`) interactively on a live GCE VM, protected by `screen` against SSH drops.

---

## 🛠️ The Toolkit

Located in `examples/secure-boot/bin/`:

*   **[`customize-in-screen.sh`](file:///usr/local/google/home/cjac/src/github/c9h/dataproc-evolution/custom-images/examples/secure-boot/bin/customize-in-screen.sh):** The main workstation-side orchestrator.
*   **[`create-debug-vm.sh`](file:///usr/local/google/home/cjac/src/github/c9h/dataproc-evolution/custom-images/examples/secure-boot/bin/create-debug-vm.sh):** Helper to provision the high-spec (`n1-standard-32`) builder VM.
*   **[`install-in-screen.sh`](file:///usr/local/google/home/cjac/src/github/c9h/dataproc-evolution/custom-images/examples/secure-boot/install-in-screen.sh):** The guest-side wrapper that spawns the script in `screen`.

---

## 🚀 How to Use It

### 1. Configure Target
Ensure your `env.json` points to the customization script you want to test (e.g., `examples/secure-boot/harden-kernel-and-os.sh`).

### 2. Launch or Attach
Run the orchestrator from your workstation:

```bash
bash examples/secure-boot/bin/customize-in-screen.sh
```

**What it does:**
1.  **Cold Start:** If the debug VM doesn't exist, it creates one (`n1-standard-32` for fast compilation).
2.  **Sync:** Fast bulk uploads local scripts to GCS.
3.  **Launch:** Triggers the script inside a `screen` session named **`customization`** on the VM.
4.  **Attach:** Connects your terminal directly to the live/running script output on the VM.

### 3. Detach or Reconnect
*   **To Detach (leave running in background):** Press `Ctrl + A` followed by `D`.
*   **If SSH drops:** Just re-run the script. It detects the active session and re-attaches instantly without interrupting the build.

---

## 🔄 Iteration & Debugging Loop

1.  If the build fails, **hot-fix** the script directly on the VM for instant testing:
    ```bash
    ssh <debug-instance-name>
    ```
2.  Or, fix it on your workstation and re-run `customize-in-screen.sh`. It will sync the new version and reboot the customization process.
3.  **Clean Builds:** Pass `-c` to clear sentinels and artifcats before running:
    ```bash
    bash examples/secure-boot/bin/customize-in-screen.sh -c
    ```

---

## 🧹 Cleanup

Once verified, stop or delete the debug VM manually via `gcloud` or use the `-r` flag to force recreation on the next run.

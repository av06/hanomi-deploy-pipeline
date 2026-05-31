# Hanomi multi-service deploy pipeline

This repository contains a partial implementation of a deployment pipeline for the hypothetical **Hanomi** stack. It focuses on release orchestration, deployment mechanics, rollback behavior, health checks, and secret boundaries rather than on the application code itself.

The stack is intentionally treated as VM-based infrastructure, not Kubernetes:

| Service | Runtime | Target |
|---|---|---|
| backend | Go service on Linux | Backend VM |
| frontend | Next.js service on Linux | Frontend VM |
| worker | Python script on Windows Server | Worker VM |

The parent repository owns the release orchestration. The application code lives in three git submodules:

```text
hanomi-deploy-pipeline/
├── backend/      # git submodule: Go service
├── frontend/     # git submodule: Next.js app
├── worker/       # git submodule: Python worker
├── .github/workflows/deploy.yml
├── scripts/remote/deploy-linux.sh
├── scripts/remote/rollback-linux.sh
├── scripts/remote/deploy-windows.ps1
├── scripts/remote/rollback-windows.ps1
└── config/
```

> Note: the submodule directories are represented as placeholders in this submission. The CI config is written as if real service submodules exist at these paths. In a real repo, these would be added with `git submodule add <repo-url> backend`, `frontend`, and `worker`.

The GitHub Actions workflow includes a preflight check. In this public assignment repository, it exits successfully after noting that the service directories are placeholders. Once real submodules are attached, the same workflow proceeds through build, package, deploy, health check, and rollback behavior.

Expected service entrypoints:

- `backend/go.mod`, `backend/go.sum`, and `backend/cmd/backend`
- `frontend/package-lock.json` and a Next.js build configured with `output: 'standalone'`
- `worker/requirements.txt` if dependencies are needed, plus the worker source and tests

---

## Architecture

The deployment is triggered on every merge to `main` in the parent repository.

```text
merge to parent main
        |
        v
GitHub Actions checks out parent repo + submodules
        |
        v
Build artifacts
  - backend Go binary tarball
  - frontend Next.js standalone tarball
  - worker Python zip
        |
        v
Deploy sequentially
  1. backend Linux VM
  2. frontend Linux VM
  3. worker Windows VM
        |
        v
Health check after each service
        |
        v
Success, or rollback failed service and fail pipeline
```

The pipeline is intentionally **sequential**. This makes failure handling easier to reason about and avoids deploying downstream services if an upstream service is unhealthy. Parallel deployment would be faster, but it makes mid-rollout failure handling more complex.

---

## Tool choices

### GitHub Actions

GitHub Actions is used because the assignment asks for a CI config and the trigger is naturally tied to merges into the parent GitHub repository. The workflow uses:

- `actions/checkout` with recursive submodules
- language-specific setup actions for Go, Node.js, and Python
- GitHub Actions secrets for SSH credentials and VM connection details
- GitHub Actions environment protection for production deploys

### SSH/SCP for Linux VMs

The backend and frontend deploy through SSH/SCP. Each service gets copied to a release directory under:

```text
/opt/hanomi/<service>/releases/<release-id>
```

The active release is selected using a `current` symlink:

```text
/opt/hanomi/<service>/current -> /opt/hanomi/<service>/releases/<release-id>
```

The systemd service always starts from `current`, so rollback only requires switching the symlink back and restarting the service.

### OpenSSH/PowerShell for Windows VM

The worker deploys to the Windows server over OpenSSH and runs a PowerShell deployment script remotely. The same release-directory pattern is used:

```text
C:\hanomi\worker\releases\<release-id>
C:\hanomi\worker\current
```

The worker is assumed to run as either a Windows Service or a Scheduled Task. The sample implementation uses a Scheduled Task named `HanomiWorker` because it is simple and works without external tools. The target Windows VM is responsible for having Python and any runtime dependencies available, or the worker artifact would need to include a virtual environment/build step in a production version.

---

## Rollback strategy

Each service keeps multiple releases on its own VM.

For Linux services:

1. Upload artifact to `/tmp/hanomi/<service>/<release-id>`.
2. Extract artifact into `/opt/hanomi/<service>/releases/<release-id>`.
3. Save the old `current` target as `previous`.
4. Atomically switch `current` to the new release using `ln -sfn`.
5. Restart the systemd unit.
6. Run health checks.
7. If health checks fail, switch `current` back to `previous` and restart.

For Windows worker:

1. Upload worker zip to `C:\hanomi\worker\incoming`.
2. Expand it into `C:\hanomi\worker\releases\<release-id>`.
3. Save the current release path into `previous.txt`.
4. Recreate the `current` junction.
5. Restart the Scheduled Task.
6. Run the worker health check.
7. If health checks fail, recreate the junction to the previous release and restart the task.

This is a **per-service rollback**, not a full distributed rollback.

---

## What happens if one service fails mid-rollout?

The workflow deploys in this order:

```text
backend -> frontend -> worker
```

If the backend deployment fails, the backend rolls back and the frontend/worker are not deployed.

If the frontend deployment fails, the frontend rolls back and the worker is not deployed. The backend remains on the new version if it passed health checks.

If the worker deployment fails, the worker rolls back. Backend and frontend remain on the new version if they passed health checks.

This is intentional. Automatically rolling back already-healthy services can create more risk unless all services are tightly version-coupled. In a production version, I would add a release manifest with compatibility metadata, for example:

```json
{
  "release": "2026-05-31-abcdef",
  "backend": "sha1",
  "frontend": "sha2",
  "worker": "sha3",
  "requires": {
    "backend_api": ">=2026.05"
  }
}
```

If the services are known to be strongly coupled, the pipeline can be changed to rollback all already-deployed services in reverse order.

---

## Health checks

The implementation supports basic HTTP health checks:

| Service | Example health check |
|---|---|
| backend | `http://backend-vm:8080/health` |
| frontend | `http://frontend-vm:3000/api/health` |
| worker | `http://worker-vm:9000/health` |

The health check retries multiple times before failing. This handles slow process startup without hiding real failures.

For the Python worker, if no HTTP server exists, I would replace the health check with one of:

- Scheduled Task status check
- Windows Service status check
- heartbeat file timestamp check
- queue lag / last processed timestamp check

---

## Secrets handling

No secrets are committed to this repository.

GitHub Actions secrets/environment secrets should store:

```text
SSH_PRIVATE_KEY
LINUX_SSH_USER
BACKEND_HOST
FRONTEND_HOST
WINDOWS_HOST
WINDOWS_SSH_USER
WINDOWS_SSH_PRIVATE_KEY
```

Application secrets should live on the target VMs, not inside build artifacts. For example:

```text
/etc/hanomi/backend.env
/etc/hanomi/frontend.env
C:\hanomi\worker\worker.env
```

The systemd unit files load Linux env files with `EnvironmentFile`. The Windows worker can load env from a protected file or from Windows Credential Manager in a real deployment.

This keeps CI responsible for shipping versioned artifacts, not for distributing runtime credentials.

---

## Tradeoffs

### Why not Docker?

Docker would make artifact consistency stronger and simplify process startup. However, the assignment only says separate VMs and does not require container runtime availability. This implementation works with plain Linux and Windows servers.

### Why require Next.js standalone output?

The frontend systemd unit runs `server.js` from the deployed release. Requiring `output: 'standalone'` keeps the artifact self-contained and avoids depending on `npm install` or source checkout state on the VM.

### Why not Kubernetes?

The requirement explicitly says to treat the targets as three separate VMs, not Kubernetes.

### Why sequential deployment?

Sequential deployment is slower but easier to reason about. It prevents cascading failures and gives a clean answer for mid-rollout failure.

### Why per-service rollback?

Per-service rollback avoids unnecessarily reverting healthy services. Full rollback is only safer if there is a strict compatibility requirement across all services.

### Why release directories and symlinks/junctions?

They provide simple atomic switching, quick rollback, and easy inspection of deployed versions without needing a heavyweight deployment agent.

---

## How to use this repository

1. Add real submodules:

```bash
git submodule add git@github.com:<org>/hanomi-backend.git backend
git submodule add git@github.com:<org>/hanomi-frontend.git frontend
git submodule add git@github.com:<org>/hanomi-worker.git worker
git submodule update --init --recursive
```

2. Configure GitHub Actions secrets/environment secrets.

3. Ensure the Linux VMs have:

```bash
sudo mkdir -p /opt/hanomi/backend /opt/hanomi/frontend /etc/hanomi
sudo systemctl daemon-reload
```

4. Install the systemd unit files from `config/systemd/`.

5. Ensure the Windows VM has OpenSSH enabled and a `HanomiWorker` Scheduled Task or Windows Service configured.

6. Merge to `main` in the parent repository.

---

## Local validation

The shell scripts can be syntax-checked with:

```bash
bash -n scripts/remote/deploy-linux.sh
bash -n scripts/remote/rollback-linux.sh
```

PowerShell syntax can be checked from macOS/Linux with:

```powershell
pwsh -NoProfile -Command '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile("scripts/remote/deploy-windows.ps1",[ref]$t,[ref]$e)|Out-Null;if($e){$e;exit 1}'
pwsh -NoProfile -Command '$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile("scripts/remote/rollback-windows.ps1",[ref]$t,[ref]$e)|Out-Null;if($e){$e;exit 1}'
```

The deploy script itself should be executed on Windows because it intentionally uses `C:\hanomi\...` paths and Windows junctions.

---

## AI usage

I used ChatGPT/Codex to help brainstorm the deployment architecture, rollback tradeoffs, health-check approach, README structure, and initial CI/script scaffolding. I reviewed and shaped the final design decisions manually.

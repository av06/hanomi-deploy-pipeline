# Live discussion notes

## 20-second summary

I designed a GitHub Actions based pipeline that builds three service artifacts from submodules and deploys them sequentially to three separate VMs. Linux services use systemd and release-directory symlink switching. The Windows worker uses PowerShell, release directories, and a Scheduled Task. Each service is health-checked after deployment. If a service fails, only that service is rolled back and the pipeline stops.

## Why this design

- The assignment says VMs, not Kubernetes, so I avoided K8s-native assumptions.
- The parent repo owns orchestration because the trigger is a merge to parent `main`.
- Sequential rollout gives clear failure boundaries.
- Release directories make rollback simple and fast.
- Secrets stay in GitHub Actions secrets or VM-local env files, never in artifacts.

## Failure example

If backend succeeds and frontend fails:

1. Backend remains on the new version because it passed health checks.
2. Frontend rolls back to its previous release.
3. Worker is not deployed.
4. Pipeline fails and requires investigation.

I chose this over automatic global rollback because global rollback can be riskier if the already deployed service is healthy. If the services were tightly coupled, I would use a release manifest and rollback in reverse order.

## Improvements for production

- Add deployment approvals using GitHub environments.
- Add smoke tests that check service-to-service compatibility.
- Add release manifest and compatibility rules.
- Add notifications to Slack/PagerDuty.
- Add artifact signing/checksums.
- Store app secrets in a proper secret manager instead of VM files.
- Add blue/green or canary deployment behind a load balancer.

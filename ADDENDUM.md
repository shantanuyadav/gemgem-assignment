# Stress Test Scenarios

Walked through some worst-case scenarios to sanity-check the infra. Covering what breaks, why users stay online, and how recovery works.

## 1) Spot Failure Mid-Deploy

60% of Spot instances get interrupted while a rolling deploy is in progress.

The ECS agent (ECS_ENABLE_SPOT_INSTANCE_DRAINING=true) catches the 2-min notice and immediately drains all tasks on those instances — both old and new revision. ALB stops routing new requests to them, in-flight connections get 120s to wrap up.

Tasks on the 2 On-Demand baseline instances are unaffected. They keep serving the whole time. ECS sees the count is low, tries to place replacements. If there's no room, capacity provider bumps the ASG — it'll try other Spot pools first, falls back to On-Demand if Spot is gone. New instances register within 3–5 min.

If too many new-revision tasks failed health checks during all this, the circuit breaker rolls back. Old tasks were never drained (minimum_healthy_percent = 100) so users didn't notice.

## 2) Secrets Permission Gets Revoked

Someone removes `ssm:GetParameters` from the Task Execution Role.

Running tasks are fine — secrets were injected as env vars at startup, they're in memory. The problem is new task launches. The agent can't fetch secrets, so every new task fails with `ResourceInitializationError`. Deploys stall, scaling events fail, and the circuit breaker can't even roll back because rollback tasks hit the same issue.

The service degrades slowly as existing tasks die for unrelated reasons and can't be replaced.

**Catch it via:** STOPPED task events with ResourceInitializationError, CloudTrail showing AccessDenied on ssm:GetParameters, alarm on running < desired.

**Fix:** restore the permission, then `aws ecs update-service --force-new-deployment`. No secret rotation needed — nothing was leaked, it was just a permissions issue.

## 3) Pending Task Deadlock

Desired count is 10, cluster fits 6. Four tasks sit PENDING.

CapacityProviderReservation goes above target → managed scaling bumps the ASG → new instances boot and register (~3–5 min) → scheduler places the pending tasks.

This can't actually deadlock because the metric is driven by desired-vs-available, not running count. As long as managed_scaling is on and asg_max_size has room, it scales. The only way you get stuck is if max_size is too low.

## 4) Deploy Lifecycle

Quick walkthrough of the rolling update:

- New tasks start immediately (up to 200% of desired). Old ones keep running.
- A new task has to pass 2 ALB health checks (~30s) before it gets traffic.
- Once it's healthy, ECS drains one old task. ALB gives in-flight requests 120s, then SIGTERM → 120s graceful shutdown → SIGKILL.
- Repeat until done.
- If new tasks keep failing: circuit breaker halts everything, rolls back. Old tasks were never removed, so no user impact. EventBridge fires an alert.

## 5) TLS and Identity

TLS terminates at the ALB (TLS 1.3 policy). ALB → ECS traffic is HTTP over the private network. Standard practice — re-encrypting internally adds latency for minimal gain. Can add end-to-end TLS in nginx if compliance requires it.

Container runs as the Task Role (ecs_task). Only has access to CloudWatch Logs. No SSM, no S3, nothing else. IMDSv2 enforced (http_tokens = required) to block SSRF credential theft. hop_limit = 2 so containers can still reach IMDS.

## 6) Cost Floor (Zero Traffic for 12 Hours)

What you're still paying for: 2 On-Demand t3.medium instances (~$1.00), NAT Gateway (~$0.54), ALB (~$0.27), plus CloudWatch Logs. ECS tasks run on the EC2 instances so no extra charge there. Roughly **~$1.80 per 12 hours** idle.

To bring it down: drop On-Demand base to 1 in non-prod, use smaller instances, swap NAT GW for a NAT instance in low-traffic envs, schedule min_count down overnight, Savings Plans for the baseline.

## 7) Three Failure Modes

**OOM Kill** — single task, code 137. ALB deregisters it, traffic shifts, ECS restarts it. Fix: bump task_memory or investigate leaks.

**Stale AMI** — ASG can't launch new instances (InvalidAMI or agent mismatch). Existing tasks fine but can't scale or replace Spot. Fix: pin AMI with a refresh pipeline, alert on launch failures.

**AZ Outage** — lose ~33–50% of tasks. Service degrades but stays up. spread placement ensures the other AZs have tasks. Auto scaling compensates, capacity provider launches instances in healthy AZs. Fully automated recovery.

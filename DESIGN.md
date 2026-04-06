# Design Notes — ECS on EC2

## A) Zero-Downtime Deploys

The setup is straightforward: `deployment_maximum_percent = 200` lets ECS run new tasks alongside old ones, and `deployment_minimum_healthy_percent = 100` means it won't kill any old task until replacements are healthy. So new tasks come up, pass ALB health checks, and only then do old tasks start draining.

Health check settings:

| Setting | Value | Notes |
|---|---|---|
| Check interval | 15s | |
| Healthy threshold | 2 | ~30s before a new target gets traffic |
| Unhealthy threshold | 3 | avoids killing on transient blips |
| Deregistration delay | 120s | drain window for in-flight requests |
| Slow start | 30s | ramp traffic so cold processes don't get slammed |
| Grace period | 60s | ignore health check fails while the container boots |

The circuit breaker (rollback = true) auto-reverts to the last working task def if new tasks keep failing. Since minimum_healthy_percent = 100, old tasks never got drained during a failed deploy, so users don't notice.

**Deploy flow:** new task starts → passes 2 health checks (~30s) → slow start ramps traffic → ECS drains one old task → ALB gives 120s for in-flight requests → SIGTERM → 120s graceful shutdown → SIGKILL. Repeat in batches until done.

## B) Secrets

Secrets live in SSM Parameter Store, provisioned outside Terraform. The task definition only has ARNs, not values. At launch time the ECS agent assumes the Task Execution Role, calls `ssm:GetParameters`, and injects them as env vars before the entrypoint runs. After that they only exist in process memory — not on disk, not in logs, not in TF state.

Even if state is compromised you just get ARNs, which are basically guessable anyway. Not credentials.

**Role separation:** the Execution Role reads SSM at launch. The Task Role (what the container actually runs as) has zero SSM access — the app already has its secrets in env vars, it shouldn't be able to go browse the parameter store. Limits blast radius if the container gets compromised.

## C) Spot Strategy

2 On-Demand instances as a baseline floor (`on_demand_base_capacity = 2`). Everything above that is Spot (`on_demand_percentage_above_base = 0%`). The `price-capacity-optimized` strategy picks pools with best availability and lowest price.

When a Spot instance gets interrupted: ECS agent catches the 2-min notice, drains all tasks on it, ALB stops sending new requests (in-flight get 120s). ECS places replacements on surviving instances, or the capacity provider scales the ASG if there's no room. Falls back to On-Demand if Spot pools are empty.

Why users stay online: the On-Demand base can't be reclaimed, tasks are spread across AZs, and multiple instance types (t3.medium, t3a.medium, t3.large) diversify across Spot pools so one pool dying doesn't take everything down.

## D) Scaling

Two layers:

**Task count** — target-tracks CPU at 60%. Scale-out cooldown 60s, scale-in 300s to avoid flapping.

**EC2 instances** — when tasks go PENDING (no room on existing instances), the capacity provider's CapacityProviderReservation metric spikes and managed scaling bumps the ASG. `target_capacity = 100` means use existing capacity before adding more. `instance_warmup_period = 300` prevents over-scaling while instances boot.

No deadlock possible because the feedback loop is: PENDING tasks → metric rises → ASG scales → instances register → tasks placed. Only breaks if `asg_max_size` is too low.

## E) Monitoring

What I'd page on:

| Signal | Threshold | 3AM page? |
|---|---|---|
| ALB 5xx rate | >1% over 5 min | yes |
| Running tasks < desired | sustained >10 min | yes |
| Circuit breaker fired | any | yes |
| Spot interruptions | >2 in 5 min | no (notify) |
| Unhealthy targets >0 | sustained >5 min | yes |

Non-paging stuff for Slack: OOM kills, ASG launch failures, SSM GetParameters errors, task STOPPED reason patterns, p99 latency > 2s.

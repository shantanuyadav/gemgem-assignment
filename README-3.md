# ECS on EC2 — Production Terraform

## How to Run

### What you need

- Terraform >= 1.5
- AWS CLI with creds that have enough permissions
- A VPC that already has:
  - 2+ private subnets with NAT Gateway egress, in different AZs
  - 2+ public subnets, also different AZs
  - SG for the ALB (inbound 80/443)
  - SG for ECS instances (inbound from the ALB SG on ephemeral ports 32768–65535)
- SSM parameters already created at the paths you reference in `ssm_parameter_arns`
- ACM certificate if you want HTTPS (optional — without it the ALB just runs HTTP)

### Deploy

```bash
cd terraform/

# make a tfvars for your env — don't commit this
cat > prod.tfvars <<EOF
vpc_id                         = "vpc-0abc123def456"
private_subnet_ids             = ["subnet-aaa", "subnet-bbb"]
public_subnet_ids              = ["subnet-ccc", "subnet-ddd"]
alb_security_group_id          = "sg-alb123"
ecs_instance_security_group_id = "sg-ecs456"
alb_certificate_arn            = "arn:aws:acm:us-east-1:123456789:certificate/abc-123"

ssm_parameter_arns = {
  "app_secret_key" = "arn:aws:ssm:us-east-1:123456789:parameter/production/app/secret_key"
  "db_password"    = "arn:aws:ssm:us-east-1:123456789:parameter/production/app/db_password"
}
EOF

terraform init
terraform plan -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars
```

### Tearing it down

Deletion protection is on by default so you have to disable it first:

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn <alb-arn> \
  --attributes Key=deletion_protection.enabled,Value=false

terraform destroy -var-file=prod.tfvars
```

## Assumptions

Some things this expects to exist already:

| What | Why it's not in this repo |
|---|---|
| VPC, subnets, security groups | Network stuff is usually a separate stack. Didn't want to couple them. |
| Private subnets have NAT | ECS instances need outbound to pull images, register with ECS, talk to SSM. |
| SSM params pre-provisioned | Keeps secret values out of Terraform state entirely. They're managed separately (secrets pipeline, console, etc). |
| ACM cert pre-provisioned | Cert issuance is its own lifecycle. If you don't pass an ARN the ALB falls back to HTTP, which is fine for dev. |
| No real app code | Using `nginx:latest` as a stand-in. The infra doesn't care what the app is. |
| Bridge network mode | Standard pattern for ECS on EC2 — dynamic port mapping so you can run multiple tasks per instance. |

## Time Spent

~2.5 hours:
- Terraform code: ~90 min
- ADDENDUM (stress tests): ~45 min
- DESIGN + this README: ~30 min
- Review pass: ~15 min

## Shortcuts

1. No remote backend — should be S3 + DynamoDB in prod, left commented out to keep things self-contained.
2. VPC/subnets are just variables, not created here. See assumptions above.
3. ALB access logs are off. You'd need an S3 bucket with the right policy. TODO.
4. No WAF — prod should have it (rate limiting, managed rules, etc).
5. No ECR repo, just public nginx. Real setup would have private ECR with scanning enabled.
6. Single target group — blue/green with CodeDeploy needs two. Rolling update is simpler and still does zero-downtime, so went with that.
7. Alerting rules described in DESIGN.md but not wired up in Terraform.

## Tools

- **Claude** — used for drafting and iterating on the Terraform, DESIGN.md, and ADDENDUM.md. I reviewed and validated everything against AWS docs. I understand every resource and config choice in here.
- AWS docs — mainly for capacity provider mechanics, ALB health check timing, Spot interruption flow.
- Terraform Registry docs for `aws_ecs_service`, `aws_autoscaling_group`, `aws_ecs_capacity_provider`.

## What I'd add with more time

1. EventBridge + SNS for the alerts from DESIGN.md (circuit breaker events, task count, 5xx spikes)
2. Blue/green via CodeDeploy — two TGs, canary traffic shifting, alarm-triggered rollback
3. ECR repo with image scanning + lifecycle policies
4. WAF on the ALB
5. VPC endpoints for ECR/SSM/CloudWatch Logs — skip the NAT Gateway for AWS API traffic, saves money
6. tflint or Terratest in CI
7. Split into reusable modules (ALB, cluster, service) so other teams can use them
8. CloudWatch dashboard — task count, CPU, memory, latency, 5xx, Spot interruptions

## Repo structure

```
.
├── README.md
├── DESIGN.md
├── ADDENDUM.md
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── versions.tf
```

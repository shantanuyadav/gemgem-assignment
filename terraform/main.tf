# --- Data Sources ---

# grab latest ECS-optimized AMI when one isn't pinned
data "aws_ssm_parameter" "ecs_ami" {
  count = var.ecs_ami_id == "" ? 1 : 0
  name  = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

locals {
  ecs_ami_id  = var.ecs_ami_id != "" ? var.ecs_ami_id : data.aws_ssm_parameter.ecs_ami[0].value
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

#
# IAM — EC2 instance role (for the ECS agent)
#

resource "aws_iam_role" "ecs_instance" {
  name = "${local.name_prefix}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# SSM access so we can use Session Manager instead of SSH
resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${local.name_prefix}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

#
# IAM — Task Execution Role
# (pulls images + fetches secrets, NOT the app role)
#

resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_base" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# only the SSM params this service actually needs
resource "aws_iam_role_policy" "task_execution_ssm" {
  name = "${local.name_prefix}-task-execution-ssm"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = values(var.ssm_parameter_arns)
    }]
  })
}

#
# IAM — Task Role (what the container itself assumes at runtime)
#

resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# just cloudwatch for now — add more as needed
resource "aws_iam_role_policy" "task_app_permissions" {
  name = "${local.name_prefix}-task-app-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.ecs_service.arn}:*"
    }]
  })
}

# --- Logging ---

resource "aws_cloudwatch_log_group" "ecs_service" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30
}

# --- ECS Cluster ---

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# --- Launch Template ---

resource "aws_launch_template" "ecs" {
  name_prefix   = "${local.name_prefix}-"
  image_id      = local.ecs_ami_id
  instance_type = var.instance_types[0] # overridden by mixed instances policy anyway

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  # no public IP - these go in private subnets
  network_interfaces {
    associate_public_ip_address = false
    security_groups = [var.ecs_instance_security_group_id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true" >> /etc/ecs/ecs.config
    echo "ECS_CONTAINER_STOP_TIMEOUT=120s" >> /etc/ecs/ecs.config
    echo "ECS_ENGINE_TASK_CLEANUP_WAIT_DURATION=1h" >> /etc/ecs/ecs.config
  EOF
  )

  # IMDSv2 — hop limit 2 so containers can still hit the metadata endpoint
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-ecs-instance"
    }
  }

  key_name = var.instance_key_name != "" ? var.instance_key_name : null

  lifecycle {
    create_before_destroy = true
  }
}

# --- ASG (on-demand base + spot overflow) ---

resource "aws_autoscaling_group" "ecs" {
  name_prefix         = "${local.name_prefix}-"
  vpc_zone_identifier = var.private_subnet_ids
  min_size = var.asg_min_size
  max_size = var.asg_max_size
  # don't set desired_capacity — capacity provider manages it

  protect_from_scale_in = true

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.ecs.id
        version            = "$Latest"
      }

      # more instance types = bigger spot pool = fewer interruptions
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }

    instances_distribution {
      on_demand_base_capacity                  = var.asg_on_demand_base
      on_demand_percentage_above_base_capacity = var.asg_on_demand_percentage_above_base
      spot_allocation_strategy                 = "price-capacity-optimized"
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# --- Capacity Provider ---

resource "aws_ecs_capacity_provider" "main" {
  name = "${local.name_prefix}-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = var.capacity_provider_target_capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 5
      instance_warmup_period    = 300
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 0
  }
}

# --- ALB ---

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = true
  drop_invalid_header_fields = true

  # TODO: wire up access logs to the logging bucket
  access_logs {
    bucket  = ""
    enabled = false
  }
}

resource "aws_lb_target_group" "main" {
  name        = "${local.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"
  deregistration_delay = var.deregistration_delay

  health_check {
    path     = var.health_check_path
    protocol = "HTTP"
    port     = "traffic-port"
    interval            = var.health_check_interval
    timeout             = 5
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    matcher             = "200"
  }

  # let new tasks warm up before getting real traffic
  slow_start = 30

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS
resource "aws_lb_listener" "https" {
  count = var.alb_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# HTTP — redirects to HTTPS when we have a cert, otherwise just forwards (dev/test)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = var.alb_certificate_arn != "" ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = var.alb_certificate_arn != "" ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    target_group_arn = var.alb_certificate_arn == "" ? aws_lb_target_group.main.arn : null
  }
}

# --- Task Definition ---

resource "aws_ecs_task_definition" "main" {
  family             = local.name_prefix
  network_mode       = "bridge" # bridge for dynamic port mapping on ec2
  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn
  cpu    = var.task_cpu
  memory = var.task_memory

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "nginx:latest" # FIXME: swap for real image once ECR is set up
      cpu       = var.task_cpu
      memory    = var.task_memory
      essential = true

      portMappings = [{
        containerPort = var.container_port
        hostPort      = 0 # dynamic port mapping
        protocol      = "tcp"
      }]

      # secrets come from SSM — values never end up in tf state
      secrets = [
        for name, arn in var.ssm_parameter_arns : {
          name      = upper(name)
          valueFrom = arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_service.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }

      stopTimeout = 120

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/ || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])
}

# --- ECS Service ---

resource "aws_ecs_service" "main" {
  name            = "${local.name_prefix}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.service_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight = 1
    base   = 0
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  deployment_configuration {
    deployment_maximum_percent         = 200
    deployment_minimum_healthy_percent = 100
  }

  # auto-rollback if new tasks keep failing
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # spread across AZs, then across instances
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }
  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  health_check_grace_period_seconds = 60

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.task_execution_base,
    aws_iam_role_policy.task_execution_ssm,
  ]
}

# --- Service Auto Scaling ---

resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = var.service_max_count
  min_capacity       = var.service_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu_tracking" {
  name               = "${local.name_prefix}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.service_cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

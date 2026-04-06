# outputs

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "ecs_service_name" {
  value = aws_ecs_service.main.name
}

output "alb_dns_name" {
  description = "Point DNS here"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  value = aws_lb.main.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.main.arn
}

output "asg_name" {
  value = aws_autoscaling_group.ecs.name
}

output "capacity_provider_name" {
  value = aws_ecs_capacity_provider.main.name
}

output "task_execution_role_arn" {
  description = "Role that fetches secrets at launch"
  value       = aws_iam_role.ecs_task_execution.arn
}

output "task_role_arn" {
  description = "Runtime identity for the container"
  value       = aws_iam_role.ecs_task.arn
}

output "instance_role_arn" {
  value = aws_iam_role.ecs_instance.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.ecs_service.name
}

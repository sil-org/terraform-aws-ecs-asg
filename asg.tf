/*
 * Generate user_data from template file
 */
locals {
  user_data = templatefile("${path.module}/default-user-data.sh", {
    ecs_cluster_name     = var.cluster_name
    additional_user_data = var.additional_user_data
  })
}

/*
 * Create Launch Template
 */
resource "aws_launch_template" "lt" {
  ebs_optimized = false
  name          = "lt-${var.cluster_name}"
  image_id      = data.aws_ami.ecs_ami.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name
  user_data     = base64encode(var.user_data != "false" ? var.user_data : local.user_data)

  iam_instance_profile {
    name = aws_iam_instance_profile.ecsInstanceProfile.id
  }

  monitoring {
    enabled = var.enable_ec2_detailed_monitoring
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = var.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = var.tags
  }

  network_interfaces {
    ipv6_address_count = var.enable_ipv6 ? 1 : 0
    security_groups    = var.security_group_ids
  }
}

/*
 * Create Auto-Scaling Group
 */
resource "aws_autoscaling_group" "asg" {
  name                      = var.cluster_name
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_period
  default_cooldown          = var.default_cooldown
  termination_policies      = var.termination_policies

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  tag {
    key                 = "ecs_cluster"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  protect_from_scale_in = var.protect_from_scale_in

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * Create autoscaling policies
 */
resource "aws_autoscaling_policy" "up" {
  name                   = "${var.cluster_name}-scaleUp"
  scaling_adjustment     = var.scaling_adjustment_up
  adjustment_type        = var.adjustment_type
  cooldown               = var.policy_cooldown
  policy_type            = "SimpleScaling"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  count                  = var.alarm_actions_enabled ? 1 : 0
}

resource "aws_autoscaling_policy" "down" {
  name                   = "${var.cluster_name}-scaleDown"
  scaling_adjustment     = var.scaling_adjustment_down
  adjustment_type        = var.adjustment_type
  cooldown               = var.policy_cooldown
  policy_type            = "SimpleScaling"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  count                  = var.alarm_actions_enabled ? 1 : 0
}

/*
 * Create CloudWatch alarms to trigger scaling of ASG
 */
resource "aws_cloudwatch_metric_alarm" "scaleUp" {
  alarm_name          = "${var.cluster_name}-scaleUp"
  alarm_description   = "ECS cluster scaling metric above threshold"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = var.scaling_metric_name
  namespace           = "AWS/ECS"
  statistic           = "Average"
  period              = var.alarm_period
  threshold           = var.alarm_threshold_up
  actions_enabled     = var.alarm_actions_enabled
  count               = var.alarm_actions_enabled ? 1 : 0
  alarm_actions       = [aws_autoscaling_policy.up[0].arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}

resource "aws_cloudwatch_metric_alarm" "scaleDown" {
  alarm_name          = "${var.cluster_name}-scaleDown"
  alarm_description   = "ECS cluster scaling metric under threshold"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = var.evaluation_periods
  metric_name         = var.scaling_metric_name
  namespace           = "AWS/ECS"
  statistic           = "Average"
  period              = var.alarm_period
  threshold           = var.alarm_threshold_down
  actions_enabled     = var.alarm_actions_enabled
  count               = var.alarm_actions_enabled ? 1 : 0
  alarm_actions       = [aws_autoscaling_policy.down[0].arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}


data "template_file" "router-cloudinit" {
  template = "${file("./modules/openshift-cluster/router-cloudinit.yml")}"

  vars {
    openshift_url = "${var.openshift["url"]}"
    dns_zone_id = "${var.vpc_conf["zone_id"]}"
    aws_region = "${var.vpc_conf["region"]}"
  }
}

resource "aws_launch_configuration" "router" {
  name_prefix = "${var.aws_conf["domain"]}-router-"
  image_id = "${data.aws_ami.default.id}"
  instance_type = "${var.aws_conf["instance_type"]}"
  key_name = "${var.aws_conf["key_name"]}"
  iam_instance_profile = "${aws_iam_instance_profile.node-profile.id}"
  security_groups = [
    "${var.vpc_conf["security_group"]}",
    "${aws_security_group.router.id}",
    "${aws_security_group.node-router.id}",
    "${aws_security_group.external-router.id}"
  ]
  root_block_device {
    volume_type = "gp2"
    volume_size = 80
    delete_on_termination = false
  }
  user_data = "${data.template_file.router-cloudinit.rendered}"
  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "router" {
  name = "${var.openshift["domain"]}-router"
  launch_configuration = "${aws_launch_configuration.router.name}"
  vpc_zone_identifier = ["${split(",", var.vpc_conf["subnets_public"])}"]
  min_size = "${length(split(",", var.vpc_conf["availability_zones"]))}"
  max_size = "${length(split(",", var.vpc_conf["availability_zones"])) * 2}"
  desired_capacity = "${length(split(",", var.vpc_conf["availability_zones"]))}"
  wait_for_capacity_timeout = 0
  load_balancers = ["${aws_elb.router.id}"]

  tag {
    key = "Name"
    value = "${var.openshift["domain"]}-router"
    propagate_at_launch = true
  }
  tag {
    key = "Stack"
    value = "${var.openshift["domain"]}"
    propagate_at_launch = true
  }
  tag {
    key = "clusterid"
    value = "${var.openshift["domain"]}"
    propagate_at_launch = true
  }
  tag {
    key = "environment"
    value = "${var.openshift["environment"]}"
    propagate_at_launch = true
  }
  tag {
    key = "host-type"
    value = "lb"
    propagate_at_launch = true
  }
  tag {
    key = "sub-host-type"
    value = "infra"
    propagate_at_launch = true
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_policy" "router" {
  name = "${var.openshift["domain"]}-router"
  autoscaling_group_name = "${aws_autoscaling_group.router.name}"
  adjustment_type = "ChangeInCapacity"
  metric_aggregation_type = "Maximum"
  policy_type = "StepScaling"
  step_adjustment {
    metric_interval_lower_bound = 3.0
    scaling_adjustment = 2
  }
  step_adjustment {
    metric_interval_lower_bound = 2.0
    metric_interval_upper_bound = 3.0
    scaling_adjustment = 2
  }
  step_adjustment {
    metric_interval_lower_bound = 1.0
    metric_interval_upper_bound = 2.0
    scaling_adjustment = -1
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "router-elb" {
  name = "${var.openshift["domain"]}-router-elb"
  vpc_id = "${var.vpc_conf["id"]}"

  ingress {
    from_port = 0
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 0
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "${var.openshift["domain"]}-router-elb"
    Stack = "${var.openshift["domain"]}"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elb" "router" {
  name = "router-elb"
  subnets = ["${split(",", var.vpc_conf["subnets_public"])}"]

  security_groups = [
    "${var.vpc_conf["security_group"]}",
    "${aws_security_group.router-elb.id}"
  ]

  listener {
    lb_port            = 80
    lb_protocol        = "tcp"
    instance_port      = 80
    instance_protocol  = "tcp"
  }

  listener {
    lb_port            = 443
    lb_protocol        = "tcp"
    instance_port      = 443
    instance_protocol  = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 10
    target              = "TCP:80"
    interval            = 30
  }

  connection_draining = true
  cross_zone_load_balancing = true
  internal = "${var.openshift["internal"]}"

  tags {
    Stack = "${var.openshift["domain"]}"
    Name = "${var.openshift["domain"]}-router-elb"
  }
}

resource "aws_route53_record" "router" {
   zone_id = "${var.vpc_conf["zone_id"]}"
   name = "*.${var.openshift["apps_domain"]}"
   type = "A"
   alias {
     name = "${aws_elb.router.dns_name}"
     zone_id = "${aws_elb.router.zone_id}"
     evaluate_target_health = false
   }

   lifecycle {
     create_before_destroy = true
   }
}

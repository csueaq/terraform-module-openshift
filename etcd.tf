data "template_file" "etcd-cloudinit" {
  template = "${file("./modules/openshift-cluster/etcd-cloudinit.yml")}"

  vars {
    openshift_url = "${var.openshift["url"]}"
    dns_zone_id = "${var.vpc_conf["zone_id"]}"
    aws_region = "${var.vpc_conf["region"]}"
  }
}

resource "aws_launch_configuration" "etcd" {
  name_prefix = "${var.aws_conf["domain"]}-etcd-"
  image_id = "${data.aws_ami.default.id}"
  instance_type = "${var.aws_conf["instance_type"]}"
  key_name = "${var.aws_conf["key_name"]}"
  iam_instance_profile = "${aws_iam_instance_profile.node-profile.id}"
  security_groups = [
    "${var.vpc_conf["security_group"]}",
    "${aws_security_group.etcd.id}",
    "${aws_security_group.node-etcd.id}",
    "${aws_security_group.internal-etcd.id}"
  ]
  root_block_device {
    volume_type = "gp2"
    volume_size = 80
    delete_on_termination = false
  }
  user_data = "${data.template_file.etcd-cloudinit.rendered}"
  associate_public_ip_address = true

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "etcd" {
  name = "${var.openshift["domain"]}-etcd"
  launch_configuration = "${aws_launch_configuration.etcd.name}"
  vpc_zone_identifier = ["${split(",", var.vpc_conf["subnets_public"])}"]
  min_size = "${var.openshift["master_capacity_min"]}"
  max_size = "${var.openshift["master_capacity_max"]}"
  desired_capacity = "${var.openshift["master_capacity_min"]}"
  wait_for_capacity_timeout = 0
  load_balancers = ["${aws_elb.etcd.id}"]

  tag {
    key = "Name"
    value = "${var.openshift["domain"]}-etcd"
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
    value = "etcd"
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

resource "aws_autoscaling_policy" "etcd" {
  name = "${var.openshift["domain"]}-etcd"
  autoscaling_group_name = "${aws_autoscaling_group.etcd.name}"
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

resource "aws_security_group" "etcd-elb" {
  name = "${var.openshift["domain"]}-etcd-elb"
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
    Name = "${var.openshift["domain"]}-etcd-elb"
    Stack = "${var.openshift["domain"]}"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elb" "etcd" {
  name = "etcd-elb"
  subnets = ["${split(",", var.vpc_conf["subnets_public"])}"]

  security_groups = [
    "${var.vpc_conf["security_group"]}",
    "${aws_security_group.etcd-elb.id}"
  ]

  listener {
    lb_port            = 443
    lb_protocol        = "tcp"
    instance_port      = 2379
    instance_protocol  = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 10
    target              = "TCP:2379"
    interval            = 30
  }

  connection_draining = true
  cross_zone_load_balancing = true
  internal = true

  tags {
    Stack = "${var.openshift["domain"]}"
    Name = "${var.openshift["domain"]}-etcd-elb"
  }
}

resource "aws_route53_record" "etcd" {
   zone_id = "${var.vpc_conf["zone_id"]}"
   name = "etcd.${var.openshift["domain"]}"
   type = "A"
   alias {
     name = "${aws_elb.etcd.dns_name}"
     zone_id = "${aws_elb.etcd.zone_id}"
     evaluate_target_health = false
   }

   lifecycle {
     create_before_destroy = true
   }
}

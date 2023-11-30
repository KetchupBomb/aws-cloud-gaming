provider "aws" {
  region = var.region
}

data "aws_ami" "windows_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2019-English-Full-Base-*"]
  }
}

data "http" "local_ip" {
  url = "https://api.ipify.org?format=json"
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  availability_zones           = length(var.allowed_availability_zone_identifier) != 0 ? var.allowed_availability_zone_identifier : [for az in data.aws_availability_zones.available.names : substr(az, -1, 1)]
  availability_zone_identifier = element(local.availability_zones, random_integer.az_id.result)
  availability_zone            = "${var.region}${local.availability_zone_identifier}"

  local_ip = jsondecode(data.http.local_ip.response_body).ip

  ports = {
    "rdp" : {
      "tcp" : [{ "port" = 3389, "description" = "RDP", }, ],
    },
    "vnc" : {
      "tcp" : [{ "port" = 5900, "description" = "VNC", }, ],
    },
    "sunshine" : {
      "tcp" : [
        { "port" = 47984, "description" = "HTTPS", },
        { "port" = 47989, "description" = "HTTP", },
        { "port" = 47990, "description" = "Web", },
        { "port" = 48010, "description" = "RTSP", },
      ],
      "udp" : [
        { "port" = 47998, "description" = "Video", },
        { "port" = 47999, "description" = "Control", },
        { "port" = 48000, "description" = "Audio", },
        { "port" = 48002, "description" = "Mic (unused)", },
      ],
    },
  }
}

resource "random_integer" "az_id" {
  min = 0
  max = length(local.availability_zones)
}

resource "random_password" "password" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "password" {
  name  = "${var.resource_name}-administrator-password"
  type  = "SecureString"
  value = random_password.password.result

  tags = {
    App = "aws-cloud-gaming"
  }
}

resource "aws_security_group" "default" {
  name = "${var.resource_name}-sg"

  tags = {
    App = "aws-cloud-gaming"
  }
}

locals {
  port_forwardings = { for key, val in local.ports : key => val if var.firewall_rules[key] }
}
# Allow inbound connections from the local IP
resource "aws_security_group_rule" "ingress" {
  for_each = {
    for port in flatten([
      for app, protocols in local.port_forwardings : [
        for protocol, ports in protocols : [
          for port in ports :
          {
            name        = join("_", [app, protocol, port.port]),
            app         = app,
            protocol    = protocol,
            port        = port.port,
            description = port.description
          }
        ]
      ]
    ]) : join("_", [port.app, port.protocol, port.port]) => port
  }
  type              = "ingress"
  description       = each.value.description
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = ["${local.local_ip}/32"]
  security_group_id = aws_security_group.default.id
}

# Allow outbound connection to everywhere
resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.default.id
}

resource "aws_iam_role" "server_instance_role" {
  name               = "${var.resource_name}-instance-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
  tags = {
    App = "aws-cloud-gaming"
  }
}

resource "aws_iam_policy" "password_get_parameter_policy" {
  name   = "${var.resource_name}-password-get-parameter-policy"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "${aws_ssm_parameter.password.arn}"
    }
  ]
}
EOF
}

data "aws_iam_policy" "driver_get_object_policy" {
  arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "password_get_parameter_policy_attachment" {
  role       = aws_iam_role.server_instance_role.name
  policy_arn = aws_iam_policy.password_get_parameter_policy.arn
}

resource "aws_iam_role_policy_attachment" "driver_get_object_policy_attachment" {
  role       = aws_iam_role.server_instance_role.name
  policy_arn = data.aws_iam_policy.driver_get_object_policy.arn
}

resource "aws_iam_instance_profile" "server_instance_profile" {
  name = "${var.resource_name}-instance-profile"
  role = aws_iam_role.server_instance_role.name
}

resource "aws_spot_instance_request" "server_instance" {
  instance_type     = var.instance_type
  availability_zone = local.availability_zone
  ami               = (length(var.custom_ami) > 0) ? var.custom_ami : data.aws_ami.windows_ami.image_id
  security_groups   = [aws_security_group.default.name]
  user_data = var.skip_install ? "" : templatefile(
    "${path.module}/templates/user_data.tpl",
    {
      password_ssm_parameter = aws_ssm_parameter.password.name,
      var = {
        instance_type               = var.instance_type,
        install_parsec              = var.custom_software.parsec,
        install_auto_login          = var.custom_software.auto_login,
        install_graphic_card_driver = var.custom_software.gpu_driver,
        choco_packages              = var.choco_packages,
      }
    }
  )
  iam_instance_profile = aws_iam_instance_profile.server_instance_profile.id

  # Spot configuration
  spot_type            = "one-time"
  wait_for_fulfillment = true

  # EBS configuration
  ebs_optimized = true
  root_block_device {
    volume_size = var.root_block_device_size_gb
  }

  tags = {
    Name = "${var.resource_name}-instance"
    App  = "aws-cloud-gaming"
  }
}

output "instance_id" {
  value = aws_spot_instance_request.server_instance.spot_instance_id
}

output "instance_ip" {
  value = aws_spot_instance_request.server_instance.public_ip
}

output "instance_public_dns" {
  value = aws_spot_instance_request.server_instance.public_dns
}

output "instance_password" {
  value     = random_password.password.result
  sensitive = true
}

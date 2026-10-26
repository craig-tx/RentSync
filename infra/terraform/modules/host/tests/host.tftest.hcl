# Host hardening and durability (FR-009, FR-031, constitution VI). Lives with the module
# because a root's tests cannot reference resources inside a module. key_name (no SSH key) is
# checked statically by check_prevent_destroy.sh: it is computed, so unknown under mocks.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  deployment_id      = "pr-42"
  ami_id             = "ami-0123456789abcdef0"
  instance_type      = "t4g.small"
  availability_zone  = "us-east-1a"
  subnet_id          = "subnet-0123456789abcdef0"
  private_ip         = "10.40.1.42"
  security_group_ids = ["sg-0123456789abcdef0"]
  files              = {}
  host_env           = { HOST_ROLE = "environment" }
  ssm_read_paths     = ["/rentsync/pr-42"]
  ssm_write_params   = ["/rentsync/pr-42/image_tag"]
  ecr_repository_arn = "arn:aws:ecr:us-east-1:123456789012:repository/shared-us/mock_pms"
}

run "hardened_and_durable" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.root_block_device[0].tags["DeploymentId"] == "pr-42"
    error_message = "The root volume must be encrypted and tagged with its DeploymentId (constitution VI)."
  }

  assert {
    condition     = aws_ebs_volume.data.encrypted && aws_ebs_volume.data.tags["rentsync:backup"] == "daily"
    error_message = "The data volume must be encrypted and tagged for daily backups (FR-031, FR-032)."
  }

  assert {
    condition     = aws_network_interface.this.private_ips == toset(["10.40.1.42"])
    error_message = "The network interface must carry the configured fixed private IP (research R3)."
  }

  assert {
    condition     = aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "The instance must stop before the data volume detaches."
  }

  assert {
    condition     = aws_instance.this.user_data_replace_on_change
    error_message = "Host configuration changes must replace the host (research R6)."
  }
}

run "x86_fallback_uses_x86_compose" {
  command = plan

  variables {
    instance_type = "t3.small"
  }

  assert {
    condition     = local.arch == "x86_64"
    error_message = "Non-Graviton types must install the x86_64 Compose plugin."
  }
}

run "swap_file_at_first_boot" {
  command = plan

  override_resource {
    target          = aws_ebs_volume.data
    override_during = plan
    values          = { id = "vol-0123456789abcdef0" }
  }

  assert {
    condition     = strcontains(local.user_data, "/usr/local/bin/rentsync-swap 1024") && strcontains(local.user_data, "/etc/sysctl.d/90-rentsync.conf")
    error_message = "Hosts must create a 1 GiB swap file and set vm.swappiness at first boot (research R4)."
  }
}

run "swap_can_be_turned_off" {
  command = plan

  override_resource {
    target          = aws_ebs_volume.data
    override_during = plan
    values          = { id = "vol-0123456789abcdef0" }
  }

  variables {
    swap_mib = 0
  }

  assert {
    condition     = !strcontains(local.user_data, "rentsync-swap 0") && !strcontains(local.user_data, "/usr/local/bin/rentsync-swap ")
    error_message = "swap_mib = 0 must not create a swap file."
  }
}

run "swap_must_fit_the_root_disk" {
  command = plan

  variables {
    swap_mib = 8192
  }

  expect_failures = [var.swap_mib]
}

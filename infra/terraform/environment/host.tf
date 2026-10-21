# The environment host and its public surface (research R7, R12). Security group rules are
# standalone resources.

resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "Environment host: HTTP and HTTPS from the internet only (FR-009)"
  vpc_id      = local.shared.vpc_id

  tags = { Name = "${local.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "public" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

module "host" {
  source = "../modules/host"

  deployment_id      = var.deployment_id
  ami_id             = local.shared.ami_id
  instance_type      = var.instance_type
  availability_zone  = local.shared.availability_zone
  subnet_id          = local.shared.subnet_id
  private_ip         = var.private_ip
  security_group_ids = [aws_security_group.this.id, local.shared.otlp_client_security_group_id]
  ssm_read_paths     = [local.ssm_prefix, local.shared.ingest_ssm_path]
  ssm_write_params   = [aws_ssm_parameter.image_tag.name, aws_ssm_parameter.previous_image_tag.name]
  ecr_repository_arn = local.shared.ecr_repository_arn
  data_snapshot_id   = var.data_snapshot_id

  # Releases target hosts by DeploymentId; the release role may run commands only on hosts
  # with this tag (contracts/bootstrap-iam.md).
  extra_tags = { "rentsync:deployable" = "true" }

  # The mock PMS stack is added in US2 (tasks T056-T059).
  files = {}
  host_env = {
    HOST_ROLE                 = "environment"
    DEPLOYMENT_ID             = var.deployment_id
    DEPLOYMENT_ENVIRONMENT    = var.environment
    SITE_HOSTNAME             = var.hostname
    DB_NAME                   = local.db_name
    AWS_REGION                = var.region
    SSM_READ_PATHS            = join(" ", [local.ssm_prefix, local.shared.ingest_ssm_path])
    ECR_REPOSITORY_URL        = local.shared.ecr_repository_url
    OPENOBSERVE_OTLP_ENDPOINT = local.shared.otlp_endpoint
  }
}

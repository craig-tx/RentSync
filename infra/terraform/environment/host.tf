# The environment host and its public surface (research R7, R12). Security group rules are
# standalone resources.

resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "Environment host: HTTP and HTTPS from the internet only (FR-009)"
  vpc_id      = module.network.vpc_id

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
  subnet_id          = module.network.subnet_id
  private_ip         = var.private_ip
  security_group_ids = [aws_security_group.this.id]
  ssm_read_paths     = [local.ssm_prefix, local.shared.ingest_ssm_path]
  ssm_write_params   = [aws_ssm_parameter.image_tag.name, aws_ssm_parameter.previous_image_tag.name]
  ecr_repository_arn = local.shared.ecr_repository_arn
  data_snapshot_id   = var.data_snapshot_id

  # Releases target hosts by DeploymentId. The non-production release role may run commands only
  # on hosts tagged "true"; production hosts are "protected", which only the prod-us role (trusted
  # solely for the prod-us GitHub Environment) may touch (contracts/bootstrap-iam.md).
  extra_tags = { "rentsync:deployable" = local.deployable_tag }

  # The mock PMS stack (research R7). One copy of each file, read from infra/.
  files = {
    "/opt/rentsync/compose.yaml"     = { content = file("${path.module}/../../host/compose.env.yaml"), permissions = "0644" }
    "/opt/rentsync/Caddyfile"        = { content = file("${path.module}/../../host/Caddyfile.env"), permissions = "0644" }
    "/opt/rentsync/collector.yaml"   = { content = file("${path.module}/../../otel/collector.yaml"), permissions = "0644" }
    "/usr/local/bin/rentsync-deploy" = { content = file("${path.module}/../../host/bin/rentsync-deploy"), permissions = "0755" }
  }
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
    ACME_EMAIL                = var.acme_email
    ACME_CA                   = var.acme_ca
  }
}

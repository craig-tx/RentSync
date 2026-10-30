# Image registry for the mock PMS (research R16). Owned by the shared deployment, so every
# environment pulls the exact image staging verified (FR-027).

resource "aws_ecr_repository" "mock_pms" {
  name                 = "${var.deployment_id}/mock_pms"
  image_tag_mutability = "IMMUTABLE" # a tag (the git SHA) is always one image
  force_delete         = false       # teardown empties it first (runbook §Teardown)

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "mock_pms" {
  repository = aws_ecr_repository.mock_pms.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      # Generous: prod-us moves only on approval, so many merges can land between promotions,
      # and the image prod runs (and its rollback target) must not expire.
      description = "Keep the last 100 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 100
      }
      action = { type = "expire" }
    }]
  })
}

# RentSync's API image (feature 003 research R15), kept exactly like the mock's: one release
# ships both at the same commit SHA.
resource "aws_ecr_repository" "api" {
  name                 = "${var.deployment_id}/api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy     = aws_ecr_lifecycle_policy.mock_pms.policy
}

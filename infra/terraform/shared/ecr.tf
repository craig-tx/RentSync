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
      description  = "Keep the last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = local.common_tags
  }
}
data "aws_caller_identity" "current" {}

check "expected_aws_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.aws_account_id
    error_message = "The authenticated AWS account does not match var.aws_account_id."
  }
}

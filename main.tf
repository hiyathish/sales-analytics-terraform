# ==========================================================
# Sales analytics: Stage 1 - foundation
# Glue database, Athena workgroup, read-only group and users,
# and folder markers in the existing bucket.
# ==========================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = "sales-analytics"
    }
  }
}

# ---------- Inputs ----------

variable "environment" {
  description = "dev, qa or prod"
  type        = string

  validation {
    condition     = contains(["dev", "qa", "prod"], var.environment)
    error_message = "environment must be dev, qa or prod."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_account_id" {
  description = "Account this environment must run in."
  type        = string
}

variable "bucket_name" {
  description = "Existing S3 bucket that holds the raw and curated data."
  type        = string
}

variable "reader_users" {
  description = "IAM user names to create and add to the read group. Passwords are set separately."
  type        = list(string)
  default     = []
}

# ---------- Derived names ----------

locals {
  database_name  = "sales_db_${var.environment}"
  workgroup_name = "sales-analytics-${var.environment}"
  reader_group   = "read_${var.environment}"

  curated_prefix = "curated/"
  results_prefix = "athena-results/"

  glue_arn = "arn:aws:glue:${var.aws_region}:${var.aws_account_id}"
}

# ---------- Existing bucket (referenced only, not changed) ----------

data "aws_s3_bucket" "data" {
  bucket = var.bucket_name
}

# Folder markers for curated output and Athena results
resource "aws_s3_object" "curated_customers" {
  bucket  = data.aws_s3_bucket.data.id
  key     = "${local.curated_prefix}customers/"
  content = ""
}

resource "aws_s3_object" "curated_sales_orders" {
  bucket  = data.aws_s3_bucket.data.id
  key     = "${local.curated_prefix}sales_orders/"
  content = ""
}

resource "aws_s3_object" "athena_results" {
  bucket  = data.aws_s3_bucket.data.id
  key     = local.results_prefix
  content = ""
}

# ---------- Glue catalog database ----------

resource "aws_glue_catalog_database" "sales" {
  name        = local.database_name
  description = "Sales analytics tables (${var.environment})"
}

# ---------- Athena workgroup ----------

resource "aws_athena_workgroup" "sales" {
  name          = local.workgroup_name
  force_destroy = var.environment != "prod"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${data.aws_s3_bucket.data.bucket}/${local.results_prefix}"
    }
  }
}

# ---------- Read-only group and users ----------

resource "aws_iam_group" "readers" {
  name = local.reader_group
}

data "aws_iam_policy_document" "readers" {
  statement {
    sid = "RunAthenaQueries"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
    ]
    resources = [aws_athena_workgroup.sales.arn]
  }

  statement {
    sid = "ReadGlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]
    resources = [
      "${local.glue_arn}:catalog",
      "${local.glue_arn}:database/${local.database_name}",
      "${local.glue_arn}:table/${local.database_name}/*",
    ]
  }

  statement {
    sid       = "ReadCuratedData"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.data.arn}/${local.curated_prefix}*"]
  }

  statement {
    sid       = "ListCuratedAndResults"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.data.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.curated_prefix}*", "${local.results_prefix}*"]
    }
  }

  statement {
    sid       = "BucketLocation"
    actions   = ["s3:GetBucketLocation"]
    resources = [data.aws_s3_bucket.data.arn]
  }

  statement {
    sid       = "WriteAthenaResults"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${data.aws_s3_bucket.data.arn}/${local.results_prefix}*"]
  }
}

resource "aws_iam_group_policy" "readers" {
  name   = "sales-read-${var.environment}"
  group  = aws_iam_group.readers.name
  policy = data.aws_iam_policy_document.readers.json
}

resource "aws_iam_user" "readers" {
  for_each = toset(var.reader_users)
  name     = each.value
}

resource "aws_iam_user_group_membership" "readers" {
  for_each = aws_iam_user.readers
  user     = each.value.name
  groups   = [aws_iam_group.readers.name]
}

# ---------- Outputs ----------

output "database_name" {
  value = aws_glue_catalog_database.sales.name
}

output "workgroup_name" {
  value = aws_athena_workgroup.sales.name
}

output "reader_group_name" {
  value = aws_iam_group.readers.name
}

output "curated_location" {
  value = "s3://${data.aws_s3_bucket.data.bucket}/${local.curated_prefix}"
}
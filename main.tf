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

# --- Stage 3a: role the Glue jobs run as -------------------------------------

data "aws_iam_policy_document" "glue_jobs_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue_jobs" {
  name               = "sales-analytics-glue-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.glue_jobs_trust.json
}

# AWS managed baseline for Glue: logging and service access
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_jobs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_jobs_data" {
  statement {
    sid     = "ReadRawFiles"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.bucket_name}",
      "arn:aws:s3:::${var.bucket_name}/avro_datastage_files/*",
    ]
  }

  statement {
    sid       = "WriteCurated"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.bucket_name}/curated/*"]
  }

  statement {
    sid     = "ScriptsAndTemp"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.bucket_name}/glue-scripts/*",
      "arn:aws:s3:::${var.bucket_name}/glue-temp/*",
    ]
  }

  statement {
    sid = "CatalogPartitions"
    actions = [
      "glue:GetTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:UpdatePartition",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${aws_glue_catalog_database.sales.name}",
      "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:table/${aws_glue_catalog_database.sales.name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "glue_jobs_data" {
  name   = "sales-analytics-glue-data"
  role   = aws_iam_role.glue_jobs.id
  policy = data.aws_iam_policy_document.glue_jobs_data.json
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

# --- Stage 2: curated catalog tables -----------------------------------------
# Both tables read Parquet from the curated folders. Raw Avro is never queried
# directly. Stage 3 writes the curated files and registers the monthly partitions.

resource "aws_glue_catalog_table" "customers" {
  name          = "customers"
  database_name = aws_glue_catalog_database.sales.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    classification        = "parquet"
    "parquet.compression" = "SNAPPY"
  }

  partition_keys {
    name = "signup_month"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_name}/curated/customers/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    compressed    = true

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "customer_id"
      type = "string"
    }
    columns {
      name = "first_name"
      type = "string"
    }
    columns {
      name = "last_name"
      type = "string"
    }
    columns {
      name = "email"
      type = "string"
    }
    columns {
      name = "city"
      type = "string"
    }
    columns {
      name = "state"
      type = "string"
    }
    columns {
      name = "zip_code"
      type = "string"
    }
    columns {
      name = "segment"
      type = "string"
    }
    columns {
      name = "signup_date"
      type = "date"
    }
  }
}

resource "aws_glue_catalog_table" "sales_orders" {
  name          = "sales_orders"
  database_name = aws_glue_catalog_database.sales.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL              = "TRUE"
    classification        = "parquet"
    "parquet.compression" = "SNAPPY"
  }

  partition_keys {
    name = "order_month"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_name}/curated/sales_orders/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    compressed    = true

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "order_id"
      type = "string"
    }
    columns {
      name = "order_date"
      type = "date"
    }
    columns {
      name = "customer_id"
      type = "string"
    }
    columns {
      name = "product_id"
      type = "string"
    }
    columns {
      name = "product_name"
      type = "string"
    }
    columns {
      name = "category"
      type = "string"
    }
    columns {
      name = "quantity"
      type = "int"
    }
    columns {
      name = "unit_price"
      type = "decimal(10,2)"
    }
    columns {
      name = "line_total"
      type = "decimal(12,2)"
    }
  }
}
locals {
  enabled = module.this.enabled

  is_vpc                 = var.vpc_id != null
  security_group_enabled = module.this.enabled && var.security_group_enabled
  user_names             = keys(var.sftp_users)
  user_names_map         = { for idx, user in local.user_names : idx => user }
  is_s3                  = var.domain == "S3"
}

data "aws_s3_bucket" "landing" {
  count = local.enabled && local.is_s3 ? 1 : 0

  bucket = var.s3_bucket_name
}

resource "aws_transfer_server" "default" {
  count = local.enabled ? 1 : 0

  identity_provider_type = "SERVICE_MANAGED"
  protocols              = ["SFTP"]
  domain                 = var.domain
  endpoint_type          = local.is_vpc ? "VPC" : "PUBLIC"
  force_destroy          = var.force_destroy
  security_policy_name   = var.security_policy_name
  logging_role           = join("", aws_iam_role.logging[*].arn)
  host_key               = var.host_key

  dynamic "endpoint_details" {
    for_each = local.is_vpc ? [1] : []

    content {
      subnet_ids             = var.subnet_ids
      security_group_ids     = local.security_group_enabled ? module.security_group.*.id : var.vpc_security_group_ids
      vpc_id                 = var.vpc_id
      address_allocation_ids = var.eip_enabled ? aws_eip.sftp.*.id : var.address_allocation_ids
    }
  }
  dynamic workflow_details {
    for_each = var.kafka_lambda_enabled ? [1] : []
    
    content {
      on_upload {
        execution_role = aws_iam_role.sftp_transfer_role[count.index].arn
        workflow_id = aws_transfer_workflow.kafka[count.index].id
      }
    }
  }
    

  tags = module.this.tags
}

resource "aws_transfer_user" "default" {
  for_each = local.enabled ? var.sftp_users : {}

  server_id = join("", aws_transfer_server.default[*].id)
  role      = aws_iam_role.s3_access_for_sftp_users[index(local.user_names, each.value.user_name)].arn

  user_name = each.value.user_name

  home_directory_type = var.restricted_home ? "LOGICAL" : "PATH"

  dynamic "home_directory_mappings" {
    for_each = var.restricted_home ? [1] : []

    content {
      entry  = "/"
      target = "/${var.s3_bucket_name}/${each.value.user_name}"
    }
  }

  dynamic "posix_profile" {
    for_each = local.is_s3 ? [] : [1]

    content {
      gid = 0
      uid = each.value.unix_uid
    }
  }
      

  tags = module.this.tags
}

resource "aws_transfer_ssh_key" "default" {
  for_each = local.enabled ? var.sftp_users : {}

  server_id = join("", aws_transfer_server.default[*].id)

  user_name = each.value.user_name
  body      = each.value.public_key

  depends_on = [
    aws_transfer_user.default
  ]
}

resource "aws_eip" "sftp" {
  count = local.enabled && var.eip_enabled ? length(var.subnet_ids) : 0

  vpc = local.is_vpc
}

module "security_group" {
  source  = "cloudposse/security-group/aws"
  version = "0.3.1"

  use_name_prefix = var.security_group_use_name_prefix
  rules           = var.security_group_rules
  description     = var.security_group_description
  vpc_id          = local.is_vpc ? var.vpc_id : null

  enabled = local.security_group_enabled
  context = module.this.context
}

# Custom Domain
resource "aws_route53_record" "main" {
  count = local.enabled && length(var.domain_name) > 0 && length(var.zone_id) > 0 ? 1 : 0

  name    = var.domain_name
  zone_id = var.zone_id
  type    = "CNAME"
  ttl     = "300"

  records = [
    join("", aws_transfer_server.default[*].endpoint)
  ]
}

module "logging_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["transfer", "cloudwatch"]

  context = module.this.context
}

data "aws_iam_policy_document" "assume_role_policy" {
  count = local.enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["transfer.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "efs_access_for_sftp_users" {
  for_each = local.enabled && !local.is_s3 ? local.user_names_map : {}

  statement {
    sid = "AllowEFSAccess"
    effect = "Allow"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientRootAccess"
    ]

    resources = [
      "arn:aws:elasticfilesystem:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:file-system/${var.s3_bucket_name}"
    ]
  }
}


data "aws_iam_policy_document" "s3_access_for_sftp_users" {
  for_each = local.enabled && local.is_s3 ? local.user_names_map : {}

  statement {
    sid    = "AllowListingOfUserFolder"
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      join("", data.aws_s3_bucket.landing[*].arn)
    ]
  }

  statement {
    sid    = "HomeDirObjectAccess"
    effect = "Allow"

    actions = var.s3_bucket_permissions

    resources = [
      "${join("", data.aws_s3_bucket.landing[*].arn)}/${each.value}/*"
    ]
  }
}

data "aws_iam_policy_document" "logging" {
  count = local.enabled ? 1 : 0

  statement {
    sid    = "CloudWatchAccessForAWSTransfer"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:CreateLogGroup",
      "logs:PutLogEvents"
    ]

    resources = ["*"]
  }
}

module "iam_label" {
  for_each = local.enabled ? local.user_names_map : {}

  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["transfer", "s3", each.value]

  context = module.this.context
}

resource "aws_iam_policy" "s3_access_for_sftp_users" {
  for_each = local.enabled ? local.user_names_map : {}

  name   = module.iam_label[index(local.user_names, each.value)].id
  policy = (local.is_s3 ? data.aws_iam_policy_document.s3_access_for_sftp_users : data.aws_iam_policy_document.efs_access_for_sftp_users)[index(local.user_names, each.value)].json 
}

resource "aws_iam_role" "s3_access_for_sftp_users" {
  for_each = local.enabled ? local.user_names_map : {}

  name = module.iam_label[index(local.user_names, each.value)].id

  assume_role_policy  = join("", data.aws_iam_policy_document.assume_role_policy[*].json)
  managed_policy_arns = [aws_iam_policy.s3_access_for_sftp_users[index(local.user_names, each.value)].arn]
}

resource "aws_iam_policy" "logging" {
  count = local.enabled ? 1 : 0

  name   = module.logging_label.id
  policy = join("", data.aws_iam_policy_document.logging[*].json)
}

resource "aws_iam_role" "logging" {
  count = local.enabled ? 1 : 0

  name                = module.logging_label.id
  assume_role_policy  = join("", data.aws_iam_policy_document.assume_role_policy[*].json)
  managed_policy_arns = [join("", aws_iam_policy.logging[*].arn)]
}

resource "aws_iam_role" "sftp_transfer_role" {
  count = var.kafka_lambda_enabled ? 1 : 0

  name = "SFTPTransferRole"
  
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "transfer.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
  inline_policy {
    name = "AllowTransferToReadAndCallLambda"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
	{
	  Sid = "ConsoleAccess"
	  Effect = "Allow"
	  Action = "s3:GetBucketLocation"
	  Resource = "*"
	},
        {
	  Sid = "ListObjectsInBucket"
	  Effect = "Allow"
	  Action = "s3:ListBucket"
	  Resource = [
	    "arn:aws:s3:::${var.s3_bucket_name}"
	  ]
        },
        {
	  Sid = "AllObjectActions"
	  Effect = "Allow"
	  Action = "s3:*Object"
	  Resource = [
	    "arn:aws:s3:::${var.s3_bucket_name}/*"
	  ]
	},
        {
	  Sid = "GetObjectVersion"
	  Effect = "Allow"
	  Action = "s3:GetObjectVersion"
	  Resource = [
	    "arn:aws:s3:::${var.s3_bucket_name}/*"
	  ]
	},
        {
	  Sid = "Custom"
	  Effect = "Allow"
	  Action = [
	    "lambda:InvokeFunction"
	  ]
	  Resource = [ aws_lambda_function.push_to_kafka[count.index].arn ]
        }
    ]
    }
    )
  }
}

resource "aws_cloudwatch_log_group" "push_to_kafka" {
  count = var.kafka_lambda_enabled ? 1 : 0
  name = "/aws/lambda/push_to_kafka"
  retention_in_days = 14
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


resource "aws_iam_role" "iam_for_lambda" {
  count = var.kafka_lambda_enabled ? 1 : 0
  name = "push_to_kafka"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
  inline_policy {
    name = "AWSLambdaExecutionRole"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
	{
	  Effect = "Allow"
	  Action = "logs:CreateLogGroup"
	  Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
	},
        {
	  Effect = "Allow"
	  Action = [
	    "logs:CreateLogStream",
	    "logs:PutLogEvents"
	  ]
	  Resource = [
	    "${aws_cloudwatch_log_group.push_to_kafka[0].arn}:*"
	  ]
	}
      ]
    })
  }
  inline_policy {
    name = "AllowSendWorkflow"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
	  Effect= "Allow"
	  Action= [
	    "ec2:DescribeNetworkInterfaces"
	  ]
	  Resource= "*"
        },
        {
	  Effect = "Allow"
	  Action = [
	    "ec2:CreateNetworkInterface",
	    "ec2:DeleteNetworkInterface"
	  ]
	  Resource = [
	    "arn:aws:ec2:*:${data.aws_caller_identity.current.account_id}:*/*"
	  ]
        },
        {
	  Effect = "Allow"
	  Action = [
	    "transfer:SendWorkflowStepState"
	  ]
	  Resource = [
	    "arn:aws:transfer:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:workflow/*"
	  ]
	}
      ]
    })
  }
  inline_policy {
    name   = "AllowEFSAccess" 
    policy = jsonencode(
      {
	Statement = [
	  {
	    Action   = [
	      "elasticfilesystem:ClientWrite",
	      "elasticfilesystem:ClientRootAccess",
	      "elasticfilesystem:ClientMount",
	    ]
	    Effect   = "Allow"
	    Resource = "arn:aws:elasticfilesystem:us-west-2:831078261596:file-system/fs-0d7a2f26c92ac1dbe"
	    Sid      = "AllowEFSAccess"
	  },
	]
	Version   = "2012-10-17"
      }
      ) 
  }
  inline_policy {
    name   = "AllowS3Write" 
    policy = jsonencode(
      {
	Statement = [
	  {
	    Action   = [
	      "s3:ReplicateObject",
	      "s3:PutObject",
	      "s3:GetObjectAcl",
	      "s3:GetObject",
	      "s3:ListBucket",
	      "s3:InitiateReplication",
	      "s3:GetBucketAcl",
	      "s3:PutBucketVersioning",
	      "s3:GetObjectVersion",
	    ]
	    Effect   = "Allow"
	    Resource = [
	      "arn:aws:s3:::npm-prod-nm/*",
	      "arn:aws:s3:::npm-prod-nm-qa/*",
	    ]
	    Sid      = "VisualEditor0"
	  },
	]
	Version   = "2012-10-17"
      }
      )
  }
}

resource "aws_lambda_function" "push_to_kafka" {
  count = var.kafka_lambda_enabled ? 1 : 0
  function_name = "push_to_kafka"
  filename = var.lambda_zip
  role = aws_iam_role.iam_for_lambda[count.index].arn
  handler = var.lambda_handler
  runtime = "python3.8"
  vpc_config {
    security_group_ids = var.vpc_security_group_ids
    subnet_ids = var.vpc_private_subnet_ids
  }
  memory_size = 512
  timeout = 300
  environment {
    variables = {
      KAFKA_REST_SERVER = var.kafka_rest_server
      #      KAFKA_QUEUE = var.kafka_queue
      EFS_ARCHIVE_FOLDER         = "archive"
      EFS_KAFKA_ERRORS_LOCATION  = "kafka_errors"
      EFS_MOUNT_LOCATION         = "/mnt/incoming"
      EFS_PREFIX_ALLOW_LIST      = "nmohc_oncoemr/nmohc/documents,nmohc_oncoemr/nmohc/scheduling"
      EFS_QUARANTINE_LOCATION    = "quarantine"
      EFS_HOLDING_FOLDER         = "holding"
      EFS_S3_PATH_CONFIG_PATH    = "lambda_config/sftp_path_config_20221027.json"
      EFS_SFTP_INTEGRATION_USERS = "nmohc_oncoemr"
      KAFKA_REST_SERVER_QA       = "kafka-rest-clinicalqa.npm.betteromics.com:8082"
      KAFKA_TOPIC                = "hl7_npower_nmcc"
      KAFKA_TOPIC_QA             = "hl7_npower_nmcc_qa"
      S3_DESTINATION_BUCKET      = "npm-prod-nm"
      S3_DESTINATION_BUCKET_QA   = "npm-prod-nm-qa"
      S3_DESTINATION_PREFIX      = "lambda_transfer"
      SENTRY_DSN                 = "https://6e9c65f999a54a5caf42c75c3ab41d47@o444126.ingest.sentry.io/6523232"
      SENTRY_SERVICE_NAME        = "ClinicalLambdaEtl"
      SLEEP_TIME                 = "3"
      TRANSFER_REGION            = "us-west-2"
      VAULT_ADDR                 = "https://vault.corp.betteromics.com:8200"
      VAULT_HMAC_KEY_NAME        = "push_to_s3"
      VAULT_NAMESPACE            = "npmprod"
      VAULT_ROLE                 = "dev"
    }
  }
  file_system_config {
    arn              = "arn:aws:elasticfilesystem:us-west-2:831078261596:access-point/fsap-0fa8e667bde09fc08"
    local_mount_path = "/mnt/incoming"
  }
}

resource "aws_transfer_workflow" "kafka" {
  count = var.kafka_lambda_enabled ? 1 : 0
  description = "kafka"
  steps {
    custom_step_details {
      name = "Step0"
      target = aws_lambda_function.push_to_kafka[count.index].arn
      source_file_location = "$${previous.file}"
      timeout_seconds = 60
    }
    type = "CUSTOM"
  }
}


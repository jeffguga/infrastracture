terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "M-Motors"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

############################################################
# VARIABLES
############################################################

variable "aws_region" {
  description = "Région AWS de déploiement"
  type        = string
  default     = "eu-west-3"
}

variable "environment" {
  description = "Environnement de déploiement"
  type        = string
  default     = "dev"
}

variable "alert_email" {
  description = "Adresse e-mail recevant les alertes"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Budget mensuel AWS en dollars"
  type        = number
  default     = 300
}

variable "db_username" {
  description = "Nom d'utilisateur PostgreSQL"
  type        = string
  default     = "mmotors_admin"
}

variable "db_password" {
  description = "Mot de passe PostgreSQL"
  type        = string
  sensitive   = true
}

variable "backend_image" {
  description = "Image Docker du backend Python"
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.12-slim"
}

variable "dev_instance_type" {
  description = "Type de l'instance EC2 de développement"
  type        = string
  default     = "t3.micro"
}

############################################################
# VARIABLES LOCALES
############################################################

locals {
  name = "m-motors-${var.environment}"
}

############################################################
# DONNÉES ET IDENTIFIANT ALÉATOIRE
############################################################

resource "random_id" "suffix" {
  byte_length = 4
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

############################################################
# VPC
############################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

############################################################
# INTERNET GATEWAY
############################################################

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name}-internet-gateway"
  }
}

############################################################
# SOUS-RÉSEAUX PUBLICS
############################################################

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${count.index + 1}"
    Type = "Public"
  }
}

############################################################
# SOUS-RÉSEAUX PRIVÉS
############################################################

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${local.name}-private-${count.index + 1}"
    Type = "Private"
  }
}

############################################################
# NAT GATEWAY
############################################################

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [
    aws_internet_gateway.main
  ]

  tags = {
    Name = "${local.name}-nat-gateway"
  }
}

############################################################
# TABLE DE ROUTAGE PUBLIQUE
############################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name}-public-routes"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

############################################################
# TABLE DE ROUTAGE PRIVÉE
############################################################

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name}-private-routes"
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

############################################################
# BUCKET S3 PUBLIC POUR LE FRONTEND
############################################################

resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name}-frontend-${random_id.suffix.hex}"

  tags = {
    Name        = "${local.name}-frontend"
    Purpose     = "Static website"
    DataClass   = "Public"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_object" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  key    = "index.html"
  source = "index.html"

}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  depends_on = [
    aws_s3_bucket_public_access_block.frontend
  ]

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid       = "AllowPublicRead"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })
}


############################################################
# BUCKET S3 PRIVÉ POUR LES DOSSIERS CLIENTS
############################################################

resource "aws_s3_bucket" "documents" {
  bucket = "${local.name}-documents-${random_id.suffix.hex}"

  tags = {
    Name        = "${local.name}-documents"
    Purpose     = "Purchase and rental documents"
    DataClass   = "Confidential"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "documents" {
  bucket = aws_s3_bucket.documents.id
  key    = "dossier d'achat"
  source = "./dossier"

}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  depends_on = [
    aws_s3_bucket_versioning.documents
  ]

  rule {
    id     = "archive-old-versions"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

############################################################
# SECURITY GROUP DU LOAD BALANCER
############################################################

resource "aws_security_group" "alb" {
  name        = "m-motors-dev-alb-sg"
  description = "HTTP access to Load Balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP public"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Trafic sortant"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-alb-sg"
  }
}

############################################################
# SECURITY GROUP ECS
############################################################
resource "aws_security_group" "ecs" {
  name        = "m-motors-dev-ecs-sg"
  description = "Backend access only from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Backend depuis ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Trafic sortant ECS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-ecs-sg"
  }
}

############################################################
# SECURITY GROUP RDS
############################################################

resource "aws_security_group" "rds" {
  name        = "m-motors-dev-rds-sg"
  description = "Acces PostgreSQL uniquement depuis ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL depuis ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    description = "Trafic sortant RDS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-rds-sg"
  }
}

############################################################
# SECURITY GROUP EC2 DEV
############################################################

resource "aws_security_group" "dev" {
  name        = "m-motors-dev-dev-sg"
  description = "Systems Manager managed instance"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Trafic sortant EC2"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-dev-sg"
  }
}

############################################################
# GROUPE DE SOUS-RÉSEAUX RDS
############################################################

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name}-db-subnets"
  }
}

############################################################
# RDS POSTGRESQL
############################################################

resource "aws_db_instance" "postgres" {
  identifier = "${local.name}-postgres"

  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "mmotors"
  username = var.db_username
  password = var.db_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  publicly_accessible = false
  multi_az            = true

  backup_retention_period = 1
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:00-sun:04:00"

  deletion_protection       = false
  delete_automated_backups  = false
  skip_final_snapshot       = true
  final_snapshot_identifier = "m-motors-dev-postgres-final-2"

  auto_minor_version_upgrade = true
  apply_immediately          = true

  tags = {
    Name        = "${local.name}-postgres"
    DataClass   = "Confidential"
    Environment = var.environment
  }
}

############################################################
# RÔLE D’EXÉCUTION ECS
############################################################

resource "aws_iam_role" "ecs_execution" {
  name = "${local.name}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

############################################################
# RÔLE APPLICATIF ECS
############################################################

resource "aws_iam_role" "ecs_task" {
  name = "${local.name}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

############################################################
# POLICY D’ACCÈS AU BUCKET DOCUMENTAIRE
############################################################

resource "aws_iam_role_policy" "documents" {
  name = "${local.name}-documents-access"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid      = "ListDocumentsBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.documents.arn
      },
      {
        Sid    = "ManageDocuments"
        Effect = "Allow"

        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject"
        ]

        Resource = "${aws_s3_bucket.documents.arn}/*"
      }
    ]
  })
}

############################################################
# GROUPE DE LOGS CLOUDWATCH
############################################################

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${local.name}-backend"
  retention_in_days = 30

  tags = {
    Name        = "${local.name}-backend-logs"
    Environment = var.environment
  }
}

############################################################
# CLUSTER ECS
############################################################

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${local.name}-cluster"
  }
}

############################################################
# APPLICATION LOAD BALANCER
############################################################

resource "aws_lb" "backend" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = aws_subnet.public[*].id

  tags = {
    Name = "${local.name}-alb"
  }
}

############################################################
# TARGET GROUP
############################################################

resource "aws_lb_target_group" "backend" {
  name        = "${local.name}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name}-target-group"
  }
}

############################################################
# LISTENER ALB
############################################################

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.backend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

############################################################
# DÉFINITION DE TÂCHE ECS
############################################################

resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.name}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "backend"
      image     = var.backend_image
      essential = true

      command = [
        "python",
        "-m",
        "http.server",
        "8000"
      ]

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "DOCUMENTS_BUCKET"
          value = aws_s3_bucket.documents.bucket
        },
        {
          name  = "DB_HOST"
          value = aws_db_instance.postgres.address
        },
        {
          name  = "DB_PORT"
          value = "5432"
        },
        {
          name  = "DB_NAME"
          value = aws_db_instance.postgres.db_name
        },
        {
          name  = "DB_USER"
          value = var.db_username
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "backend"
        }
      }
    }
  ])

  tags = {
    Name = "${local.name}-backend-task"
  }
}

############################################################
# SERVICE ECS
############################################################

resource "aws_ecs_service" "backend" {
  name            = "${local.name}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn

  desired_count = 2
  launch_type   = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http
  ]

  tags = {
    Name = "${local.name}-backend-service"
  }
}

############################################################
# RÔLE SYSTEMS MANAGER POUR EC2
############################################################

resource "aws_iam_role" "ec2_ssm" {
  name = "${local.name}-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dev" {
  name = "${local.name}-dev"
  role = aws_iam_role.ec2_ssm.name
}

############################################################
# INSTANCE EC2 SPOT DE DÉVELOPPEMENT
############################################################

resource "aws_instance" "dev" {
  ami           = data.aws_ssm_parameter.ubuntu.value
  instance_type = var.dev_instance_type

  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.dev.id]

  iam_instance_profile = aws_iam_instance_profile.dev.name

  associate_public_ip_address = true

  instance_market_options {
    market_type = "spot"

    spot_options {
      spot_instance_type             = "persistent"
      instance_interruption_behavior = "stop"
    }
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20

    tags = {
      Name = "${local.name}-dev-root-volume"
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name        = "${local.name}-dev-spot"
    Purpose     = "Development"
    Environment = var.environment
  }
}

############################################################
# PLANIFICATION EC2
############################################################

resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "scheduler.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${local.name}-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]

        Resource = aws_instance.dev.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "start" {
  name = "${local.name}-start-dev"

  schedule_expression          = "cron(0 8 ? * MON-FRI *)"
  schedule_expression_timezone = "Europe/Paris"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.dev.id]
    })
  }
}

resource "aws_scheduler_schedule" "stop" {
  name = "${local.name}-stop-dev"

  schedule_expression          = "cron(0 20 ? * MON-FRI *)"
  schedule_expression_timezone = "Europe/Paris"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [aws_instance.dev.id]
    })
  }
}

############################################################
# SNS POUR LES ALERTES
############################################################

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"

  tags = {
    Name = "${local.name}-alerts"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

############################################################
# ALARMES HARDWARE
############################################################

locals {
  hardware_alarms = {
    ecs_cpu = {
      namespace   = "AWS/ECS"
      metric      = "CPUUtilization"
      statistic   = "Average"
      operator    = "GreaterThanThreshold"
      threshold   = 80
      evaluations = 2

      dimensions = {
        ClusterName = aws_ecs_cluster.main.name
        ServiceName = aws_ecs_service.backend.name
      }
    }

    ecs_memory = {
      namespace   = "AWS/ECS"
      metric      = "MemoryUtilization"
      statistic   = "Average"
      operator    = "GreaterThanThreshold"
      threshold   = 85
      evaluations = 2

      dimensions = {
        ClusterName = aws_ecs_cluster.main.name
        ServiceName = aws_ecs_service.backend.name
      }
    }

    ec2_cpu = {
      namespace   = "AWS/EC2"
      metric      = "CPUUtilization"
      statistic   = "Average"
      operator    = "GreaterThanThreshold"
      threshold   = 80
      evaluations = 3

      dimensions = {
        InstanceId = aws_instance.dev.id
      }
    }

    ec2_status = {
      namespace   = "AWS/EC2"
      metric      = "StatusCheckFailed"
      statistic   = "Maximum"
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 1
      evaluations = 1

      dimensions = {
        InstanceId = aws_instance.dev.id
      }
    }

    rds_cpu = {
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      statistic   = "Average"
      operator    = "GreaterThanThreshold"
      threshold   = 80
      evaluations = 2

      dimensions = {
        DBInstanceIdentifier = aws_db_instance.postgres.identifier
      }
    }

    rds_storage = {
      namespace   = "AWS/RDS"
      metric      = "FreeStorageSpace"
      statistic   = "Minimum"
      operator    = "LessThanThreshold"
      threshold   = 5368709120
      evaluations = 1

      dimensions = {
        DBInstanceIdentifier = aws_db_instance.postgres.identifier
      }
    }

    rds_memory = {
      namespace   = "AWS/RDS"
      metric      = "FreeableMemory"
      statistic   = "Minimum"
      operator    = "LessThanThreshold"
      threshold   = 268435456
      evaluations = 2

      dimensions = {
        DBInstanceIdentifier = aws_db_instance.postgres.identifier
      }
    }

    alb_unhealthy = {
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      statistic   = "Maximum"
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 1
      evaluations = 1

      dimensions = {
        LoadBalancer = aws_lb.backend.arn_suffix
        TargetGroup  = aws_lb_target_group.backend.arn_suffix
      }
    }

    alb_latency = {
      namespace   = "AWS/ApplicationELB"
      metric      = "TargetResponseTime"
      statistic   = "Average"
      operator    = "GreaterThanThreshold"
      threshold   = 2
      evaluations = 2

      dimensions = {
        LoadBalancer = aws_lb.backend.arn_suffix
        TargetGroup  = aws_lb_target_group.backend.arn_suffix
      }
    }

    alb_5xx = {
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_Target_5XX_Count"
      statistic   = "Sum"
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 5
      evaluations = 1

      dimensions = {
        LoadBalancer = aws_lb.backend.arn_suffix
        TargetGroup  = aws_lb_target_group.backend.arn_suffix
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "hardware" {
  for_each = local.hardware_alarms

  alarm_name        = "${local.name}-${replace(each.key, "_", "-")}"
  alarm_description = "Alarme de surveillance M-Motors pour ${each.key}"

  namespace   = each.value.namespace
  metric_name = each.value.metric
  statistic   = each.value.statistic

  period             = 300
  evaluation_periods = each.value.evaluations

  threshold           = each.value.threshold
  comparison_operator = each.value.operator

  treat_missing_data = "notBreaching"

  dimensions = each.value.dimensions

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  ok_actions = [
    aws_sns_topic.alerts.arn
  ]
}

############################################################
# FINOPS : ALARME DE SOUS-UTILISATION EC2
############################################################

resource "aws_cloudwatch_metric_alarm" "ec2_underutilized" {
  alarm_name        = "${local.name}-ec2-underutilized"
  alarm_description = "EC2 utilise moins de 5 % de CPU pendant trois heures"

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"

  period             = 3600
  evaluation_periods = 3

  threshold           = 5
  comparison_operator = "LessThanThreshold"

  treat_missing_data = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.dev.id
  }

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  ok_actions = [
    aws_sns_topic.alerts.arn
  ]
}

############################################################
# MÉTRIQUES APPLICATIVES EXTRAITES DES LOGS
############################################################

locals {
  application_log_metrics = {
    backend_errors = {
      pattern   = "ERROR"
      namespace = "M-Motors/Application"
      metric    = "BackendErrorCount"
      threshold = 5
    }

    database_errors = {
      pattern   = "DatabaseError"
      namespace = "M-Motors/Application"
      metric    = "DatabaseErrorCount"
      threshold = 1
    }

    document_errors = {
      pattern   = "DocumentUploadError"
      namespace = "M-Motors/CriticalPath"
      metric    = "DocumentUploadErrorCount"
      threshold = 1
    }

    dossier_errors = {
      pattern   = "DossierCreationError"
      namespace = "M-Motors/CriticalPath"
      metric    = "DossierCreationErrorCount"
      threshold = 1
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "application" {
  for_each = local.application_log_metrics

  name           = "${local.name}-${replace(each.key, "_", "-")}"
  log_group_name = aws_cloudwatch_log_group.backend.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric
    namespace     = each.value.namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "application" {
  for_each = local.application_log_metrics

  alarm_name        = "${local.name}-${replace(each.key, "_", "-")}"
  alarm_description = "Alarme applicative M-Motors pour ${each.key}"

  namespace   = each.value.namespace
  metric_name = each.value.metric
  statistic   = "Sum"

  period             = 300
  evaluation_periods = 1

  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  ok_actions = [
    aws_sns_topic.alerts.arn
  ]
}

############################################################
# MATRICE HARDWARE 1
# CALCUL ECS ET EC2
############################################################

resource "aws_cloudwatch_dashboard" "hardware_compute" {
  dashboard_name = "${local.name}-01-hardware-compute"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "ECS CPU et mémoire"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          stat   = "Average"

          metrics = [
            [
              "AWS/ECS",
              "CPUUtilization",
              "ClusterName",
              aws_ecs_cluster.main.name,
              "ServiceName",
              aws_ecs_service.backend.name
            ],
            [
              ".",
              "MemoryUtilization",
              ".",
              ".",
              ".",
              "."
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "EC2 CPU et contrôle d'état"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          stat   = "Average"

          metrics = [
            [
              "AWS/EC2",
              "CPUUtilization",
              "InstanceId",
              aws_instance.dev.id
            ],
            [
              ".",
              "StatusCheckFailed",
              ".",
              "."
            ]
          ]
        }
      }
    ]
  })
}

############################################################
# MATRICE HARDWARE 2
# STOCKAGE RDS ET RÉSEAU ALB
############################################################

resource "aws_cloudwatch_dashboard" "hardware_storage" {
  dashboard_name = "${local.name}-02-hardware-storage-network"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "RDS CPU, stockage et mémoire"
          region = var.aws_region
          view   = "timeSeries"
          period = 300

          metrics = [
            [
              "AWS/RDS",
              "CPUUtilization",
              "DBInstanceIdentifier",
              aws_db_instance.postgres.identifier
            ],
            [
              ".",
              "FreeStorageSpace",
              ".",
              "."
            ],
            [
              ".",
              "FreeableMemory",
              ".",
              "."
            ],
            [
              ".",
              "DatabaseConnections",
              ".",
              "."
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "ALB santé et latence"
          region = var.aws_region
          view   = "timeSeries"
          period = 300

          metrics = [
            [
              "AWS/ApplicationELB",
              "UnHealthyHostCount",
              "LoadBalancer",
              aws_lb.backend.arn_suffix,
              "TargetGroup",
              aws_lb_target_group.backend.arn_suffix
            ],
            [
              ".",
              "HealthyHostCount",
              ".",
              ".",
              ".",
              "."
            ],
            [
              ".",
              "TargetResponseTime",
              ".",
              ".",
              ".",
              "."
            ]
          ]
        }
      }
    ]
  })
}

############################################################
# MATRICE APPLICATIVE 1
# ERREURS APPLICATIVES
############################################################

resource "aws_cloudwatch_dashboard" "application_errors" {
  dashboard_name = "${local.name}-03-application-errors"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 8

        properties = {
          title  = "Erreurs du backend et de PostgreSQL"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          stat   = "Sum"

          metrics = [
            [
              "M-Motors/Application",
              "BackendErrorCount"
            ],
            [
              ".",
              "DatabaseErrorCount"
            ]
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 8
        width  = 24
        height = 8

        properties = {
          title  = "Dernières erreurs applicatives"
          region = var.aws_region

          query = <<-QUERY
            SOURCE '${aws_cloudwatch_log_group.backend.name}'
            | fields @timestamp, @message, @logStream
            | filter @message like /ERROR|DatabaseError|Traceback/
            | sort @timestamp desc
            | limit 50
          QUERY
        }
      }
    ]
  })
}

############################################################
# MATRICE APPLICATIVE 2
# CHEMIN CRITIQUE DOSSIERS ET DOCUMENTS
############################################################

resource "aws_cloudwatch_dashboard" "critical_path" {
  dashboard_name = "${local.name}-04-critical-path"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "Erreurs de création de dossiers et dépôt documentaire"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          stat   = "Sum"

          metrics = [
            [
              "M-Motors/CriticalPath",
              "DossierCreationErrorCount"
            ],
            [
              ".",
              "DocumentUploadErrorCount"
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "API HTTP 5xx et latence"
          region = var.aws_region
          view   = "timeSeries"
          period = 300

          metrics = [
            [
              "AWS/ApplicationELB",
              "HTTPCode_Target_5XX_Count",
              "LoadBalancer",
              aws_lb.backend.arn_suffix,
              "TargetGroup",
              aws_lb_target_group.backend.arn_suffix
            ],
            [
              ".",
              "TargetResponseTime",
              ".",
              ".",
              ".",
              "."
            ]
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 8

        properties = {
          title  = "Logs du chemin critique"
          region = var.aws_region

          query = <<-QUERY
            SOURCE '${aws_cloudwatch_log_group.backend.name}'
            | fields @timestamp, @message
            | filter @message like /DossierCreationError|DocumentUploadError/
            | sort @timestamp desc
            | limit 50
          QUERY
        }
      }
    ]
  })
}

############################################################
# MATRICE FINOPS 1
# UTILISATION ET RIGHTSIZING
############################################################

resource "aws_cloudwatch_dashboard" "finops_utilization" {
  dashboard_name = "${local.name}-05-finops-utilization"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6

        properties = {
          title  = "Utilisation CPU ECS"
          region = var.aws_region
          view   = "timeSeries"
          period = 3600
          stat   = "Average"

          metrics = [
            [
              "AWS/ECS",
              "CPUUtilization",
              "ClusterName",
              aws_ecs_cluster.main.name,
              "ServiceName",
              aws_ecs_service.backend.name
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6

        properties = {
          title  = "Utilisation CPU EC2"
          region = var.aws_region
          view   = "timeSeries"
          period = 3600
          stat   = "Average"

          metrics = [
            [
              "AWS/EC2",
              "CPUUtilization",
              "InstanceId",
              aws_instance.dev.id
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6

        properties = {
          title  = "Utilisation CPU RDS"
          region = var.aws_region
          view   = "timeSeries"
          period = 3600
          stat   = "Average"

          metrics = [
            [
              "AWS/RDS",
              "CPUUtilization",
              "DBInstanceIdentifier",
              aws_db_instance.postgres.identifier
            ]
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 6
        width  = 24
        height = 5

        properties = {
          markdown = <<-MARKDOWN
            # Recommandations FinOps

            - Vérifier ECS lorsque le CPU moyen reste inférieur à 20 %.
            - Vérifier EC2 lorsque le CPU moyen reste inférieur à 5 %.
            - Vérifier RDS lorsque le CPU moyen reste inférieur à 15 %.
            - Confirmer l'arrêt d'EC2 entre 20h et 08h.
            - Contrôler régulièrement le dimensionnement des tâches Fargate.
          MARKDOWN
        }
      }
    ]
  })
}

############################################################
# MATRICE FINOPS 2
# GOUVERNANCE DES COÛTS
############################################################

resource "aws_cloudwatch_dashboard" "finops_governance" {
  dashboard_name = "${local.name}-06-finops-governance"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 8

        properties = {
          markdown = <<-MARKDOWN
            # Gouvernance FinOps M-Motors

            **Budget mensuel :** $${var.monthly_budget_usd}

            ## Alertes budgétaires

            - Alerte lorsque la dépense réelle atteint 80 % du budget.
            - Alerte lorsque la prévision atteint 100 % du budget.
            - Alerte lorsqu'une anomalie de coût atteint 10 USD.

            ## Optimisations intégrées

            - Instance EC2 Spot.
            - Arrêt automatique de la VM à 20h.
            - Démarrage automatique de la VM à 08h en semaine.
            - VM arrêtée pendant le week-end.
            - Lifecycle S3 pour les anciennes versions.
            - Autoscaling du stockage PostgreSQL.
            - Rétention CloudWatch limitée à 30 jours.
          MARKDOWN
        }
      }
    ]
  })
}

############################################################
# BUDGET AWS
############################################################

resource "aws_budgets_budget" "monthly" {
  name = "${local.name}-monthly-budget"

  budget_type = "COST"

  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  time_unit = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"

    values = [
      "user:Project$M-Motors"
    ]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 80
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"

    subscriber_email_addresses = [
      var.alert_email
    ]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 100
    threshold_type      = "PERCENTAGE"
    notification_type   = "FORECASTED"

    subscriber_email_addresses = [
      var.alert_email
    ]
  }
}



############################################################
# OUTPUTS
############################################################

output "frontend_url" {
  description = "URL du site statique S3"
  value       = aws_s3_bucket_website_configuration.frontend.website_endpoint
}

output "frontend_bucket_name" {
  description = "Nom du bucket frontend"
  value       = aws_s3_bucket.frontend.bucket
}

output "backend_url" {
  description = "URL du Load Balancer du backend"
  value       = "http://${aws_lb.backend.dns_name}"
}

output "documents_bucket" {
  description = "Nom du bucket documentaire privé"
  value       = aws_s3_bucket.documents.bucket
}

output "postgres_endpoint" {
  description = "Endpoint PostgreSQL"
  value       = aws_db_instance.postgres.address
}

output "dev_instance_id" {
  description = "Identifiant de la VM de développement"
  value       = aws_instance.dev.id
}

output "alert_topic_arn" {
  description = "ARN du topic SNS d'alerting"
  value       = aws_sns_topic.alerts.arn
}

output "bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "dashboards" {
  description = "Liste des matrices CloudWatch"

  value = [
    aws_cloudwatch_dashboard.hardware_compute.dashboard_name,
    aws_cloudwatch_dashboard.hardware_storage.dashboard_name,
    aws_cloudwatch_dashboard.application_errors.dashboard_name,
    aws_cloudwatch_dashboard.critical_path.dashboard_name,
    aws_cloudwatch_dashboard.finops_utilization.dashboard_name,
    aws_cloudwatch_dashboard.finops_governance.dashboard_name
  ]
}
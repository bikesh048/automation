# Provider configuration
provider "aws" {
  region = "us-east-1"
}

# Variables
variable "app_name" {
  description = "Name of the application"
  default     = "rise-app"
}

variable "container_port" {
  description = "Port exposed by the container"
  default     = 3000
}

variable "cicd_provider" {
  description = "CI/CD provider to use (codepipeline, github_actions, circleci, etc.)"
  default     = "codepipeline"
}

variable "github_repo" {
  description = "GitHub repository URL"
  default     = "bikesh048/automation"
}

variable "github_branch" {
  description = "GitHub branch to monitor"
  default     = "main"
}

variable "codestar_connection_arn" {
  description = "ARN of the CodeStar Connections connection"
  default = "arn:aws:codeconnections:us-east-1:780147879176:connection/4b64ab72-a1fa-4604-a5dd-e1880c46015b"
}


# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.app_name}-vpc"
  }
}

# Subnets
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.app_name}-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.app_name}-public-b"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.app_name}-igw"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.app_name}-public-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# ECR Repository
resource "aws_ecr_repository" "app" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# IAM Roles for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.app_name}-task-execution-role"

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

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"
}

# Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = var.app_name
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.app_name}"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# Security Group for ECS Service
resource "aws_security_group" "ecs_service" {
  name        = "${var.app_name}-ecs-service-sg"
  description = "Security group for ECS service"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 30
}

# ECS Service
resource "aws_ecs_service" "app" {
  name            = var.app_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.app]
  
  # Allowing External Deployment
  lifecycle {
    ignore_changes = [task_definition]
  }
}

# Application Load Balancer
resource "aws_lb" "app" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Target Group
resource "aws_lb_target_group" "app" {
  name        = "${var.app_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/"
    protocol            = "HTTP"
  }
}

# Listener
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# AWS Account ID
data "aws_caller_identity" "current" {}


# remove
# AWS Connections
resource "aws_codestarconnections_connection" "github" {
  count         = var.cicd_provider == "codepipeline" ? 1 : 0
  name          = "${var.app_name}-github-connection"
  provider_type = "GitHub"
}

# remove
output "codestar_connection_arn" {
  value = "arn:aws:codeconnections:us-east-1:780147879176:connection/4b64ab72-a1fa-4604-a5dd-e1880c46015b"
  description = "ARN of the CodeStar Connections connection"
}

# CI/CD components based on provider choice
# CodePipeline Module (conditionally created)
module "codepipeline" {
  source       = "./modules"
  count        = var.cicd_provider == "codepipeline" ? 1 : 0
  
  app_name     = var.app_name
  ecr_repo_url = aws_ecr_repository.app.repository_url
  ecr_repo_name = aws_ecr_repository.app.name
  ecs_cluster_name = aws_ecs_cluster.main.name
  ecs_service_name = aws_ecs_service.app.name
  github_repo  = var.github_repo
  github_branch = var.github_branch
  connection_arn = var.codestar_connection_arn
}

# Create IAM User for external CI/CD if not using CodePipeline
resource "aws_iam_user" "cicd_user" {
  count = var.cicd_provider != "codepipeline" ? 1 : 0
  name  = "${var.app_name}-cicd-user"
}

resource "aws_iam_access_key" "cicd_user_key" {
  count = var.cicd_provider != "codepipeline" ? 1 : 0
  user  = aws_iam_user.cicd_user[0].name
}

resource "aws_iam_user_policy" "cicd_user_policy" {
  count  = var.cicd_provider != "codepipeline" ? 1 : 0
  name   = "${var.app_name}-cicd-policy"
  user   = aws_iam_user.cicd_user[0].name
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = aws_iam_role.ecs_task_execution_role.arn
      }
    ]
  })
}

# Outputs
output "alb_dns_name" {
  value       = aws_lb.app.dns_name
  description = "The DNS name of the load balancer"
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.app.repository_url
  description = "The URL of the ECR repository"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "The name of the ECS cluster"
}

output "ecs_service_name" {
  value       = aws_ecs_service.app.name
  description = "The name of the ECS service"
}

output "ci_user_access_key" {
  value       = var.cicd_provider != "codepipeline" ? aws_iam_access_key.cicd_user_key[0].id : "Not applicable - using CodePipeline"
  description = "Access key for CI/CD user"
  sensitive   = true
}

output "ci_user_secret_key" {
  value       = var.cicd_provider != "codepipeline" ? aws_iam_access_key.cicd_user_key[0].secret : "Not applicable - using CodePipeline"
  description = "Secret key for CI/CD user"
  sensitive   = true
}

output "github_connection_status" {
  value       = var.cicd_provider == "codepipeline" ? "GitHub connection created. Please complete the connection setup in the AWS console." : "Not applicable - using external CI/CD"
  description = "Instructions for GitHub connection setup for CodePipeline"
}
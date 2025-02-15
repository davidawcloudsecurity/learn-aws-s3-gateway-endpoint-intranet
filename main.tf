provider "aws" {
  region = var.region
}

variable "region" {
  description = "The region for the account"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr_block" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "192.168.0.0/16"
}

variable "public_subnet_cidr_block" {
  description = "The CIDR block for the subnet"
  type        = string
  default     = "192.168.1.0/24"
}

variable "tags" {
  description = "A map of tags to assign to the resources"
  type        = map(string)
  default = {
    Environment = "dev"
    Project     = "s3-gateway-endpoint"
  }
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr_block

  tags = merge(var.tags, {
    Name = "vpc-${var.tags["Environment"]}"
  })
}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = var.public_subnet_cidr_block

  tags = merge(var.tags, {
    Name = "subnet-${var.tags["Environment"]}"
  })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.region}.s3"
  route_table_ids = [aws_route_table.rt.id] # This is where the association happens

  tags = var.tags

  depends_on = [aws_vpc.main] # Ensure VPC is created before the endpoint
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  tags = var.tags
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.rt.id

  depends_on = [aws_route_table.rt] # Ensure the route table is created before association
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "static_website" {
  bucket = "static-website-${var.tags["Environment"]}-${random_id.bucket_suffix.hex}"
  acl    = "private"

  tags = var.tags
}

resource "aws_s3_bucket_website_configuration" "static_website_configuration" {
  bucket = aws_s3_bucket.static_website.bucket

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

output "s3_bucket_name" {
  value       = aws_s3_bucket.static_website.bucket
  description = "The name of the S3 static website bucket"
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "The ID of the VPC"
}

output "subnet_id" {
  value       = aws_subnet.main.id
  description = "The ID of the main subnet"
}

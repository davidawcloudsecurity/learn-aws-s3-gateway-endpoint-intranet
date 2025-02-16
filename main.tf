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
  default     = {
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

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.region}.s3"
  route_table_ids   = [aws_route_table.rt.id] # This is where the association happens

  tags = var.tags

  depends_on = [aws_vpc.main]  # Ensure VPC is created before the endpoint
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  tags = var.tags
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.rt.id

  depends_on = [aws_route_table.rt]  # Ensure the route table is created before association
}

# Create an IAM instance profile with the specified role
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_instance_profile"
  role = "AmazonSSMManagedInstanceCore"
}

# EC2 Instance
resource "aws_instance" "windows_ec2" {
  ami           = "ami-001adaa5c3ee02e10" # Windows AMI
  instance_type = "t2.micro" # You might want to adjust this based on your needs
  subnet_id     = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  tags = merge(var.tags, {
    Name = "Windows-EC2-${var.tags["Environment"]}"
  })
}

# Security Group for EC2 Instance
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-security-group-${var.tags["Environment"]}"
  description = "Security group for EC2 instance accessing S3 static website"
  vpc_id      = aws_vpc.main.id
  tags = var.tags

  # Inbound Rules
  # Since you only want to see the static website, we won't open any inbound ports here
  # unless you need RDP for management. Here's an example for RDP if needed:
  /*
  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Be cautious with this! Limit to your IP or a secure range.
  }
  */
  # Outbound Rules
  # Allow all outbound traffic to access the S3 service
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

# S3 Bucket Policy to allow access via VPC Endpoint
resource "aws_s3_bucket_policy" "allow_vpce_access" {
  bucket = aws_s3_bucket.static_website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowVPCEAccess"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = [
          "${aws_s3_bucket.static_website.arn}/*",
        ]
        Condition = {
          StringEquals = {
            "aws:sourceVpce" = aws_vpc_endpoint.s3.id
          }
        }
      },
    ]
  })
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "static_website" {
  bucket = "static-website-${var.tags["Environment"]}-${random_id.bucket_suffix.hex}"

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "example" {
  bucket = aws_s3_bucket.static_website.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "example" {
  bucket = aws_s3_bucket.static_website.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_acl" "example" {
  depends_on = [
    aws_s3_bucket_ownership_controls.example,
    aws_s3_bucket_public_access_block.example,
  ]

  bucket = aws_s3_bucket.static_website.id
  acl    = "private"
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

# Upload index.html
resource "aws_s3_object" "index" {
  bucket = aws_s3_bucket.static_website.id
  key    = "index.html"
  source = "./index.html" # Ensure this path is correct relative to where you run `terraform apply`
  content_type = "text/html"
}

# Upload error.html
resource "aws_s3_object" "error" {
  bucket = aws_s3_bucket.static_website.id
  key    = "error.html"
  source = "./error.html" # Ensure this path is correct
  content_type = "text/html"
}

# Upload folder with PNG files
# Here we assume you have PNG files in a folder named 'images' 
# and we'll use a wildcard to upload all PNG files in that folder
resource "aws_s3_object" "image_folder" {
  for_each = fileset("path/to/your/images/", "*.png") # Adjust this path
  bucket   = aws_s3_bucket.static_website.id
  key      = "assets/${each.value}"
  source   = "assets/${each.value}"
  content_type = "image/png"
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

output "ec2_instance_id" {
  value       = aws_instance.windows_ec2.id
  description = "The ID of the EC2 instance"
}

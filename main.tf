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
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "vpc-${var.tags["Environment"]}"
  })
}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = var.public_subnet_cidr_block
  availability_zone = "${var.region}b"  # Example: If your first subnet is in us-east-1b, use us-east-1a here. Adjust based on your existing subnet's AZ.

  tags = merge(var.tags, {
    Name = "subnet-${var.tags["Environment"]}"
  })
}

# Assuming your existing subnet is in one AZ, let's create another in a different AZ.
resource "aws_subnet" "second_subnet" {
  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr_block, 8, 2)  # Example: This creates 192.168.2.0/24 if var.vpc_cidr_block is 192.168.0.0/16
  availability_zone = "${var.region}a"  # Example: If your first subnet is in us-east-1b, use us-east-1a here. Adjust based on your existing subnet's AZ.

  tags = merge(var.tags, {
    Name = "second-subnet-${var.tags["Environment"]}"
  })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}
/* Remove s3 gateway endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.region}.s3"
  route_table_ids   = [aws_route_table.rt.id] # This is where the association happens

  tags = var.tags

  depends_on = [aws_vpc.main]  # Ensure VPC is created before the endpoint
}
*/
resource "aws_vpc_endpoint" "s3_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = false
  subnet_ids          = [aws_subnet.main.id, aws_subnet.second_subnet.id]  # Use both subnets for high availability
  security_group_ids  = [aws_security_group.ec2_sg.id]  # Or create a new one specific for this endpoint if needed

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

# Since the route table association needs to be updated for this new subnet:
resource "aws_route_table_association" "second_subnet_association" {
  subnet_id      = aws_subnet.second_subnet.id
  route_table_id = aws_route_table.rt.id
}

data "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_instance_profile"
}

# Create an IAM instance profile with the specified role
resource "aws_iam_instance_profile" "ec2_profile" {
  count = data.aws_iam_instance_profile.ec2_profile.arn == "" ? 1 : 0
  name = "ec2_instance_profile"
  role = "AmazonSSMManagedInstanceCore"
}

# EC2 Instance
resource "aws_instance" "windows_ec2" {
  ami           = "ami-001adaa5c3ee02e10" # Windows AMI
  instance_type = "t2.micro" # You might want to adjust this based on your needs
  subnet_id     = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = length(aws_iam_instance_profile.ec2_profile) > 0 ? aws_iam_instance_profile.ec2_profile[0].name : data.aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true  # This ensures the instance gets a public IP

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

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
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Be cautious with this! Limit to your IP or a secure range.
  }
  
  # Outbound Rules
  # Allow all outbound traffic to access the S3 service

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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
          "${aws_s3_bucket.static_website.arn}"
        ]
        Condition = {
          StringEquals = {
            "aws:sourceVpce" = aws_vpc_endpoint.s3_interface.id
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

# Update the ALB to use both subnets
resource "aws_lb" "alb" {
  name               = "my-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = [aws_subnet.main.id, aws_subnet.second_subnet.id]
  security_groups = [aws_security_group.ec2_sg.id]

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Default HTTP Response"
      status_code  = "200"
    }
  }
}

resource "aws_lb_target_group" "tg" {
  name     = "my-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 6
    interval            = 30
    matcher             = "307,405"  # Check for these status codes
  }
}

resource "aws_lb_listener_rule" "trailing_slash_redirect" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type = "redirect"

    redirect {
      protocol = "HTTP"
      port     = "#{port}"
      host     = "#{host}"
      path     = "/#{path}index.html"
      status_code = "HTTP_301"
    }
  }

  condition {
    path_pattern {
      values = ["*/"]
    }
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

output "ec2_instance_id" {
  value       = aws_instance.windows_ec2.id
  description = "The ID of the EC2 instance"
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  # Make this variable
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-gateway"
  }
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "main-route-table"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"

  tags = {
    Name = "main-subnet"
  }
}

resource "aws_s3_bucket" "static_website" {
  bucket = "my-static-website-bucket"
  acl    = "private"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }

  tags = {
    Name = "static-website-bucket"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.us-east-1.s3"

  route_table_ids = [aws_route_table.rt.id]

  tags = {
    Name = "s3-gateway-endpoint"
  }
}

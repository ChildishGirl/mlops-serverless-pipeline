#############################################################
# Parameters
#############################################################
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "region-name"
    values = [data.aws_region.current.name]
  }
}

#############################################################
# Create VPC with S3 gateway endpoint
#############################################################
resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_hostnames = true
  tags                 = { Name = "ml-vpc" }
}
resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id            = aws_vpc.vpc.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.rt_private.id]
  tags              = { Name = "ml-s3-endpoint" }
}
resource "aws_vpc_endpoint_route_table_association" "s3_endpoint" {
  route_table_id  = aws_route_table.rt_private.id
  vpc_endpoint_id = aws_vpc_endpoint.s3_endpoint.id
}

#############################################################
# Create public subnet with NAT instance
#############################################################
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.0.0/20"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "ml-subnet-public" }
}
resource "aws_route_table" "rt_public" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gw.id
  }
  tags = { Name = "ml-rt-public" }
}
resource "aws_route_table_association" "rt_public_association" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.rt_public.id
}
resource "aws_internet_gateway" "internet_gw" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "ml-igw" }
}
resource "aws_instance" "nat_instance" {
  ami                         = "ami-0ef3356cec8dfc09d"
  source_dest_check           = false
  associate_public_ip_address = true
  instance_type               = "t2.micro"
  iam_instance_profile        = aws_iam_instance_profile.ec2_ssm_profile.name
  vpc_security_group_ids      = [aws_security_group.nat_sg.id]
  subnet_id                   = aws_subnet.public.id
  tags                        = { Name = "ml-nat-instance" }
}
resource "aws_security_group" "nat_sg" {
  name        = "ml-nat-sg"
  description = "Security group for NAT instance"
  vpc_id      = aws_vpc.vpc.id
  ingress {
    description = "Ingress from VPC CIDR."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.vpc.cidr_block]
  }
  egress {
    description = "Default egress."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "ec2_ssm_role" {
  name                = "core-nat-instance-role"
  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
  assume_role_policy  = data.aws_iam_policy_document.ml_event_bridge_policy_trust.json
}
resource "aws_iam_instance_profile" "ec2_ssm_profile" { role = aws_iam_role.ec2_ssm_role.name }
data "aws_iam_policy_document" "ml_event_bridge_policy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

#############################################################
# Create private subnets
#############################################################
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.128.0/20"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "ml-subnet-private" }
}
resource "aws_route_table" "rt_private" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat_instance.primary_network_interface_id
  }
  tags = { Name = "ml-rt-private" }
}
resource "aws_route_table_association" "rt_private_association" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.rt_private.id
}
resource "aws_subnet" "private2" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.144.0/20"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "ml-subnet-private2" }
}
resource "aws_route_table_association" "rt_private_association2" {
  subnet_id      = aws_subnet.private2.id
  route_table_id = aws_route_table.rt_private.id
}

#############################################################
# Output variables
#############################################################
output "vpc_id" { value = aws_vpc.vpc.id }
output "cidr_vpc" { value = aws_vpc.vpc.cidr_block }
output "subnet_private_id" { value = aws_subnet.private.id }
output "subnet_private_az" { value = aws_subnet.private.availability_zone }
output "subnet_public_id" { value = aws_subnet.public.id }
output "subnet_private2_id" { value = aws_subnet.private2.id }



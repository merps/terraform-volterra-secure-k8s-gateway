provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.aws_region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

resource "aws_vpc" "this" {
  cidr_block                       = var.aws_vpc_cidr
  assign_generated_ipv6_cidr_block = false
  enable_dns_support               = true
  enable_dns_hostnames             = true
  tags = {
    "Name"                                           = var.skg_name
    "usecase"                                        = "secure-k8s-gateway"
    format("kubernetes.io/cluster/%s", var.skg_name) = "shared"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    "Name"    = var.skg_name
    "usecase" = "secure-k8s-gateway"
  }
}

resource "aws_route" "ipv6_default" {
  route_table_id              = aws_vpc.this.main_route_table_id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this.id
  lifecycle {
    ignore_changes = [
      route_table_id
    ]
  }
}

resource "aws_route" "ipv4_default" {
  route_table_id         = aws_vpc.this.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
  lifecycle {
    ignore_changes = [
      route_table_id
    ]
  }
}


resource "aws_subnet" "volterra_ce" {
  for_each          = var.aws_subnet_ce_cidr
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = var.aws_az
  tags = {
    "Name"        = format("%s-%s", var.skg_name, each.key)
    "usecase"     = "secure-k8s-gateway"
    "subnet-type" = each.key
  }
}


resource "aws_subnet" "eks" {
  depends_on        = [volterra_tf_params_action.apply_aws_vpc]
  for_each          = var.aws_subnet_eks_cidr
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key
  tags = {
    "Name"                                           = format("%s-%s", var.skg_name, each.key)
    "usecase"                                        = "secure-k8s-gateway"
    format("kubernetes.io/cluster/%s", var.skg_name) = "shared"
  }
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = var.skg_name
  cluster_version = "1.18"
  subnets         = local.eks_subnets

  tags = {
    Environment = "prod"
    usecase     = "secure-k8s-gateway"
  }

  vpc_id = aws_vpc.this.id

  node_groups_defaults = {
    ami_type  = "AL2_x86_64"
    disk_size = 50
  }

  config_output_path = var.kubeconfig_output_path
  write_kubeconfig   = true
  create_eks         = true

  kubeconfig_aws_authenticator_env_variables = {
    "AWS_ACCESS_KEY_ID"     = var.aws_access_key
    "AWS_SECRET_ACCESS_KEY" = var.aws_secret_key
  }

  node_groups = {
    example = {
      desired_capacity = 1
      max_capacity     = 10
      min_capacity     = 1

      instance_type = "m5.xlarge"
      k8s_labels = {
        Environment = "prod"
        usecase     = "secure-k8s-gateway"
      }
    }
  }
}

provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1alpha1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
    }
  }
}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"

  tags = {
    Blueprint  = local.name
    GithubRepo = "terraform-aws-eks-blueprints"
  }
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "../../.."

  cluster_name    = local.name
  cluster_version = "1.21"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  managed_node_groups = {
    mg_4 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["m5.large"]
      subnet_ids      = module.vpc.private_subnets
    }
  }

  self_managed_node_groups = {
    self_mg_4 = {
      node_group_name    = "self-managed-ondemand"
      instance_types     = ["m4.large"]
      launch_template_os = "amazonlinux2eks"       # amazonlinux2eks  or bottlerocket or windows
      custom_ami_id      = "ami-0dfaa019a300f219c" # Bring your own custom AMI generated by Packer/ImageBuilder/Puppet etc.
      subnet_ids         = module.vpc.private_subnets
    }
  }

  fargate_profiles = {
    default = {
      fargate_profile_name = "default"
      fargate_profile_namespaces = [
        {
          namespace = "default"
          k8s_labels = {
            Environment = "preprod"
            Zone        = "dev"
            env         = "fargate"
          }
      }]
      subnet_ids = local.private_subnet_ids
      additional_tags = {
        ExtraTag = "Fargate"
      }
    }
  }

  enable_amazon_prometheus = true

  enable_emr_on_eks = true
  emr_on_eks_teams = {
    data_team_a = {
      emr_on_eks_namespace     = "emr-data-team-a"
      emr_on_eks_iam_role_name = "emr-eks-data-team-a"
    }

    data_team_b = {
      emr_on_eks_namespace     = "emr-data-team-b"
      emr_on_eks_iam_role_name = "emr-eks-data-team-b"
    }
  }

  tags = local.tags
}

module "eks_blueprints_kubernetes_addons" {
  source = "../../modules/kubernetes-addons"

  eks_cluster_id               = module.eks_blueprints.eks_cluster_id
  eks_worker_security_group_id = module.eks_blueprints.worker_node_security_group_id
  auto_scaling_group_names     = module.eks_blueprints.self_managed_node_group_autoscaling_groups

  # EKS Addons
  enable_amazon_eks_vpc_cni = true
  amazon_eks_vpc_cni_config = {
    addon_name               = "vpc-cni"
    addon_version            = "v1.10.1-eksbuild.1"
    service_account          = "aws-node"
    resolve_conflicts        = "OVERWRITE"
    namespace                = "kube-system"
    additional_iam_policies  = []
    service_account_role_arn = ""
    tags                     = local.tags
  }

  enable_amazon_eks_coredns = true
  amazon_eks_coredns_config = {
    addon_name               = "coredns"
    addon_version            = "v1.8.4-eksbuild.1"
    service_account          = "coredns"
    resolve_conflicts        = "OVERWRITE"
    namespace                = "kube-system"
    service_account_role_arn = ""
    additional_iam_policies  = []
    tags                     = local.tags
  }

  enable_amazon_eks_kube_proxy = true
  amazon_eks_kube_proxy_config = {
    addon_name               = "kube-proxy"
    addon_version            = "v1.21.2-eksbuild.2"
    service_account          = "kube-proxy"
    resolve_conflicts        = "OVERWRITE"
    namespace                = "kube-system"
    additional_iam_policies  = []
    service_account_role_arn = ""
    tags                     = local.tags
  }

  enable_amazon_eks_aws_ebs_csi_driver = true
  amazon_eks_aws_ebs_csi_driver_config = {
    addon_name               = "aws-ebs-csi-driver"
    addon_version            = "v1.4.0-eksbuild.preview"
    service_account          = "ebs-csi-controller-sa"
    resolve_conflicts        = "OVERWRITE"
    namespace                = "kube-system"
    additional_iam_policies  = []
    service_account_role_arn = ""
    tags                     = local.tags
  }

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller_helm_config = {
    name       = "aws-load-balancer-controller"
    chart      = "aws-load-balancer-controller"
    repository = "https://aws.github.io/eks-charts"
    version    = "1.3.1"
    namespace  = "kube-system"
  }

  enable_aws_node_termination_handler = true
  aws_node_termination_handler_helm_config = {
    name       = "aws-node-termination-handler"
    chart      = "aws-node-termination-handler"
    repository = "https://aws.github.io/eks-charts"
    version    = "0.16.0"
    timeout    = "1200"
  }

  enable_traefik = true
  traefik_helm_config = {
    name       = "traefik"
    repository = "https://helm.traefik.io/traefik"
    chart      = "traefik"
    version    = "10.0.0"
    namespace  = "kube-system"
    timeout    = "1200"
    lint       = "true"

    set = [{
      name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
      value = "nlb"
    }]

    values = [templatefile("${path.module}/helm_values/traefik-values.yaml", {
      operating_system = "linux"
    })]
  }

  enable_metrics_server = true
  metrics_server_helm_config = {
    name       = "metrics-server"
    repository = "https://kubernetes-sigs.github.io/metrics-server/"
    chart      = "metrics-server"
    version    = "3.8.1"
    namespace  = "kube-system"
    timeout    = "1200"
    lint       = "true"

    values = [templatefile("${path.module}/helm_values/metrics-server-values.yaml", {
      operating_system = "linux"
    })]
  }

  enable_cluster_autoscaler = true
  cluster_autoscaler_helm_config = {
    name       = "cluster-autoscaler"
    repository = "https://kubernetes.github.io/autoscaler"
    chart      = "cluster-autoscaler"
    version    = "9.10.7"
    namespace  = "kube-system"
    timeout    = "1200"
    lint       = "true"

    values = [templatefile("${path.module}/helm_values/cluster-autoscaler-vaues.yaml", {
      operating_system = "linux"
    })]
  }

  # Amazon Prometheus Configuration to integrate with Prometheus Server Add-on
  enable_amazon_prometheus             = true
  amazon_prometheus_workspace_endpoint = module.eks_blueprints.amazon_prometheus_workspace_endpoint

  enable_prometheus = true
  prometheus_helm_config = {
    name       = "prometheus"
    repository = "https://prometheus-community.github.io/helm-charts"
    chart      = "prometheus"
    version    = "15.3.0"
    namespace  = "prometheus"

    values = [templatefile("${path.module}/helm_values/prometheus-values.yaml", {
      operating_system = "linux"
    })]
  }

  enable_ingress_nginx = true
  ingress_nginx_helm_config = {
    name       = "ingress-nginx"
    chart      = "ingress-nginx"
    repository = "https://kubernetes.github.io/ingress-nginx"
    version    = "3.33.0"
    namespace  = "kube-system"
    values     = [templatefile("${path.module}/helm_values/nginx_values.yaml", {})]
  }

  # NOTE: Agones requires a Node group in Public Subnets and enable Public IP
  enable_agones = true
  agones_helm_config = {
    name               = "agones"
    chart              = "agones"
    repository         = "https://agones.dev/chart/stable"
    version            = "1.15.0"
    namespace          = "kube-system"
    gameserver_minport = 7000
    gameserver_maxport = 8000

    values = [templatefile("${path.module}/helm_values/agones-values.yaml", {
      expose_udp            = true
      gameserver_namespaces = "{${join(",", ["default", "xbox-gameservers", "xbox-gameservers"])}}"
      gameserver_minport    = 7000
      gameserver_maxport    = 8000
    })]
  }

  enable_aws_for_fluentbit = true
  aws_for_fluentbit_helm_config = {
    name                                      = "aws-for-fluent-bit"
    chart                                     = "aws-for-fluent-bit"
    repository                                = "https://aws.github.io/eks-charts"
    version                                   = "0.1.0"
    namespace                                 = "logging"
    aws_for_fluent_bit_cw_log_group           = "/${local.eks_cluster_id}/worker-fluentbit-logs"
    aws_for_fluentbit_cwlog_retention_in_days = 90
    create_namespace                          = true

    values = [templatefile("${path.module}/helm_values/aws-for-fluentbit-values.yaml", {
      region                          = local.region
      aws_for_fluent_bit_cw_log_group = "/${local.eks_cluster_id}/worker-fluentbit-logs"
    })]

    set = [
      {
        name  = "nodeSelector.kubernetes\\.io/os"
        value = "linux"
      }
    ]
  }

  enable_spark_k8s_operator = true
  spark_k8s_operator_helm_config = {
    name             = "spark-operator"
    chart            = "spark-operator"
    repository       = "https://googlecloudplatform.github.io/spark-on-k8s-operator"
    version          = "1.1.6"
    namespace        = "spark-k8s-operator"
    timeout          = "1200"
    create_namespace = true
    values           = [templatefile("${path.module}/helm_values/spark-k8s-operator-values.yaml", {})]
  }

  enable_fargate_fluentbit = true
  fargate_fluentbit_addon_config = {
    output_conf = <<-EOF
    [OUTPUT]
      Name cloudwatch_logs
      Match *
      region ${local.region}
      log_group_name /${local.eks_cluster_id}/fargate-fluentbit-logs
      log_stream_prefix "fargate-logs-"
      auto_create_group true
    EOF

    filters_conf = <<-EOF
    [FILTER]
      Name parser
      Match *
      Key_Name log
      Parser regex
      Preserve_Key On
      Reserve_Data On
    EOF
    parsers_conf = <<-EOF
    [PARSER]
      Name regex
      Format regex
      Regex ^(?<time>[^ ]+) (?<stream>[^ ]+) (?<logtag>[^ ]+) (?<message>.+)$
      Time_Key time
      Time_Format %Y-%m-%dT%H:%M:%S.%L%z
      Time_Keep On
      Decode_Field_As json message
    EOF
  }

  enable_argocd = true
  argocd_helm_config = {
    name             = "argo-cd"
    chart            = "argo-cd"
    repository       = "https://argoproj.github.io/argo-helm"
    version          = "3.26.3"
    namespace        = "argocd"
    timeout          = "1200"
    create_namespace = true
    values           = [templatefile("${path.module}/helm_values/argocd-values.yaml", {})]
  }

  enable_keda = true
  keda_helm_config = {
    name       = "keda"
    repository = "https://kedacore.github.io/charts"
    chart      = "keda"
    version    = "2.6.2"
    namespace  = "keda"
    values     = [templatefile("${path.module}/helm_values/keda-values.yaml", {})]
  }

  enable_vpa = true
  vpa_helm_config = {
    name       = "vpa"
    repository = "https://charts.fairwinds.com/stable"
    chart      = "vpa"
    version    = "1.0.0"
    namespace  = "vpa"
    values     = [templatefile("${path.module}/helm_values/vpa-values.yaml", {})]
  }

  enable_yunikorn = true
  yunikorn_helm_config = {
    name       = "yunikorn"
    repository = "https://apache.github.io/yunikorn-release"
    chart      = "yunikorn"
    version    = "0.12.2"
    values     = [templatefile("${path.module}/helm_values/yunikorn-values.yaml", {})]
  }

  depends_on = [module.eks_blueprints.managed_node_groups]
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = "10.0.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = "1"
  }

  tags = local.tags
}

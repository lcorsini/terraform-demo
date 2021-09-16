terraform {
  backend "gcs" {
    bucket = "di-devops-terragrunt"
    prefix = "tfdemo/gke/terraform.tfstate"
  }
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "1.13.4"
    }
  }
}

provider "google" {
  #project     = "di-devops-lab"
  #region      = "europe-west3"
  #zone        = "europe-west3-b"
  #credentials = file("/Users/corsinilu/Develop/NTTDATA/dev-workspace/terraform-demo/credentials.json")
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "3.4.0"

  project_id   = "di-devops-lab"
  network_name = "devops-vpc"

  subnets = [
    {
      subnet_name   = "gke"
      subnet_ip     = "192.168.1.0/25"
      subnet_region = "europe-west3"
    },
  ]

  secondary_ranges = {
    gke = [
      {
        range_name    = "gke-services"
        ip_cidr_range = "192.168.1.128/25"
      },
      {
        range_name    = "gke-pods"
        ip_cidr_range = "172.30.32.0/20"
      }
    ]
  }
}

data "google_client_config" "provider" {
}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    token                  = data.google_client_config.provider.access_token
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  }
}

module "gke" {
  depends_on = [module.vpc]
  source     = "terraform-google-modules/kubernetes-engine/google"
  project_id = "di-devops-lab"
  name       = "gke-cluster"
  region     = "europe-west3"
  #zones                      = ["us-central1-a", "us-central1-b", "us-central1-f"]
  network                    = "devops-vpc"
  subnetwork                 = "gke"
  ip_range_pods              = "gke-pods"
  ip_range_services          = "gke-services"
  http_load_balancing        = false
  horizontal_pod_autoscaling = true
  network_policy             = false

  node_pools = [
    {
      name            = "default-node-pool"
      machine_type    = "e2-standard-2"
      node_locations  = "europe-west3-b"
      min_count       = 1
      max_count       = 3
      local_ssd_count = 0
      disk_size_gb    = 100
      disk_type       = "pd-standard"
      image_type      = "COS"
      auto_repair     = true
      auto_upgrade    = true
      #service_account           = "project-service-account@<PROJECT ID>.iam.gserviceaccount.com"
      preemptible        = true
      initial_node_count = 1
    },
  ]
}

resource "kubernetes_namespace" "monitoring" {
  depends_on = [module.gke]
  metadata {
    name = "monitoring"
  }
}

module "helm_kube-state-metrics" {
  depends_on = [kubernetes_namespace.monitoring, module.gke]
  source     = "terraform-module/release/helm"
  version    = "2.6.0"
  namespace  = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"

  app = {
    name    = "kube-state-metrics"
    version = "3.0.2"
    chart   = "kube-state-metrics"
    deploy  = 1
  }

  values = []
  set    = []
}

module "helm_prometheus" {
  depends_on = [kubernetes_namespace.monitoring, module.gke]
  source     = "terraform-module/release/helm"
  version    = "2.6.0"
  namespace  = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"

  app = {
    name    = "prometheus"
    version = "13.8.0"
    chart   = "prometheus"
    deploy  = 1
  }

  values = []
  set = [
    {
      name  = "nodeExporter.enabled"
      value = 0
    },
    {
      name  = "alertmanager.enabled"
      value = 0
    },
    {
      name  = "pushgateway.enabled"
      value = 0
    },
    {
      name  = "server.service.servicePort"
      value = 9090
    }
  ]
}

module "helm_grafana" {
  depends_on = [kubernetes_namespace.monitoring, module.gke]
  source     = "terraform-module/release/helm"
  version    = "2.6.0"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"

  app = {
    name    = "grafana"
    chart   = "grafana"
    version = "6.16.6"
    deploy  = 1
  }

  values = [
    file("${path.module}/grafanaConfig/datasources.yaml")
  ]
  set = [
    {
      name  = "ingress.enabled"
      value = 1
    },
    {
      name = "service.type"
      value = "LoadBalancer"
    }
  ]
}

data "kubernetes_secret" "grafana_admin_password" {
    metadata {
      name = "grafana"
      namespace = "monitoring"
    }
}
data "kubernetes_service" "grafana_service" {
  metadata {
    name = "grafana"
    namespace = "monitoring"
  }
}
output "ip_address" {
    value = data.kubernetes_service.grafana_service.status.0.load_balancer.0.ingress.0.ip
  
}
output "admin_password" {
    value = nonsensitive(data.kubernetes_secret.grafana_admin_password.data.admin-password)
}

provider "grafana" {
  url  = "http://${data.kubernetes_service.grafana_service.status.0.load_balancer.0.ingress.0.ip}"
  auth = "admin:${data.kubernetes_secret.grafana_admin_password.data.admin-password}"
}
resource "grafana_dashboard" "metrics" {
  provider = grafana
  config_json = file("./grafanaConfig/kubernetes_cluster_monitoring.json")
}
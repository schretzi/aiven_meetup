locals {
  organization     = "org507578dda0c"
  project_name     = "devops-meetup-infra"
  cloud            = "google-europe-west4"
  network_cidr     = "10.1.0.0/24"
  billing_group_id = "24248937-42b5-45fc-a541-f1c83a4f903b"
}

terraform {
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = ">= 4.0.0, < 5.0.0"
    }
  }

  backend "gcs" {
    bucket = "devops-meetup-tf-state"
    prefix = "terraform/state/infra"
  }
}

resource "aiven_project" "infra" {
  parent_id     = data.aiven_organization.self.id
  project       = local.project_name
  default_cloud = local.cloud
  billing_group = data.aiven_billing_group.self.id
}

resource "time_sleep" "wait_for_project" {
  depends_on = [aiven_project.infra]

  create_duration = "30s"
}

resource "aiven_project_vpc" "vpc" {
  depends_on   = [time_sleep.wait_for_project]
  project      = local.project_name
  cloud_name   = local.cloud
  network_cidr = local.network_cidr

  timeouts {
    create = "5m"
  }
}

resource "aiven_thanos" "thanos" {
  project                = local.project_name
  cloud_name             = local.cloud
  service_name           = "thanos"
  plan                   = "startup-8"
  project_vpc_id         = aiven_project_vpc.vpc.id
  termination_protection = "false"

  thanos_user_config {
    compactor {
      retention_days = "30"
    }
  }

}

resource "aiven_opensearch" "opensearch" {
  project                = local.project_name
  cloud_name             = local.cloud
  service_name           = "opensearch"
  plan                   = "startup-8"
  project_vpc_id         = aiven_project_vpc.vpc.id
  termination_protection = "false"

  opensearch_user_config {
    opensearch_version = 2
    custom_domain      = ""

    opensearch_dashboards {
      enabled                    = true
      opensearch_request_timeout = 30000
    }

    public_access {
      opensearch            = false
      opensearch_dashboards = true
    }

    index_template {
      mapping_nested_objects_limit = 10000
      number_of_replicas           = 1 #(becasue of startup-4)
      number_of_shards             = 10
    }

    index_patterns {
      max_index_count = 14
      pattern         = "security-auditlog-*"
    }
  }
}

resource "aiven_grafana" "grafana" {
  project        = local.project_name
  cloud_name     = local.cloud
  service_name   = "grafana"
  project_vpc_id = aiven_project_vpc.vpc.id
  plan           = "startup-8"

  grafana_user_config {
    alerting_enabled = true

    public_access {
      grafana = true
    }
  }
}

resource "aiven_service_integration" "grafana-thanos" {
  project                  = local.project_name
  integration_type         = "dashboard"
  source_service_name      = aiven_grafana.grafana.service_name
  destination_service_name = aiven_thanos.thanos.service_name
}

resource "aiven_service_integration" "grafana-to-opensearch" {
  project                  = local.project_name
  integration_type         = "logs"
  source_service_name      = aiven_grafana.grafana.service_name
  destination_service_name = aiven_opensearch.opensearch.service_name
}

resource "aiven_service_integration" "grafana-from-opensearch" {
  project                  = local.project_name
  integration_type         = "datasource"
  source_service_name      = aiven_grafana.grafana.service_name
  destination_service_name = aiven_opensearch.opensearch.service_name
}

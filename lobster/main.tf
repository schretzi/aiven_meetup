# TODO:
# - rename vpc-to vpc-primary

locals {
  organization     = "org507578dda0c"
  project_name     = "devops-meetup-lobster"
  cloud            = "aws-eu-west-3"
  network_cidr     = "10.4.0.0/24"
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
    prefix = "terraform/state/lobster"
  }
}

resource "aiven_project" "lobster" {
  parent_id     = data.aiven_organization.self.id
  project       = local.project_name
  default_cloud = local.cloud
  billing_group = data.aiven_billing_group.self.id
}


resource "time_sleep" "wait_for_project" {
  depends_on = [aiven_project.lobster]

  create_duration = "30s"
}

resource "aiven_project_vpc" "vpc-primary" {
  depends_on   = [time_sleep.wait_for_project]
  project      = local.project_name
  cloud_name   = local.cloud
  network_cidr = local.network_cidr

  timeouts {
    create = "5m"
  }
}

resource "aiven_kafka" "lobster-kafka-primary" {
  project                 = local.project_name
  cloud_name              = local.cloud
  project_vpc_id          = aiven_project_vpc.vpc-primary.id
  plan                    = "startup-2"
  service_name            = "lobster-kafka-primary"
  maintenance_window_dow  = "monday"
  maintenance_window_time = "10:00:00"

  kafka_user_config {
    kafka_rest      = true
    kafka_connect   = false
    schema_registry = true
    kafka_version   = "3.8"

    kafka {
      group_max_session_timeout_ms = 70000
      log_retention_bytes          = 1000000000
      auto_create_topics_enable    = false
      default_replication_factor   = 3
      log_retention_ms             = 1209600000
      min_insync_replicas          = 2
      num_partitions               = 1
    }

    public_access {
      kafka_rest    = false
      kafka_connect = false
    }
  }
}

resource "aiven_service_integration" "thanos-lobster-kafka-primary" {
  project                     = local.project_name
  integration_type            = "metrics"
  source_service_name         = aiven_kafka.lobster-kafka-primary.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "thanos"
}

resource "aiven_service_integration" "opensearch-lobster-kafka-primary" {
  project                     = local.project_name
  integration_type            = "logs"
  source_service_name         = aiven_kafka.lobster-kafka-primary.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "opensearch"
}

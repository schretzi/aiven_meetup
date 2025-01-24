# TODO:
# - rename vpc-to vpc-primary

locals {
  organization        = "My Organization"
  project_name        = "devops-meetup-crab"
  cloud               = "google-europe-west4"
  cloud_backup        = "aws-eu-west-3"
  network_cidr        = "10.2.0.0/24"
  network_cidr_backup = "10.3.0.0/24"
  billing_group_id    = "24248937-42b5-45fc-a541-f1c83a4f903b"
}

terraform {
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = ">= 4.0.0, < 5.0.0"
    }
  }
}

resource "aiven_project" "crab" {
  parent_id     = data.aiven_organization.self.id
  project       = local.project_name
  default_cloud = local.cloud
  billing_group = data.aiven_billing_group.self.id
}

resource "time_sleep" "wait_for_project" {
  depends_on = [aiven_project.crab]

  create_duration = "30s"
}

resource "aiven_project_vpc" "vpc-primary" {
  depends_on = [time_sleep.wait_for_project]

  project      = local.project_name
  cloud_name   = local.cloud
  network_cidr = local.network_cidr

  timeouts {
    create = "5m"
  }
}

resource "aiven_gcp_vpc_peering_connection" "vpc-primary-onprem-bridgehead" {
  vpc_id         = aiven_project_vpc.vpc-primary.id
  gcp_project_id = "devops-meetup-448714"
  peer_vpc       = "devops-meetup-network"
}

resource "aiven_project_vpc" "vpc-backup" {
  depends_on = [time_sleep.wait_for_project]

  project      = local.project_name
  cloud_name   = local.cloud_backup
  network_cidr = local.network_cidr_backup

  timeouts {
    create = "5m"
  }
}

resource "aiven_kafka" "kafka-primary" {

  project                 = local.project_name
  cloud_name              = local.cloud
  project_vpc_id          = aiven_project_vpc.vpc-primary.id
  plan                    = "startup-2"
  service_name            = "kafka-primary"
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

resource "aiven_kafka" "kafka-backup" {
  project                 = local.project_name
  cloud_name              = local.cloud_backup
  project_vpc_id          = aiven_project_vpc.vpc-backup.id
  plan                    = "startup-2"
  service_name            = "kafka-backup"
  maintenance_window_dow  = "friday"
  maintenance_window_time = "10:00:00"

  kafka_user_config {
    kafka_rest      = false
    kafka_connect   = false
    schema_registry = false
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

resource "aiven_kafka_mirrormaker" "backup" {
  project        = local.project_name
  cloud_name     = local.cloud
  service_name   = "kafka-mm2-backup"
  plan           = "startup-4"
  project_vpc_id = aiven_project_vpc.vpc-primary.id

  kafka_mirrormaker_user_config {
    ip_filter_string = ["0.0.0.0/0"]

    kafka_mirrormaker {
      refresh_groups_interval_seconds = 600
      refresh_topics_enabled          = true
      refresh_topics_interval_seconds = 600
      tasks_max_per_cpu               = 4
    }
  }
}

resource "aiven_service_integration" "thanos-kafka-primary" {
  project                     = local.project_name
  integration_type            = "metrics"
  source_service_name         = aiven_kafka.kafka-primary.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "thanos"
}

resource "aiven_service_integration" "thanos-kafka-backup" {
  project                     = local.project_name
  integration_type            = "metrics"
  source_service_name         = aiven_kafka.kafka-backup.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "thanos"
}

resource "aiven_service_integration" "thanos-kafka-mm2" {
  project                     = local.project_name
  integration_type            = "metrics"
  source_service_name         = aiven_kafka_mirrormaker.backup.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "thanos"
}

resource "aiven_service_integration" "opensearch-kafka-primary" {
  project                     = local.project_name
  integration_type            = "logs"
  source_service_name         = aiven_kafka.kafka-primary.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "opensearch"
}

resource "aiven_service_integration" "opensearch-kafka-backup" {
  project                     = local.project_name
  integration_type            = "logs"
  source_service_name         = aiven_kafka.kafka-backup.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "opensearch"
}

resource "aiven_service_integration" "opensearch-kafka-mm2" {
  project                     = local.project_name
  integration_type            = "logs"
  source_service_name         = aiven_kafka_mirrormaker.backup.service_name
  destination_service_project = "devops-meetup-infra"
  destination_service_name    = "opensearch"
}


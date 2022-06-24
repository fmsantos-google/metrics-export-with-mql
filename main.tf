variable "gcp_project_id" {
  description = "Google Cloud Project ID"
}
variable "gcp_region" {
  description = "Google Cloud region"
  default = "us-central1"
}
variable "gcp_location" {
  description = "Google Cloud location"
  default = "US"
}
variable "pubsub_topic" {
  description = "Pub/Sub topic name"
  default = "mql_metric_export"
}
variable "bigquery_dataset" {
  description = "BigQuery dataset name"
  default = "metric_export"
}
variable "bigquery_table" {
  description = "BigQuery table name"
  default = "mql_metrics"
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

locals {
  timestamp = formatdate("YYMMDDhhmmss", timestamp())
  root_dir  = abspath("./")
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = local.root_dir
  output_path = "/tmp/function-${local.timestamp}.zip"
}

resource "google_storage_bucket" "artifacts_bucket" {
  name                        = "${var.gcp_project_id}-artifacts"
  uniform_bucket_level_access = true
  location                    = var.gcp_location
}

resource "google_storage_bucket_object" "function_archive" {
  bucket = google_storage_bucket.artifacts_bucket.name
  name   = "sourcecode.${data.archive_file.source.output_md5}.zip"
  source = data.archive_file.source.output_path
}

resource "google_bigquery_dataset" "bq_dataset" {
  dataset_id                 = var.bigquery_dataset
  location                   = var.gcp_location
  delete_contents_on_destroy = true
}

resource "google_bigquery_table" "bq_table" {
  depends_on          = [google_bigquery_dataset.bq_dataset]
  dataset_id          = google_bigquery_dataset.bq_dataset.dataset_id
  table_id            = var.bigquery_table
  schema              = file("./bigquery_schema.json")
  deletion_protection = false
}

resource "google_service_account" "iam_sa" {
  account_id   = "mlq-export-metrics"
  display_name = "MQL export metrics SA"
  description  = "Used for the function that export monitoring metrics"
}

resource "google_project_iam_member" "iam_permissions" {
  depends_on = [google_service_account.iam_sa]
  project    = var.gcp_project_id
  for_each   = toset([
    "bigquery.dataEditor", "bigquery.jobUser", "compute.viewer",
    "monitoring.viewer"
  ])
  role   = "roles/${each.key}"
  member = "serviceAccount:${google_service_account.iam_sa.email}"
}

resource "google_pubsub_topic" "ps_topic" {
  name = var.pubsub_topic
}

resource "google_cloudfunctions_function" "mql_export_metrics" {
  name    = "mql_export_metrics"
  runtime = "python38"
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.ps_topic.id
  }
  entry_point           = "export_metric_data"
  source_archive_bucket = google_storage_bucket.artifacts_bucket.name
  source_archive_object = google_storage_bucket_object.function_archive.name
  service_account_email = google_service_account.iam_sa.email
}

resource "google_cloud_scheduler_job" "scheduler_job" {
  name     = "get_metric_mql"
  schedule = "*/5 * * * *"
  pubsub_target {
    topic_name = google_pubsub_topic.ps_topic.id
    data       = base64encode("Exporting metric...")
  }
}
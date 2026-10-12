locals {
  bucket_name = "${var.prefix}-${var.environment}-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "google_storage_bucket" "site" {
  name                        = local.bucket_name
  project                     = var.project_id
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels
}

# El sitio es público a propósito: cualquiera puede leer los objetos del bucket.
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_object" "index" {
  name          = "index.html"
  bucket        = google_storage_bucket.site.name
  source        = var.index_file
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache, max-age=0"
}

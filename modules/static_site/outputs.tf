output "bucket_name" {
  value = google_storage_bucket.site.name
}

output "site_url" {
  value = "https://storage.googleapis.com/${google_storage_bucket.site.name}/${google_storage_bucket_object.index.name}"
}

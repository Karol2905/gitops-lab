terraform {
  backend "gcs" {
    prefix = "prod"
    # bucket se entrega con -backend-config desde el workflow
  }
}

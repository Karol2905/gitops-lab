terraform {
  backend "gcs" {
    prefix = "dev"
    # bucket se entrega con -backend-config desde el workflow
  }
}

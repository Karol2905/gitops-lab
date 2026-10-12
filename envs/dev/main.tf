terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.location
}

variable "project_id" {
  type        = string
  description = "Proyecto de GCP de este entorno (variable GCP_PROJECT_DEV en GitHub)."
}

variable "location" {
  type = string
}

variable "owner" {
  type = string
}

variable "prefix" {
  type    = string
  default = "pemu"
}

module "sitio" {
  source      = "../../modules/static_site"
  project_id  = var.project_id
  location    = var.location
  prefix      = var.prefix
  environment = "dev"
  index_file  = "${path.root}/../../site/index.html"

  labels = {
    environment = "dev"
    owner       = lower(var.owner)
    course      = "pemu-2026"
  }
}

output "site_url" {
  value = module.sitio.site_url
}

output "bucket_name" {
  value = module.sitio.bucket_name
}

terraform {
  required_version = ">= 1.2.4"

  backend "gcs" {
    bucket = "libops-terraform"
    prefix = "gcp/libops-linux-packages"
  }

  required_providers {
    github = {
      source  = "integrations/github"
      version = "6.11.1"
    }
    google = {
      source  = "hashicorp/google"
      version = "7.24.0"
    }
  }
}

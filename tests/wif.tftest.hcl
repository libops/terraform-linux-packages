mock_provider "google" {
  override_during = plan

  mock_resource "google_project" {
    defaults = {
      project_id = "libops-linux-packages"
      number     = "123456789012"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email = "github-packages@libops-linux-packages.iam.gserviceaccount.com"
      name  = "projects/libops-linux-packages/serviceAccounts/github-packages@libops-linux-packages.iam.gserviceaccount.com"
    }
  }
}

mock_provider "github" {
  alias           = "libops"
  override_during = plan

  mock_data "github_repository" {
    defaults = {
      name = "sitectl"
    }
  }
}

variables {
  org_id              = "123456789012"
  billing_account     = "000000-000000-000000"
  github_repositories = ["libops/sitectl"]
  approved_job_workflow_refs = [
    "libops/terraform-linux-packages/.github/workflows/reusable-goreleaser.yaml@481df51116aed2efd1c002ef1ef6a287699828a0",
    "libops/.github/.github/workflows/sitectl-plugin-goreleaser.yaml@e1e30b58c9c566f72b22f03e637cd5218d635727",
  ]
}

run "requires_exact_approved_reusable_workflows" {
  command = plan

  assert {
    condition = (
      strcontains(local.provider_attribute_condition, "assertion.repository == 'libops/sitectl'") &&
      strcontains(local.provider_attribute_condition, "assertion.job_workflow_ref == 'libops/terraform-linux-packages/.github/workflows/reusable-goreleaser.yaml@481df51116aed2efd1c002ef1ef6a287699828a0'") &&
      strcontains(local.provider_attribute_condition, "assertion.job_workflow_ref == 'libops/.github/.github/workflows/sitectl-plugin-goreleaser.yaml@e1e30b58c9c566f72b22f03e637cd5218d635727'") &&
      google_iam_workload_identity_pool_provider.github.attribute_mapping["attribute.job_workflow_ref"] == "assertion.job_workflow_ref"
    )
    error_message = "WIF must require the caller repository and one of the exact direct/shared reusable workflow identities."
  }
}

run "rejects_mutable_workflow_identity" {
  command = plan

  variables {
    approved_job_workflow_refs = [
      "libops/terraform-linux-packages/.github/workflows/reusable-goreleaser.yaml@refs/heads/main",
    ]
  }

  expect_failures = [
    var.approved_job_workflow_refs,
  ]
}

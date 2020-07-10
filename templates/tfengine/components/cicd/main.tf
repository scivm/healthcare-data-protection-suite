# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This folder contains Terraform resources to setup CI/CD, which includes:
# - Necessary APIs to enable in the devops project for CI/CD purposes,
# - Necessary IAM permissions to set to enable Cloud Build Service Account perform CI/CD jobs.
# - Cloud Build Triggers to monitor GitHub repos to start CI/CD jobs.
#
# The Cloud Build configs can be found under the configs/ sub-folder.

# ***NOTE***: First follow
# https://cloud.google.com/cloud-build/docs/automating-builds/create-github-app-triggers#installing_the_cloud_build_app
# to install the Cloud Build app and connect your GitHub repository to your Cloud project.

terraform {
  required_version = "~> 0.12.0"
  required_providers {
    google      = "~> 3.0"
    google-beta = "~> 3.0"
  }
  backend "gcs" {
    bucket = "{{.state_bucket}}"
    prefix = "cicd/manual"
  }
}

data "google_project" "devops" {
  project_id = module.project.project_id
}

locals {
  services = [
    "admin.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
  ]
  cloudbuild_sa_viewer_roles = [
    "roles/browser",
    "roles/iam.securityReviewer",
    "roles/secretmanager.secretViewer",
    "roles/secretmanager.secretAccessor",
  ]
  cloudbuild_sa_editor_roles = [
    "roles/compute.xpnAdmin",
    "roles/logging.configWriter",
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.{{.parent_type}}Admin",
    {{- if eq (get . "parent_type") "organization"}}
    "roles/orgpolicy.policyAdmin",
    "roles/resourcemanager.folderCreator",
    {{- end}}
  ]
  cloudbuild_devops_roles = [
    # Enable Cloud Build SA to list and enable APIs in the devops project.
    "roles/serviceusage.serviceUsageAdmin",
  ]
}

locals {
  # Covert "" and "/" to "." in case users use them to indicate root of the git repo.
  terraform_root = trim((var.terraform_root == "" || var.terraform_root == "/") ? "." : var.terraform_root, "/")
  # ./ to indicate root is not recognized by Cloud Build Trigger.
  terraform_root_prefix = local.terraform_root == "." ? "" : "${local.terraform_root}/"
  cloud_build_sa        = "serviceAccount:${data.google_project.devops.number}@cloudbuild.gserviceaccount.com"
}

# Cloud Build - API
resource "google_project_service" "services" {
  for_each           = toset(local.services)
  project            = module.project.project_id
  service            = each.value
  disable_on_destroy = false
}

# IAM permissions to allow approvers and contributors to view the build results.
resource "google_project_iam_member" "cloudbuild_viewers" {
  for_each = toset(var.build_viewers)
  project  = module.project.project_id
  role     = "roles/cloudbuild.builds.viewer"
  member   = each.value
  depends_on = [
    google_project_service.services,
  ]
}
{{if has . "apply_trigger"}}
# IAM permissions to allow Cloud Build Service Account use the billing account.
resource "google_billing_account_iam_member" "binding" {
  billing_account_id = var.billing_account
  role               = "roles/billing.user"
  member             = local.cloud_build_sa
  depends_on = [
    google_project_service.services,
  ]
}
{{- end}}

# Cloud Build - Cloud Build Service Account IAM permissions
# IAM permissions to allow Cloud Build SA to access state.
resource "google_storage_bucket_iam_member" "cloudbuild_state_iam" {
  bucket = var.state_bucket
  {{- if has . "apply_trigger"}}
  role   = "roles/storage.admin"
  {{- else}}
  role   = "roles/storage.objectViewer"
  {{- end}}
  member = local.cloud_build_sa
  depends_on = [
    google_project_service.services,
  ]
}

# Grant Cloud Build Service Account access to the {{.parent_type}}.
resource "google_{{.parent_type}}_iam_member" "cloudbuild_sa_{{.parent_type}}_iam" {
  {{- if has . "apply_trigger"}}
  for_each = toset(local.cloudbuild_sa_editor_roles)
  {{- else}}
  for_each = toset(local.cloudbuild_sa_viewer_roles)
  {{- end}}
  {{- if eq (get . "parent_type") "organization"}}
  org_id   = {{.parent_id}}
  {{- else}}
  folder   = {{.parent_id}}
  {{- end}}
  role     = each.value
  member   = local.cloud_build_sa
  depends_on = [
    google_project_service.services,
  ]
}

# Grant Cloud Build Service Account access to the devops project.
resource "google_project_iam_member" "cloudbuild_sa_project_iam" {
  for_each = toset(local.cloudbuild_devops_roles)
  project  = module.project.project_id
  role     = each.key
  member   = local.cloud_build_sa
  depends_on = [
    google_project_service.services,
  ]
}

{{if has . "validate_trigger" -}}
resource "google_cloudbuild_trigger" "validate" {
  {{- if (get  .validate_trigger "disable" false)}}
  disabled = true
  {{- end}}
  provider = google-beta
  project  = module.project.project_id
  name     = "tf-validate"

  included_files = [
    "${local.terraform_root_prefix}**",
  ]

  {{if index . "github" -}}
  github {
    owner = "{{.github.owner}}"
    name  = "{{.github.name}}"
    pull_request {
      branch = "{{.branch_regex}}"
    }
  }
  {{- else if index . "cloud_source_repository" -}}
  trigger_template {
    repo_name   = "{{.cloud_source_repository.name}}"
    branch_name = "{{.branch_regex}}"
  }
  {{- end}}

  filename = "${local.terraform_root_prefix}cicd/configs/tf-validate.yaml"

  substitutions = {
    _TERRAFORM_ROOT = local.terraform_root
  }

  depends_on = [
    google_project_service.services,
  ]
}
{{- end}}

{{if has . "plan_trigger" -}}
resource "google_cloudbuild_trigger" "plan" {
  {{- if (get  .plan_trigger "disable" false)}}
  disabled = true
  {{- end}}
  provider = google-beta
  project  = module.project.project_id
  name     = "tf-plan"

  included_files = [
    "${local.terraform_root_prefix}live/**",
    "${local.terraform_root_prefix}cicd/configs/**"
  ]

  {{if index . "github" -}}
  github {
    owner = "{{.github.owner}}"
    name  = "{{.github.name}}"
    pull_request {
      branch = "{{.branch_regex}}"
    }
  }
  {{- else if index . "cloud_source_repository" -}}
  trigger_template {
    repo_name   = "{{.cloud_source_repository.name}}"
    branch_name = "{{.branch_regex}}"
  }
  {{- end}}

  filename = "${local.terraform_root_prefix}cicd/configs/tf-plan.yaml"

  substitutions = {
    _TERRAFORM_ROOT = local.terraform_root
  }

  depends_on = [
    google_project_service.services,
  ]
}
{{- end}}

{{if has . "apply_trigger" -}}
resource "google_cloudbuild_trigger" "apply" {
  {{- if (get  .apply_trigger "disable" false)}}
  disabled = true
  {{- end}}
  provider = google-beta
  project  = module.project.project_id
  name     = "tf-apply"

  included_files = [
    "${local.terraform_root_prefix}live/**",
    "${local.terraform_root_prefix}cicd/configs/**"
  ]

  {{if index . "github" -}}
  github {
    owner = "{{.github.owner}}"
    name  = "{{.github.name}}"
    push {
      branch = "{{.branch_regex}}"
    }
  }
  {{- else if index . "cloud_source_repository" -}}
  trigger_template {
    repo_name   = "{{.cloud_source_repository.name}}"
    branch_name = "{{.branch_regex}}"
  }
  {{- end}}

  filename = "${local.terraform_root_prefix}cicd/configs/tf-apply.yaml"

  substitutions = {
    _TERRAFORM_ROOT = local.terraform_root
  }

  depends_on = [
    google_project_service.services,
  ]
}
{{- end}}
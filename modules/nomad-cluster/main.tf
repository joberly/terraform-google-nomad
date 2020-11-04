# ---------------------------------------------------------------------------------------------------------------------
# This module has been updated with 0.12 syntax, which means the example is no longer
# compatible with any versions below 0.12.
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.12"
}

locals {
  cluster_name_prefix = "${trimsuffix(var.cluster_name, "-")}-"
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A GCE MANAGED INSTANCE GROUP TO RUN NOMAD
# ---------------------------------------------------------------------------------------------------------------------

# Create the Managed Instance Group where Nomad will run.
resource "google_compute_region_instance_group_manager" "nomad" {
  project = var.gcp_proect_id
  name    = "${var.cluster_name}-ig"

  base_instance_name = var.cluster_name
  instance_template  = google_compute_instance_template.nomad.self_link
  region             = var.gcp_region

  # Restarting all Nomad servers at the same time will result in data loss and down time. Therefore, the update strategy
  # used to roll out a new GCE Instance Template must be a rolling update. But since Terraform does not yet support
  # ROLLING_UPDATE, such updates must be manually rolled out for now.
  update_policy {
    type                         = var.instance_group_update_policy_type
    instance_redistribution_type = var.instance_group_update_policy_redistribution_type
    minimal_action               = var.instance_group_update_policy_minimal_action
    max_surge_fixed              = var.instance_group_update_policy_max_surge_fixed
    max_surge_percent            = var.instance_group_update_policy_max_surge_percent
    max_unavailable_fixed        = var.instance_group_update_policy_max_unavailable_fixed
    max_unavailable_percent      = var.instance_group_update_policy_max_unavailable_percent
    min_ready_sec                = var.instance_group_update_policy_min_ready_sec
  }

  target_pools = var.instance_group_target_pools
  target_size  = var.cluster_size

  depends_on = [
    google_compute_instance_template.nomad,
  ]
}

# Create the Instance Template that will be used to populate the Managed Instance Group.
# NOTE: This Compute Instance Template is only created if var.assign_public_ip_addresses is true.
resource "google_compute_instance_template" "nomad" {
  count = var.assign_public_ip_addresses ? 1 : 0

  name_prefix = local.cluster_name_prefix
  description = var.cluster_description

  instance_description = var.cluster_description
  machine_type         = var.machine_type

  tags                    = concat([var.cluster_tag_name], var.custom_tags)
  metadata_startup_script = var.startup_script
  metadata = merge(
    {
      "${var.metadata_key_name_for_cluster_size}" = var.cluster_size
    },
    var.custom_metadata,
  )

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  disk {
    boot         = true
    auto_delete  = true
    source_image = google_compute_image.image.self_link
    disk_size_gb = var.root_volume_disk_size_gb
    disk_type    = var.root_volume_disk_type
  }

  network_interface {
    network = var.network_name
    // If public IP addresses are requested, add an empty access_config block
    // to automatically assign public IP addresses.
    dynamic "access_config" {
      for_each = var.assign_public_ip_addresses ? ["public_ip"] : []
      content {
      }
    }
  }

  # For a full list of oAuth 2.0 Scopes, see https://developers.google.com/identity/protocols/googlescopes
  service_account {
    email = var.service_account_email
    scopes = concat(var.service_account_scopes, [
      "https://www.googleapis.com/auth/userinfo.email",
      "https://www.googleapis.com/auth/compute.readonly",
    ])
  }

  # Per Terraform Docs (https://www.terraform.io/docs/providers/google/r/compute_instance_template.html#using-with-instance-group-manager),
  # we need to create a new instance template before we can destroy the old one. Note that any Terraform resource on
  # which this Terraform resource depends will also need this lifecycle statement.
  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE FIREWALL RULES
# ---------------------------------------------------------------------------------------------------------------------

module "firewall_rules" {
  source = "../nomad-firewall-rules"

  cluster_name     = var.cluster_name
  cluster_tag_name = var.cluster_tag_name

  allowed_inbound_cidr_blocks_http = var.allowed_inbound_cidr_blocks_http
  allowed_inbound_cidr_blocks_rpc  = var.allowed_inbound_cidr_blocks_rpc
  allowed_inbound_cidr_blocks_serf = var.allowed_inbound_cidr_blocks_serf

  allowed_inbound_tags_http = var.allowed_inbound_tags_http
  allowed_inbound_tags_rpc  = var.allowed_inbound_tags_rpc
  allowed_inbound_tags_serf = var.allowed_inbound_tags_serf

  http_port = 4646
  rpc_port  = 4647
  serf_port = 4648
}

data "google_compute_image" "image" {
  name    = var.source_image
  project = var.image_project_id != null ? var.image_project_id : var.gcp_project_id
}

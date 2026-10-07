# The golden image: stock Ubuntu 22.04, hardened by the shared cis_baseline
# role, published to an image family in the landing zone's image project.
#
# Run through make build-image (scripts/build-image.py), which pins the role
# to a tag, fetches the apt transport by SHA256, and fills every variable from
# the image root's outputs. Running packer by hand works too, with the same
# variables.
#
# The bake is private end to end:
#   no external IP     org policy forbids one, and none is needed
#   IAP + OS Login     SSH arrives through the org policy's IAP rule only
#   no internet route  apt reads the Artifact Registry Ubuntu mirror through
#                      Private Google Access (image/network.tf)

packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "~> 1.1"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}

variable "project_id" {
  type        = string
  description = "Image project: the bake runs and the image is published here."
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "service_account" {
  type        = string
  description = "Bake VM identity. Reads the mirror through the metadata server."
}

variable "builder_service_account" {
  type        = string
  description = "Identity Packer impersonates for every API call and the IAP tunnel."
}

variable "ssh_username" {
  type        = string
  description = "The builder SA's OS Login POSIX user (sa_<id>), from build-image.py's key import."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Throwaway key build-image.py imported into the builder's OS Login profile."
}

variable "image_family" {
  type    = string
  default = "hardened-ubuntu-2204"
}

variable "source_image_family" {
  type    = string
  default = "ubuntu-2204-lts"
}

variable "source_image_project" {
  type    = string
  default = "ubuntu-os-cloud"
}

variable "machine_type" {
  type    = string
  default = "e2-small"
}

variable "apt_sources" {
  type        = string
  description = "Contents of /etc/apt/sources.list: ar+https lines for the mirror, one per suite."
}

variable "transport_deb" {
  type        = string
  description = "Local path of apt-transport-artifact-registry, already checked against its pinned SHA256."
}

variable "role_path" {
  type        = string
  description = "Directory holding cis_baseline, extracted from the pinned tag."
}

variable "check_script" {
  type        = string
  description = "check-hardening.sh from the same pinned tag."
}

variable "role_ref" {
  type        = string
  description = "Tag and commit of the role, recorded on the image."
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
}

source "googlecompute" "hardened" {
  project_id                  = var.project_id
  impersonate_service_account = var.builder_service_account
  zone                        = var.zone
  source_image_family         = var.source_image_family
  source_image_project_id     = [var.source_image_project]

  network          = var.network
  subnetwork       = var.subnetwork
  omit_external_ip = true
  use_internal_ip  = true
  use_iap          = true
  # OS Login, but not Packer's own OS Login step: it cannot derive a username
  # from impersonated credentials. build-image.py imports the key as the
  # builder SA and passes the POSIX user here; the instance enforces OS Login
  # through metadata and the org policy, so metadata SSH keys are ignored.
  ssh_username          = var.ssh_username
  ssh_private_key_file  = var.ssh_private_key_file
  service_account_email = var.service_account
  scopes                = ["https://www.googleapis.com/auth/cloud-platform"]

  machine_type = var.machine_type
  disk_size    = 20
  disk_type    = "pd-balanced"

  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    enable-osconfig        = "TRUE"
  }

  image_name        = "${var.image_family}-${local.timestamp}"
  image_family      = var.image_family
  image_description = "Ubuntu 22.04 hardened by cis_baseline ${var.role_ref}; apt reads the landing zone mirror."
  image_labels = {
    managed-by  = "packer"
    project     = "gcp-landing-zone"
    owner       = "jordan"
    cost_center = "cc-0001"
    source-fmly = var.source_image_family
  }
}

build {
  name    = "hardened-ubuntu"
  sources = ["source.googlecompute.hardened"]

  provisioner "file" {
    source      = var.transport_deb
    destination = "/tmp/apt-transport-artifact-registry.deb"
  }

  # Point apt at the mirror before anything installs a package. Fails the bake
  # if the mirror cannot serve an index, before Ansible spends time on it.
  provisioner "shell" {
    script = "scripts/use-mirror.sh"
    # {{ .Vars }} is how environment_vars reach the script; a custom
    # execute_command without it silently drops them. Base64 because the
    # variables are set on one command line.
    environment_vars = ["APT_SOURCES_B64=${base64encode(var.apt_sources)}"]
    execute_command  = "{{ .Vars }} sudo -E bash '{{ .Path }}'"
  }

  provisioner "ansible" {
    playbook_file    = "site.yml"
    use_proxy        = false
    ansible_env_vars = ["ANSIBLE_ROLES_PATH=${var.role_path}", "ANSIBLE_HOST_KEY_CHECKING=False"]
  }

  provisioner "shell" {
    inline            = ["sudo reboot"]
    expect_disconnect = true
  }

  # A boot must preserve the baseline before the image is published.
  provisioner "shell" {
    pause_before        = "30s"
    start_retry_timeout = "5m"
    script              = var.check_script
    execute_command     = "sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "scripts/finalize.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}

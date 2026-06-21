variable "proxmox_os_template" {
  type        = string
  description = "The storage path and filename of the target LXC template"
  default     = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}

# New network prefix variable (e.g., 192.168.1)
variable "network_prefix" {
  type        = string
  description = "The first three octets of the network"
  default     = "192.168.1"
}

# New host IP suffix variable (e.g., 52)
variable "docker_host_ip_suffix" {
  type        = string
  description = "The last octet for the container's IP address"
  default     = "52"
}

# Docker container id
variable "docker_container_id" {
  type        = integer
  description = "The id of docker container in proxmox"
  default     = 100
}

resource "proxmox_virtual_environment_container" "docker_host" {
  node_name    = "pve"
  vm_id        = var.docker_container_id
  name         = "docker-environment"
  unprivileged = true
  ostemplate   = var.proxmox_os_template

  initialization {
    hostname = "docker-srv"
    ip_config {
      ipv4 {
        # Concatenates into "192.168.1.52/24"
        address = "${var.network_prefix}.${var.docker_host_ip_suffix}/24"
        
        # Dynamically assumes the gateway is .1 on the same subnet
        gateway = "${var.network_prefix}.1"
      }
    }
  }

  cpu { cores = 4 }
  memory { dedicated = 16384 } 

  features {
    nesting = true
  }

  mount_point {
    volume = "/mnt/pve/secure-storage"
    path   = "/mnt/storage"
  }

  device_passthrough {
    source      = "/dev/dri/renderD128"
    uid         = 1000
    gid         = 1000
    mode        = "0666"
  }
}

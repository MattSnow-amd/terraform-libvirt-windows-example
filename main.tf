terraform {
  required_version = ">= 0.12"
}

provider "libvirt" {
  uri = "qemu:///system"
}

variable "prefix" {
  default = "terraform_example"
}

variable "winrm_username" {
  default = "vagrant"
}

variable "winrm_password" {
  default = "vagrant"
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/network.markdown
resource "libvirt_network" "example" {
  name = var.prefix
  mode = "nat"
  domain = "example.test"
  addresses = ["10.17.3.0/24"]
  dhcp {
    enabled = true
  }
  dns {
    enabled = true
    local_only = false
  }
}

# a multipart cloudbase-init cloud-config.
# see https://github.com/cloudbase/cloudbase-init
# see https://cloudbase-init.readthedocs.io/en/latest/userdata.html#userdata
# see https://www.terraform.io/docs/providers/template/d/cloudinit_config.html
# see https://www.terraform.io/docs/configuration/expressions.html#string-literals
data "template_cloudinit_config" "example" {
  gzip = false
  base64_encode = false
  part {
    content_type = "text/cloud-config"
    content = <<-EOF
      #cloud-config
      hostname: example
      timezone: Asia/Tbilisi
      EOF
  }
  # TODO for some reason cloudbase-init is not running this script... see why!
  part {
    content_type = "text/x-shellscript"
    content = <<-EOF
      #ps1_sysnative
      Start-Transcript -Append "C:\cloudconfig-ps1.log"
      Add-Content -Encoding ascii "C:\cloudconfig-ps1-add-content.log" (Get-Date)
      function Write-Title($title) {
        Write-Output "`n#`n# $title`n#"
      }
      Write-Title "whoami"
      whoami /all
      Write-Title "Windows version"
      cmd /c ver
      Write-Title "Environment Variables"
      dir env:
      Write-Title "TimeZone"
      Get-TimeZone
      EOF
  }
}

# a cloudbase-init cloud-config disk.
# NB this creates an iso image that will be used by the NoCloud cloudbase-init datasource.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/cloudinit.html.markdown
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.6.0/libvirt/cloudinit_def.go#L133-L162
resource "libvirt_cloudinit_disk" "example_cloudinit" {
  name = "${var.prefix}_example_cloudinit.iso"
  user_data = data.template_cloudinit_config.example.rendered
}

# this uses the vagrant windows image imported from https://github.com/rgl/windows-2016-vagrant.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/volume.html.markdown
resource "libvirt_volume" "example_root" {
  name = "${var.prefix}_root.img"
  base_volume_name = "windows-2019-amd64_vagrant_box_image_0.img"
  format = "qcow2"
  size = 66*1024*1024*1024 # 66GiB. this root FS is automatically resized by cloud-initramfs-growroot (included in the rgl/windows-vagrant image).
}

# a data disk.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/volume.html.markdown
resource "libvirt_volume" "example_data" {
  name = "${var.prefix}_data.img"
  format = "qcow2"
  size = 6*1024*1024*1024 # 6GiB.
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/domain.html.markdown
resource "libvirt_domain" "example" {
  name = var.prefix
  cpu = {
    mode = "host-passthrough"
  }
  vcpu = 2
  memory = 1024
  video {
    type = "qxl"
  }
  xml {
    xslt = file("libvirt-domain.xsl")
  }
  qemu_agent = true
  cloudinit = libvirt_cloudinit_disk.example_cloudinit.id
  disk {
    volume_id = libvirt_volume.example_root.id
    scsi = false
  }
  disk {
    volume_id = libvirt_volume.example_data.id
    scsi = false
  }
  network_interface {
    network_id = libvirt_network.example.id
    wait_for_lease = true
    hostname = "example"
    addresses = ["10.17.3.2"]
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOF
      whoami /all
      ver
      PowerShell "Get-Disk | Select-Object Number,PartitionStyle,Size | Sort-Object Number"
      PowerShell "Get-Volume | Sort-Object DriveLetter,FriendlyName"
      EOF
    ]
    connection {
      type = "winrm"
      user = var.winrm_username
      password = var.winrm_password
      host = self.network_interface[0].addresses[0] # see https://github.com/dmacvicar/terraform-provider-libvirt/issues/660
    }
  }
}

output "ip" {
  value = length(libvirt_domain.example.network_interface[0].addresses) > 0 ? libvirt_domain.example.network_interface[0].addresses[0] : ""
}

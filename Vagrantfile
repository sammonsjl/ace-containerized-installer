# ace-containerized-installer — lab VM
#
# One VM:
#   ace-installer : the whole ACE control plane as rootless podman containers
#                   (postgres, redis x2, gateway + envoy, controller web/task/rsyslog, receptor)
#
# Box: bento/rockylinux-9 (publishes x86_64 and aarch64 — works on Intel and Apple Silicon)
# Provider: tested with vmware_desktop (VMware Fusion). virtualbox and libvirt blocks
# are provided untested. libvirt users: use VAGRANT_BOX=generic/rocky9.
#
# IP is 192.168.56.30 — .10/.20 belong to the ace-the-hard-way VMs.

Vagrant.configure("2") do |config|
  config.vm.box = ENV.fetch("VAGRANT_BOX", "bento/rockylinux-9")

  # The repo is shared into the VM at /vagrant. The gateway image tarball
  # (images/ace-gateway-arm64.tar) is delivered through this mount.
  config.vm.synced_folder ".", "/vagrant"

  config.vm.define "ace-installer" do |node|
    node.vm.hostname = "ace-installer"
    node.vm.network "private_network", ip: "192.168.56.30"

    node.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]  = "8192"
      v.vmx["numvcpus"] = "4"
      # Pin NIC PCI slots (bento box defaults) — silences the Vagrant VMX-allowlisting
      # warning and keeps networking stable when Vagrant stops managing these.
      v.vmx["ethernet0.pcislotnumber"] = "160"
      v.vmx["ethernet1.pcislotnumber"] = "224"
    end
    node.vm.provider "virtualbox" do |v|
      v.memory = 8192
      v.cpus   = 4
    end
    node.vm.provider "libvirt" do |v|
      v.memory = 8192
      v.cpus   = 4
    end
  end

  # OS packages land here (root), so the Ansible run itself stays rootless —
  # the containerized installer's plays are all become:false; its docs make
  # the customer install podman as a prerequisite. Same split, expressed in Vagrant.
  config.vm.provision "shell", inline: <<-SHELL
    dnf -y install podman crun slirp4netns python3 python3-cryptography \
                   python3-psycopg2 openssl curl jq vim git
  SHELL
end

# ace-containerized-installer

Deploys the **ACE control plane** — the open-source mirror of Ansible Automation
Platform's gateway + controller — as **rootless podman containers managed by
systemd user units**, rebuilt from scratch on images this project builds
itself.

```
                       ┌────────────────────────── ace-installer VM ─┐
   https://:443  ──►   envoy (automation-gateway-proxy)              │
                       │   dynamic LDS/CDS from the gateway          │
                       ├──► gateway nginx :8446 ──► uwsgi :8052      │
                       │       (ace-gateway: jewel + platform UI)    │
                       │       gRPC control plane :50051             │
                       ├──► controller nginx :8443 ──► uwsgi :8050   │
                       │       (ace-controller — web/task/rsyslog)   │
                       │       receptor ──► podman ──► EE jobs       │
                       │  postgres :5432 · redis-tcp :6379 (TLS)     │
                       │  redis-unix (socket, controller broker)     │
                       └─────────────────────────────────────────────┘
```

## Provenance & licensing

The vendor's containerized setup bundle was used strictly as a **behavioral
spec** — container topology, task ordering, port map, config-key semantics.
Every file in this repo is written from scratch against upstream project
documentation (envoy, nginx, uwsgi, redis, postgres, AWX, django-ansible-base,
jewel), and every image it deploys is built from upstream source by
[ace-images](https://github.com/sammonsjl/ace-images).

Apache-2.0. Full provenance and trademark statement in [`NOTICE`](NOTICE).

## Prerequisites (macOS host)

- VMware Fusion + `vagrant` + `vagrant-vmware-desktop` plugin
- `ansible` (`brew install ansible`)
- Network access to `ghcr.io` — the installer pulls the prebuilt, multi-arch
  (`linux/amd64` + `linux/arm64`) gateway/hub images from
  [ace-images](https://github.com/sammonsjl/ace-images) automatically. Building
  locally and delivering a `podman save` tarball to `images/` is only needed
  offline or when testing a custom image build.

## Quickstart

```sh
# 1. (offline/custom builds only) Deliver locally-built images as gitignored
#    tarballs, read from /vagrant in the VM — skip this if ghcr.io is reachable
podman save --format oci-archive -o images/ace-gateway-arm64.tar localhost/ace-gateway:dev
podman save --format oci-archive -o images/ace-hub-arm64.tar localhost/ace-hub:dev

# 2. Boot the VM (Rocky 9, 8 GB / 4 vCPU, 192.168.56.30)
vagrant up

# 3. Install everything
ansible-galaxy collection install -r requirements.yml -p ./collections
ansible-playbook playbooks/install.yml
# ...or target the homelab VM instead of Vagrant:
ansible-playbook -i inventory/homelab.yml playbooks/install.yml

# 4. Log in
open https://192.168.56.30/     # accept the self-signed cert
cat .secrets/admin_password
```

## Building the VM with Terraform (Linux hosts)

Instead of Vagrant, two Terraform roots build the same Rocky 9 host. Both
render the shared `terraform/cloud-init/user-data.yaml.tftpl`, so the guest is
identical and the playbooks do not care which one built it.

| Root | Where | Address | Inventory |
|---|---|---|---|
| `terraform/proxmox/` | a Proxmox VE node (16 GB / 8 vCPU) | `192.168.1.45` on the LAN | `inventory/homelab.yml` |
| `terraform/kvm/` | this machine, KVM/libvirt (8 GB / 4 vCPU) | `192.168.145.45` on its own NAT network, reachable from this machine only | `inventory/kvm.yml` |

Both expect the SSH key at `~/.ssh/ace_lab_ed25519` (override with
`ssh_public_key_path`).

```sh
# Proxmox: credentials in terraform/proxmox/terraform.tfvars (gitignored)
terraform -chdir=terraform/proxmox init && terraform -chdir=terraform/proxmox apply
ansible-playbook -i inventory/homelab.yml playbooks/install.yml

# Local KVM: needs libvirt running and your user in the `libvirt` group
terraform -chdir=terraform/kvm init && terraform -chdir=terraform/kvm apply
ansible-playbook -i inventory/kvm.yml playbooks/install.yml
```

The KVM root creates its own libvirt network (`ace`, 192.168.145.0/24, NAT)
and storage pool (`ace`, `/var/lib/libvirt/images/ace`), and removes both on
`terraform destroy`. The guest's serial console is logged to
`/var/log/libvirt/qemu/ace-console.log` (root-readable); `virsh console ace`
attaches to it.

It needs hardware virtualization: `/dev/kvm` must exist, i.e. VT-x/AMD-V is
enabled in the firmware. Without it, `-var domain_type=qemu` runs the VM under
software emulation — enough to prove the plumbing, far too slow to be useful.

## Design notes (where we deliberately differ from the bundle)

| Bundle | Here | Why |
|---|---|---|
| RHEL9 SCL postgres/redis images | `postgres:15` / `redis:7` (docker.io) | public images; tuning via mounted conf/args instead of SCL env vars |
| OS packages installed by the customer per docs | preflight role (`dnf`, the one `become` block besides host prep) | a stock EL9 cloud image installs cleanly, not just the Vagrant box |
| `ansible.platform` modules for service registration | plain REST (`ansible.builtin.uri`) | the collection isn't published upstream; the modules wrap this same API |
| redis mTLS client certs | server-TLS + password | single-host loopback; client-cert auth is 2-VM-variant work |
| receptor mesh TLS + work signing | local-only control socket | single node; the mesh returns in the 2-VM variant |

Everything else follows the bundle: `generate_systemd` user units (not
quadlets), `network: host` everywhere, `userns: keep-id` (except postgres —
the official image's uid-999 machinery wants the default rootless userns),
podman secrets, one shared self-signed CA with ownca-signed component certs,
ephemeral init containers, `~/ace/<component>/` config layout.

### Apple Silicon note

Every Python process that imports `cryptography` inside an aarch64 VM under
VMware Fusion dies with SIGILL (exit 132) unless `OPENSSL_armcap=0` is set.
The playbook sets it at play level (covers Ansible modules on the VM), on every
container, and via `AWX_TASK_ENV` for execution-environment jobs.

## Kubernetes execution plane

Pointing the controller at an outside Kubernetes cluster, so jobs run there as
pods through a container group, takes a cluster-side contract (namespace,
ServiceAccount, Role, token) and controller-side wiring (a bearer-token
credential and a container group). A worked example of the controller side is
in [`examples/homelab/`](examples/homelab/), along with a full workload
registration. Both are the author's homelab wiring rather than part of the
installer — see that folder's README for what they assume.

## Uninstall

```sh
ansible-playbook playbooks/uninstall.yml            # stop + remove everything
ansible-playbook playbooks/uninstall.yml -e ace_purge=true   # also delete ~/ace
```

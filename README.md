# ace-containerized-installer

Deploys the **ACE control plane** (gateway, controller, EDA, hub and receptor)
onto a single EL9 host as **rootless podman containers managed by systemd user
units**. Every platform image is built from upstream source by
[ace-images](https://github.com/sammonsjl/ace-images) and pulled from GHCR.

```
                       ┌──────────────────────────────── ACE host (EL9) ─┐
   https://:443  ──►   envoy (automation-gateway-proxy)                  │
                       │   routes and auth pushed by the gateway (gRPC)  │
                       ├──► gateway   nginx :8446 ──► uwsgi :8052        │
                       │      (jewel + platform UI; gRPC :50051)         │
                       ├──► controller nginx :8443 ──► uwsgi / daphne    │
                       │      (web · task · rsyslog)                     │
                       │      receptor ──► host podman ──► EE jobs       │
                       ├──► eda       nginx :8445 ──► gunicorn / daphne  │
                       │      (api · daphne · two dispatcherd workers)   │
                       ├──► hub       nginx :8444 ──► pulp api / content │
                       │      (api · content · worker)                   │
                       │                                                 │
                       │  postgres :5432 (one DB per component)          │
                       │  redis-tcp :6379 (TLS, gateway)                 │
                       │  redis-unix (socket, controller + hub)          │
                       └─────────────────────────────────────────────────┘
```

The gateway registers each component as a service, and envoy routes to it:
`/api/controller/`, `/api/galaxy/`, `/api/eda/`, and `/` for the gateway itself.
firewalld admits only 443 and 80. Every other port is internal to the host.

## Provenance & licensing

Every file in this repo is written from scratch against upstream project
documentation (envoy, nginx, uwsgi, redis, postgres, AWX, django-ansible-base,
jewel, galaxy_ng, eda-server, receptor).

Apache-2.0. Full provenance and trademark statement in [`NOTICE`](NOTICE).

## Prerequisites

- Terraform ≥ 1.5 and Ansible on the machine you run this from
- An SSH keypair at `~/.ssh/ace_lab_ed25519` / `.pub` (override with
  `-var ssh_public_key_path=…`)
- `jq` and `curl` for the verification scripts
- Outbound access from the guest to `ghcr.io` and `docker.io`

## Building the host: KVM or Proxmox

Two Terraform roots build the host. Use `terraform/kvm/` for a VM on the
machine in front of you, or `terraform/proxmox/` for one on a Proxmox VE node.

| | `terraform/kvm/` | `terraform/proxmox/` |
|---|---|---|
| Where | this machine, libvirt `qemu:///system` | a Proxmox VE node (`node_name`) |
| Size | 8 GB / 4 vCPU / 60 GB thin | 16 GB / 8 vCPU / 100 GB |
| Network | its own NAT network `ace`, 192.168.145.0/24, reachable from this machine only | bridge `vmbr0`, static address on the LAN |
| Address | `192.168.145.45` | `192.168.1.45` |
| Inventory | `inventory/kvm.yml` (the default in `ansible.cfg`) | `inventory/homelab.yml` |
| Provider | `dmacvicar/libvirt` 0.9.9 | `bpg/proxmox` 0.111.1 |

What the two have in common:

- The same pinned Rocky 9.8 GenericCloud image. Preflight requires an EL9
  family host, so Fedora won't do.
- The same `terraform/cloud-init/user-data.yaml.tftpl`, which:
  - creates the `rocky` user with passwordless sudo and your key
  - installs qemu-guest-agent
  - lowers `ip_unprivileged_port_start` to 80, so the first install binds 443
    rootless without a reboot
  - gives the user a subuid/subgid range for rootless podman
  - grows the root filesystem
- A shared output, `ace_host` (name, ip, user, url).

Because both build the same guest, the playbooks don't care which root built it.

### Local KVM

Needs libvirtd running and your user in the `libvirt` group. It also needs
hardware virtualization: `/dev/kvm` must exist, i.e. VT-x/AMD-V enabled in the
firmware. Without it, `-var domain_type=qemu` runs the guest under software
emulation, which is enough to prove the plumbing but far too slow to be useful.

```sh
terraform -chdir=terraform/kvm init
terraform -chdir=terraform/kvm apply
```

The root creates its own libvirt network (`ace`) and storage pool (`ace`,
`/var/lib/libvirt/images/ace`), and `terraform destroy` removes both. The guest's
serial console is logged to `/var/log/libvirt/qemu/ace-console.log`
(root-readable), and `virsh console ace` attaches to it. On a laptop the host
is SSH-ready in about 80 seconds, and the install takes about 20 minutes (see [`VERIFIED.md`](VERIFIED.md)).

### Proxmox

Put the connection details in `terraform/proxmox/terraform.tfvars`, which is
gitignored:

```hcl
proxmox_endpoint     = "https://<node>:8006"
proxmox_api_token    = "user@realm!tokenid=<uuid>"
proxmox_ssh_username = "root"        # the provider uploads the cloud-init
proxmox_ssh_password = "…"           # snippet over SSH; or proxmox_ssh_agent = true
node_name            = "<node>"
```

On the node, `image_datastore_id` (default `local`) must allow the `import`
content type, and `snippet_datastore_id` (default `local`) must allow
`snippets`. The network is set by `bridge`, `ip`, `gateway_ip`, `netmask` and
`dns_servers`. The VM ID is `vm_id` (default 145).

```sh
terraform -chdir=terraform/proxmox init
terraform -chdir=terraform/proxmox apply
```

### Keeping the inventory in step

Each inventory hard-codes its root's address as the host vars `ansible_host`
and `ace_ip`. If you change a root's `ip`, change the matching inventory too.
They have to be host vars, because inventory-file group vars lose to
`inventory/group_vars/all.yml`.

Tear a host down with `terraform -chdir=terraform/<root> destroy`.

## Install

```sh
ansible-galaxy collection install -r requirements.yml -p ./collections

ansible-playbook playbooks/install.yml                          # KVM (default inventory)
ansible-playbook -i inventory/homelab.yml playbooks/install.yml # Proxmox
```

Then browse to `https://<address>/`, accept the self-signed certificate, and log
in as `admin` with the password in `.secrets/admin_password`.

`.secrets/` (gitignored) holds every generated password and key. That is what
makes re-runs idempotent, so keep it for as long as the host exists.

The install runs these phases in order:

1. preflight
2. host prep (podman, linger, one shared CA, firewalld)
3. image pull
4. postgres
5. redis
6. gateway
7. service registration
8. receptor
9. controller
10. EDA
11. hub
12. a final gateway merge of service data

Everything runs rootless except the preflight package install and host prep.

## Images and pinning

`inventory/group_vars/all.yml` sets `ace_image_tag`, which pins every ACE image
at once (currently `20260928-r1`). ace-images publishes `:latest` plus one
`:YYYYMMDD-r<run>` tag per build. Pin a dated tag so an install months apart
gets the same platform. Bumping it is a one-line change.

| From `ace_registry` (`ghcr.io/sammonsjl`) | Stock public images |
|---|---|
| `ace-gateway`, `ace-controller`, `ace-eda`, `ace-hub`, `ace-receptor`, `ace-ee-minimal`, `ace-de-supported` | `envoyproxy/envoy:v1.33.5`, `postgres:15`, `redis:7`, `nginx:stable` (hub and EDA web), `rockylinux:9` (one-shot CA trust update) |

For offline installs or custom builds, set `ace_images_tar_dir` to a directory
on the host that holds `<image-name>.tar` (e.g. `ace-controller.tar`, from
`podman save`). Any image the registry cannot serve is loaded from there.

## Verifying an install

```sh
scripts/e2e.sh 192.168.145.45           # front door, auth, services, job launch
scripts/workflow-e2e.sh 192.168.145.45  # workflow with an approval node
```

`e2e.sh` checks:

- the UI through envoy
- gateway auth
- the registered services
- the controller, EDA and hub through the gateway
- a launch of the Demo Job Template, to completion

Everything goes through 443. Once the gateway is wired in, the controller only
accepts gateway-issued auth. [`VERIFIED.md`](VERIFIED.md) records each verified
install and the image set it used.

## Self-service portal wrapper

The self-service automation portal syncs job templates but not workflow job
templates. So to offer a workflow there, you wrap it in a thin job template
that launches it through the gateway API:

```sh
scripts/portal-workflow.sh 192.168.1.45                          # the demo workflow
ansible-playbook -i inventory/homelab.yml playbooks/portal-wrapper.yml
```

`portal-wrapper.yml` points `controller_url` at the Proxmox host. Pass
`-e controller_url=https://<address>` for any other.

## Design notes

| Choice | Why |
|---|---|
| `postgres:15` / `redis:7` from docker.io | public images, tuned with mounted config and args |
| preflight installs OS packages (`dnf`) | a stock EL9 cloud image installs cleanly with nothing done by hand |
| service registration over plain REST (`ansible.builtin.uri`) | the collection that wraps this API isn't published upstream |
| redis server-TLS + password, no client certs | single host, loopback only |
| receptor on a local control socket, no mesh TLS or work signing | single node |
| `generate_systemd` user units, not quadlets | the unit comes from the same `podman_container` task that defines the container |
| `network: host` everywhere | one host, so components are separated by port |
| `userns: keep-id`, except postgres | the official postgres image expects uid 999, mapped onto the host user instead |
| podman secrets for anything carrying credentials | settings files with passwords never sit on disk |
| one self-signed CA, ownca-signed component certs | also installed into the host trust store |
| ephemeral init containers | migrations and bootstrap run once, then exit |
| `~/ace/<component>/` config layout | one tree per component, removed by `uninstall.yml -e ace_purge=true` |

### aarch64 note

Some virtualized aarch64 guests (seen under VMware Fusion on Apple Silicon)
kill any Python process that imports `cryptography` with SIGILL (exit 132),
unless `OPENSSL_armcap=0` is set. The playbook sets it at play level (which
covers Ansible modules on the host), on every container, and via
`AWX_TASK_ENV` for execution-environment jobs. It is harmless on x86_64.

## Kubernetes execution plane

You can point the controller at an outside Kubernetes cluster so that jobs run
there as pods through a container group. That needs two things:

- a cluster-side contract: a namespace, ServiceAccount, Role and token
- controller-side wiring: a bearer-token credential and a container group

A worked example of the controller side is in
[`examples/homelab/`](examples/homelab/), along with a full workload
registration. Both are the author's homelab wiring rather than part of the
installer. See that folder's README for what they assume.

## Uninstall

```sh
ansible-playbook playbooks/uninstall.yml                     # stop + remove everything
ansible-playbook playbooks/uninstall.yml -e ace_purge=true   # also delete ~/ace
```

`uninstall.yml` has not been verified end to end yet. For a lab host,
`terraform destroy` is the reliable reset.

# ace-containerized-installer

Deploys the **ACE control plane** — the open-source mirror of Ansible Automation
Platform's gateway + controller — as **rootless podman containers managed by
systemd user units**, using the exact mechanics of Red Hat's containerized
installer, rebuilt from scratch on upstream images.

```
                       ┌────────────────────────── ace-installer VM ─┐
   https://:443  ──►   envoy (automation-gateway-proxy)              │
                       │   dynamic LDS/CDS from the gateway          │
                       ├──► gateway nginx :8446 ──► uwsgi :8052      │
                       │       (ace-gateway: jewel + platform UI)    │
                       │       gRPC control plane :50051             │
                       ├──► controller nginx :8443 ──► uwsgi :8050   │
                       │       (awx:devel — web / task / rsyslog)    │
                       │       receptor ──► podman ──► awx-ee jobs   │
                       │  postgres :5432 · redis-tcp :6379 (TLS)     │
                       │  redis-unix (socket, controller broker)     │
                       └─────────────────────────────────────────────┘
```

## Provenance & licensing

The Red Hat AAP containerized setup bundle was used strictly as a **behavioral
spec** — container topology, task ordering, port map, config-key semantics.
Every file in this repo is written from scratch against upstream project
documentation (envoy, nginx, uwsgi, redis, postgres, AWX, django-ansible-base,
jewel). No Red Hat content is included. Apache-2.0.

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

# 4. Log in
open https://192.168.56.30/     # accept the self-signed cert
cat .secrets/admin_password
```

## Design notes (where we deliberately differ from the bundle)

| Bundle | Here | Why |
|---|---|---|
| RHEL9 SCL postgres/redis images | `postgres:15` / `redis:7` (docker.io) | public images; tuning via mounted conf/args instead of SCL env vars |
| OS packages installed by the customer per docs | Vagrant shell provisioner | keeps the Ansible run 100 % rootless, same split |
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

## Uninstall

```sh
ansible-playbook playbooks/uninstall.yml            # stop + remove everything
ansible-playbook playbooks/uninstall.yml -e ace_purge=true   # also delete ~/ace
```

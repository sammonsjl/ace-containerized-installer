# Verified install — 2026-09-10

A full `install.yml` run against a fresh Rocky 9.8 host on Proxmox, with every
platform component built from upstream source by `ace-images`.

    PLAY RECAP
    ace-installer : ok=217  changed=78  unreachable=0  failed=0  skipped=8

## What ran

    == UI login page via envoy :443
    == Gateway auth (/api/gateway/v1/me/)        admin
    == Registered services
         controller -> /api/controller/  (order 1)
         galaxy     -> /api/galaxy/      (order 2)
         eda        -> /api/eda/         (order 3)
         gateway    -> /                 (order 100)
    == Controller through the gateway            ace / hybrid
    == EDA through the gateway                   good
    == Hub through the gateway                   good
    == Launch Demo Job Template through the gateway
         job template 6, job 1 -> successful
    E2E PASSED

The job launch is the load-bearing one: the controller handed work to
`ace-receptor`, which spawned `ace-ee-minimal` through the host podman socket
and ran it to completion.

## Images in use

Every ACE component is ours:

    ghcr.io/sammonsjl/ace-controller   3 containers
    ghcr.io/sammonsjl/ace-eda          4
    ghcr.io/sammonsjl/ace-hub          3
    ghcr.io/sammonsjl/ace-gateway      1
    ghcr.io/sammonsjl/ace-receptor     1

Deliberately upstream, and nothing else:

    docker.io/envoyproxy/envoy:v1.33.5   1   (bazel; not the lesson)
    docker.io/library/nginx:stable       2   (hub-web and eda-web muxes)
    docker.io/library/postgres:15        1
    docker.io/library/redis:7            2

## What this run proved about the changes

- The gateway moved to the `/opt/aap-gateway` prefix with its console and
  static under `/var/lib/ansible-automation-platform/platform/ui`. A first run
  against the old published image failed exactly here — `can't find command
  /opt/aap-gateway/venv/bin/uwsgi`, nginx returning 502 — which is what the
  path change was for.
- `ace-receptor` runs with no host podman bind-mounts. It ships podman itself
  and reaches the host socket as a remote client.
- `eda-web` runs stock nginx. `quay.io/ansible/eda-ui` was only ever supplying
  the nginx binary.

## Second run — from GHCR, 2026-09-10

The first run used images side-loaded over SSH, because nothing was published
yet. Repeated after CI published all eight, with `ace_image_tag` pinned to the
dated tag so every image had to come from the registry:

    PLAY RECAP
    ace-installer : ok=190  changed=41  unreachable=0  failed=0  skipped=33

    E2E PASSED   (job template 6, job 3 -> successful)

Every container now runs `ghcr.io/sammonsjl/ace-*:20260910-11f2029` — built by
GitHub Actions from pinned upstream commits, pulled anonymously from a public
registry. All eight packages are anonymously pullable.

Each image carries the commit it was built from:

    ace.source.ref=94333d005e22acdf35706f289981af8da711a943   (ace-controller -> ansible/awx)
    org.opencontainers.image.revision=11f2029a...             (the ace-images commit)

## Third run — latest upstream, 2026-09-28

ace-images' `build-all` now builds every image from the current head of each
upstream branch rather than the Containerfile pins. Its first such run
published `20260928-r1`; this install pinned `ace_image_tag` to it, on a fresh
VM 145:

    PLAY RECAP
    ace-installer : ok=230  changed=121  unreachable=0  failed=0  skipped=3

    E2E PASSED            (job template)
    WORKFLOW E2E PASSED   (approval workflow: approve runs Step B, deny runs Step C)
    portal-workflow.sh    exit 0 (three-step workflow, all nodes successful)
    role_level filter     200 for notification_admin_role / admin_role / read_role

Every ACE container runs `ghcr.io/sammonsjl/ace-*:20260928-r1`, built from:

    ansible/jewel               e680bd8   ansible/ansible-ui   3eb11da
    ansible/awx                 cf3dd7d   ansible/galaxy_ng    43a6d2d
    ansible/eda-server          f572026   ansible/receptor     18ecf6e
    django-ansible-base         5d0c475   (the same commit in gateway and hub)

Both patches the controller role applies to its image — `licensing.py` and
DAB's `field_lookup_backend.py` — still found their anchors in the new AWX and
DAB, so neither upstream moved underneath them.

## Fourth run — local KVM, 2026-09-28

The same `20260928-r1` images, on a VM built by the new `terraform/kvm/` root
instead of Proxmox: libvirt on a laptop (i5-8350U, 16 GB), the guest at 8 GB /
4 vCPU with host-passthrough CPU, on the root's own NAT network at
`192.168.145.45` (`inventory/kvm.yml`). `terraform apply` to SSH-ready with
cloud-init finished took 78 s, including the image download; the install took
about 20 minutes.

    PLAY RECAP
    ace-installer : ok=230  changed=121  unreachable=0  failed=0  skipped=3

    E2E PASSED            (job template 6, job 1 -> successful)

So the 8 GB / 4 vCPU size is enough for the whole control plane plus a job.

## Caveats

- `ace-git-server` and `ace-de-supported` are built and published but were not
  exercised by this run; the decision environment is registered, not fired.
- `uninstall.yml` remains untested.

# Homelab examples

These two playbooks are the author's own homelab wiring, kept as worked
examples. They are **not part of the installer**, and they target a design the
homelab has since retired: ACE's control plane on this podman VM, with a Talos
cluster (yojimbo) used only as the execution plane through container groups.
That homelab now runs all of ACE on Kubernetes with
[ace-operator](https://github.com/sammonsjl/ace-operator) instead.

| Playbook | What it shows |
|---|---|
| `wire-execution-plane.yml` | Pointing a running controller at an outside Kubernetes cluster: a bearer-token credential plus a container group, so jobs run as pods there. Reusable — override the `plane_*` vars. |
| `wire-workloads.yml` | Registering one real workload end to end: a manual project, a custom credential type seeded from a cluster secret, an inventory, a dedicated container group and the job template. |

What they assume, and which parts no longer exist:

- **The cluster-side contract** — a namespace, ServiceAccount, Role and
  long-lived token for job pods — lived in the homelab repo at
  `infrastructure/configs/yojimbo/ace-jobs/`. It has been removed there.
  Recreate the equivalent in whatever cluster you point these at.
- **Hard-wired homelab values:** the controller at `https://192.168.1.45`,
  yojimbo's API at `192.168.1.20:6443`, kubectl context `admin@yojimbo`, and
  `ace-ee-minimal:latest` rather than a pinned tag. They run standalone, so
  inventory `group_vars` — including `ace_image_tag` — do not apply.
- **`wire-workloads.yml` reads its project from `~/code/homelab/ansible`.** The
  homelab repo now lives at `~/projects/homelab`, and the cleanup playbook it
  delivers was only ever on an unpushed branch, so this one does not run as-is.

Both lessons they encode are still worth knowing: files added to
`PROJECTS_ROOT` after the controller starts need an SELinux relabel to
`container_file_t`, and AWX's default pod spec forces
`automountServiceAccountToken: false` and forbids overriding it, so a container
group that needs a ServiceAccount token has to mount a projected one by hand.

Run from the repository root:

```sh
ansible-playbook examples/homelab/wire-execution-plane.yml
ansible-playbook -i inventory/homelab.yml examples/homelab/wire-workloads.yml
```

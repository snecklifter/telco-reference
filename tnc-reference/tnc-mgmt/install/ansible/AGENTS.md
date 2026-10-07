# Ansible Automation for TNC Management Cluster Deployment

## Overview

This Ansible playbook automates end-to-end deployment of an OpenShift 4.22 management (hub) cluster using the agent-based installer on bare metal Supermicro servers, with full day-2 configuration via Ansible roles.

## Playbooks

- `playbook.yaml` — Main playbook with two plays: `install` and `configure` (use `--tags` to run one).
- `update-dns.yaml` — Zone-only DNS update without running the full install.
- `wipe-disks.yaml` — Destructive disk wipe for rebuilds (requires confirmation).
- `get-macs.yaml` — Discover MAC addresses from BMCs via Redfish.

All playbooks accept `cluster_vars` for per-cluster config: `ansible-playbook playbook.yaml -e cluster_vars=/path/to/mgmt1.yaml`

## Play and Role Order

### Install play (`--tags install`)
`bmc_harden → validate → prerequisites → dns → manifests → boot`

### Configure play (`--tags configure`)
`stage_config → storage → vault → certmanager → gitlab → gitops`

## Roles

| Role | Purpose |
|------|---------|
| `bmc_harden` | Disables IPMI over LAN and BMC ToHost USB ethernet via Redfish |
| `validate` | Pre-flight checks on vars.yaml |
| `prerequisites` | Installs RPMs, downloads oc/openshift-install, creates build dir |
| `dns` | BIND DNS container with multi-cluster zone discovery |
| `manifests` | Renders install-config, agent-config, MachineConfigs |
| `boot` | Mounts ISO via Redfish virtual media and boots nodes |
| `stage_config` | Copies configuration tree to staging area, templates overlay patches, fixes catalog source and subscription channels |
| `storage` | Installs LSO, ODF, ACM, CNV, Cluster Logging, Keycloak, DevSpaces operators; labels worker nodes; creates StorageCluster; verifies Ceph health and OSD count |
| `vault` | Deploys Vault Enterprise via Helm, initializes, unseals, configures KV/auth, installs ESO, creates ClusterSecretStore |
| `certmanager` | Installs cert-manager, DNS webhook solver, issues Let's Encrypt wildcard cert, patches IngressController defaultCertificate |
| `gitlab` | Installs EDB CNPG PostgreSQL cluster, GitLab operator, Redis, creates Routes, initializes GitLab (user, group, project, push repo) |
| `gitops` | Installs OpenShift GitOps, applies full kustomize configuration, creates ArgoCD Application |

## Key Constraints

- **All config in vars.yaml** — overlay files and kustomization files are never modified; all customization is via Ansible templates rendered to the staging area
- **Everything from scratch** — nothing is pre-populated in Vault or created outside the playbook
- **No secrets in code** — all templates use REDACTED placeholders; credentials use `no_log: true`
- **Idempotent** — roles use `oc apply`, check-before-create patterns, and conditional execution

## File Structure

- `vars.yaml` — All cluster configuration: networking, storage, BMC credentials, host inventory, day-2 component config. Contains REDACTED placeholders for secrets.
- `templates/` — Jinja2 templates rendered by Ansible (see templates section below)
- `roles/` — Ansible roles (see role table above)

### Configuration Templates (`templates/configuration/`)

| Template | Renders to |
|----------|-----------|
| `kustomization.yaml.j2` | Top-level kustomization with component selection from vars.yaml |
| `cert-manager-subscription.yaml.j2` | cert-manager operator Namespace/OperatorGroup/Subscription |
| `certmanager-config.yaml.j2` | CertManager CR with public DNS recursive nameservers for ACME |
| `certmanager-dns-webhook.yaml.j2` | DNS-01 webhook solver (13 K8s resources: RBAC, PKI, Deployment, Service, APIService) |
| `certmanager-dns-credentials-es.yaml.j2` | ExternalSecret for DNS API credentials from Vault |
| `certmanager-clusterissuer.yaml.j2` | Let's Encrypt production ClusterIssuer with DNS-01 webhook solver |
| `certmanager-wildcard-cert.yaml.j2` | Wildcard Certificate + IngressController defaultCertificate patch |
| `cnpg-operator.yaml.j2` | EDB CloudNativePG operator Namespace/OperatorGroup/Subscription |
| `eso-subscription.yaml.j2` | External Secrets Operator Namespace/OperatorGroup/Subscription |
| `eso-config.yaml.j2` | ExternalSecretsConfig CR with egress network policy |
| `eso-clustersecretstore.yaml.j2` | ClusterSecretStore for Vault with per-cluster auth paths |
| `gitlab-cnpg-cluster.yaml.j2` | EDB CNPG PostgreSQL 3-instance HA cluster for GitLab |
| `gitlab-external-secrets.yaml.j2` | ExternalSecrets for GitLab (object-storage, postgres, redis, registry, CNPG creds) |
| `gitlab-routes.yaml.j2` | OpenShift Routes for GitLab webservice and pages |
| `vault-route.yaml.j2` | OpenShift Route for Vault external access |
| `keycloak-operator.yaml.j2` | Red Hat Build of Keycloak operator |
| `devspaces-operator.yaml.j2` | DevSpaces operator |

### Install Templates (`templates/`)

| Template | Purpose |
|----------|---------|
| `install-config.yaml.j2` | OpenShift install-config with optional mirror registry |
| `agent-config.yaml.j2` | Agent config with bonded interfaces, VLANs, per-host networking |
| `named.conf.j2` | BIND named.conf with multi-cluster zone discovery |
| `zone.db.j2` | DNS zone file with API, ingress, and host A records |
| `raid-mirror.yaml.j2` | MachineConfig for RAID 1 boot mirror across two NVMe disks |

## Key Technical Details

### Jinja2 Templates

**Do NOT use `{%-` in templates.** Ansible sets `trim_blocks=True` and `lstrip_blocks=True` by default. Using `{%-` causes double whitespace stripping, collapsing YAML onto single lines. Always use `{%` instead.

**Jinja2 dict method collision:** When iterating over a dict key named `keys`, `items`, `values`, or `update`, use bracket notation (`s["keys"]`) not dot notation (`s.keys`) — Jinja2 resolves the latter to the dict method.

### DNS Container

Uses the Red Hat hardened BIND image (`registry.access.redhat.com/hi/bind:latest`):
- Runs as non-root (UID 65532), listens on port **8053** (not 53)
- Mount custom config to `/etc/named/hbird-defaults.conf:ro,Z`
- **Never mount over `/var/named`** — BIND requires it writable as its working directory. Mount zone files into a subdirectory: `-v zones:/var/named/zones:ro,Z` and reference them with absolute paths in named.conf (`file "/var/named/zones/<zone>.zone"`)
- Port mapping `53:8053` via podman handles the port translation
- Do NOT mount to `/etc/named/conf.d/local.conf` with an `options` block — the base config already defines one and BIND rejects redefinitions
- Multi-cluster: zone files are discovered dynamically; named.conf is regenerated from all `.zone` files

### Networking

- bond0: cluster network (optional VLAN via `networking.vlan_id`)
- bond1: storage network for ODF (VLAN via `networking.storage_network.vlan_id`)
- Interface names are shared across all nodes via `interface_layout`
- Per-host: IP, storage IP, BMC address, BMC credentials, MAC addresses

### Storage

- Software RAID 1 boot mirror across two NVMe OS disks via Ignition/MachineConfig
- Uses `--metadata=1.0` to preserve filesystem at start of partition
- ODF health check verifies Ceph HEALTH_OK and OSD count matches workers × disks

### BMC / Redfish

- Uses `community.general.redfish_command` for virtual media mount and boot
- Per-host BMC credentials (different passwords per node)
- ISO served via local httpd on port 80
- BMC hardening disables IPMI over LAN and ToHost USB ethernet interface

### External Secrets (ESO)

- External Secrets Operator replaces Vault Secrets Operator (VSO)
- ClusterSecretStore `vault-backend` connects to Vault via Kubernetes auth
- Per-cluster Vault paths: KV mount at `configuration.vault.secret_path`, K8s auth at `configuration.vault.mount_path`
- ExternalSecretsConfig CR must be applied AFTER the CRD exists (separate from Subscription)

### cert-manager and TLS

- cert-manager uses `--dns01-recursive-nameservers-only` with public DNS (8.8.8.8, 1.1.1.1) for ACME zone lookups — prevents cluster-internal BIND from returning the wrong SOA for subdomain zones
- DNS-01 webhook solver listens on port **8443** (not 443) — OpenShift denies privileged ports. Flag: `--secure-port=8443`
- Wildcard cert set as IngressController `defaultCertificate` — all Routes get TLS automatically

### PostgreSQL (CNPG)

- EDB CloudNativePG provides 3-instance HA PostgreSQL for GitLab
- `max_locks_per_transaction: 256` required for GitLab migrations (default 64 causes "out of shared memory")
- Bootstrap credentials synced from Vault via ExternalSecret (`gitlab-postgres-creds`)
- CNPG service name `gitlab-postgres-rw` matches GitLab's `psql.host` config
- Enterprise image requires pull secret for `docker.enterprisedb.com`

### Operator Installation Pattern

Operators with CRs in the kustomize build must be pre-installed in the `storage` role (or before the kustomize apply) so their CRDs exist. Currently pre-installed: LSO, ODF, ACM, CNV, Cluster Logging, Keycloak, DevSpaces. The `stage_config` role fixes `redhat-operators-disconnected` → `configuration.catalog_source` in both `reference-crs/` and `other-crs/`.

### OpenShift Routes (not GatewayAPI)

External access for Vault and GitLab uses OpenShift Routes with edge TLS termination. GatewayAPI is not used because OpenShift 4.22 system components (console, OAuth, monitoring) only support Routes — there is no migration path to HTTPRoutes for system components yet.

## Running

```bash
# Full install + configure
ansible-playbook playbook.yaml

# Configure only (cluster already installed)
ansible-playbook playbook.yaml --tags configure

# Resume from a specific task
ansible-playbook playbook.yaml --tags configure --start-at-task "Check if Vault is initialized"

# Per-cluster vars override
ansible-playbook playbook.yaml -e @/path/to/overrides.yaml
```

Requires: sudo access (for httpd, firewalld, podman), pull secret, SSH key, BMC credentials in vars.yaml.

## Dependencies

Installed automatically by the playbook:
- RPM packages: httpd, nmstate
- Ansible collections: community.general, ansible.posix
- Binaries: openshift-install, oc (downloaded from mirror.openshift.com)

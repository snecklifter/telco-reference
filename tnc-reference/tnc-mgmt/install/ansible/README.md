# OpenShift Management Cluster Automation

Automated end-to-end deployment of an OpenShift 4.22 management (hub) cluster on bare metal Supermicro servers using the agent-based installer, with full day-2 configuration.

## What Gets Installed

### Install Phase

| Step | Description |
|------|-------------|
| **GitLab Backup** | Backs up existing GitLab data and database before re-provisioning (automatic, skippable) |
| **BMC Hardening** | Disables IPMI over LAN and BMC ToHost USB ethernet on all servers via Redfish |
| **Validation** | Pre-flight checks on vars.yaml configuration |
| **Prerequisites** | Downloads `openshift-install` and `oc` binaries (auto-updates to latest patch) |
| **DNS** | Deploys BIND DNS on the bastion for cluster name resolution during install |
| **Manifests** | Generates install-config, agent-config, MachineConfigs (RAID mirror, etcd encryption) |
| **Boot** | Mounts agent ISO via Redfish virtual media and boots all nodes |

### Configure Phase

| Step | Description |
|------|-------------|
| **Stage Config** | Copies kustomize configuration to staging area, templates overlay patches |
| **Storage** | Installs MetalLB, LSO, ODF (with Ceph health verification), ACM, CNV, Cluster Logging, Keycloak operator, DevSpaces operator |
| **Cluster DNS** | Deploys HA BIND DNS inside the cluster on a dedicated VLAN with MetalLB load balancing, replaces bastion DNS |
| **Vault** | Deploys Vault Enterprise (Helm), initializes, unseals, configures KV engine and Kubernetes auth, installs External Secrets Operator |
| **cert-manager** | Installs cert-manager, DNS webhook solver, issues Let's Encrypt wildcard and API certificates, updates kubeconfig |
| **Keycloak** | Deploys RHBK with CNPG HA database, creates SSO realm with OIDC clients for OpenShift, GitLab, NetBox, and AAP |
| **NetBox** | Deploys NetBox via Helm with CNPG database, Keycloak SSO with JWKS token verification, S3 backups |
| **AAP** | Deploys Ansible Automation Platform (Controller, Hub, EDA) with shared CNPG database (4 databases), S3 storage for Hub |
| **GitLab** | Deploys GitLab operator with CNPG database, Redis, creates Routes, initializes repo, restores from backup if available |
| **GitOps** | Installs OpenShift GitOps (ArgoCD), applies full kustomize configuration |

### Security Features

- etcd encryption enabled at install time (AES-CBC)
- Let's Encrypt TLS for `*.apps` and API server
- All secrets generated in Vault, synced via External Secrets Operator
- Keycloak SSO for OpenShift console, GitLab, NetBox, and AAP
- BMC IPMI disabled, ToHost USB ethernet disabled
- DNS isolated on dedicated VLAN

## Prerequisites

- Bastion host with: sudo access, SSH key, Ansible, Python 3
- Network: bare metal servers with BMC/Redfish access, DHCP or static IPs
- DNS: upstream forwarders (default 8.8.8.8, 1.1.1.1)
- Pull secret from console.redhat.com (include EDB registry credentials for CNPG)

## Configuration

All configuration is in `vars.yaml`. For per-cluster overrides, create a separate file and pass it with `-e @overrides.yaml`.

Key sections:
- `cluster` — name, domain, OCP version
- `networking` — VIPs, VLANs, DNS, MetalLB pool
- `storage` — OS disks for RAID mirror, ODF disk paths
- `configuration.components` — comment out any line to exclude that component
- `hosts` — per-node: hostname, role, IP, BMC credentials, MAC addresses

## Running

### Fresh install (full deployment)

```bash
ansible-playbook playbook.yaml -e @/path/to/overrides.yaml
```

This runs both the install and configure phases sequentially. The install phase
deploys the OpenShift cluster, and the configure phase installs all day-2
components.

### Configure only (cluster already installed)

```bash
ansible-playbook playbook.yaml --tags configure -e @/path/to/overrides.yaml
```

Skips the install phase entirely. Use this when the cluster is already running
and you want to apply or re-apply day-2 configuration.

### Skip GitLab backup

```bash
ansible-playbook playbook.yaml --skip-tags backup -e @/path/to/overrides.yaml
```

The backup role runs by default at the start of the install play. It
automatically detects a running GitLab instance and backs up the database,
repositories, and secrets to `/opt/backups/`. Skip it for a completely fresh
deployment with no prior data.

### Resume from a specific task

```bash
ansible-playbook playbook.yaml --tags configure --start-at-task "Check if Vault is initialized" -e @/path/to/overrides.yaml
```

Useful when re-running after a failure. Start from the Vault step when
subsequent roles need `vault_root_token` (Keycloak, NetBox, AAP, GitLab).

### Common resume points

| Starting from | Command |
|---------------|---------|
| Vault (needed for most roles) | `--start-at-task "Check if Vault is initialized"` |
| cert-manager | `--start-at-task "Render cert-manager manifests"` |
| Keycloak | `--start-at-task "Render Keycloak manifests"` |
| DNS (cluster) | `--start-at-task "Discover all zone files from bastion DNS"` |
| GitLab | `--start-at-task "Render GitLab manifests"` |
| AAP | `--start-at-task "Render AAP manifests"` |
| Kustomize apply | `--start-at-task "Apply full configuration via kustomize"` |

### Excluding components

Comment out components in `vars.yaml` (or overrides) to exclude them:

```yaml
configuration:
  components:
    - talm
    - lso
    - odf
    - gitops
    - acm
    - vault
    # - quay          # commented out = excluded
    - logging
    - cnv
    - keycloak
    - netbox
    - aap
    - devspaces
```

### Other playbooks

```bash
# Update DNS zones without reinstalling
ansible-playbook update-dns.yaml -e @/path/to/overrides.yaml

# Wipe disks for rebuild (destructive, requires confirmation)
ansible-playbook wipe-disks.yaml -e @/path/to/overrides.yaml

# Discover MAC addresses from BMCs
ansible-playbook get-macs.yaml -e @/path/to/overrides.yaml
```

## Backup and Restore

### Automatic backup (before re-provisioning)

The backup role runs at the start of the install play. If a running GitLab
instance is detected, it:

1. Creates a full GitLab application backup (repos, uploads, artifacts)
2. Dumps the CNPG PostgreSQL database
3. Exports GitLab secrets (rails secret, initial root password)
4. Stores everything at `/opt/backups/` on the bastion

### Automatic restore (after re-provisioning)

At the end of the configure play, the GitLab role checks for backup files at
`/opt/backups/`. If found, it automatically:

1. Restores GitLab secrets
2. Restores the database from the pg_dump
3. Copies and restores the application backup via the toolbox

No manual intervention needed — a full re-provision preserves GitLab data.

# Ansible Automation for TNC Management Cluster Deployment

## Overview

This Ansible playbook automates end-to-end deployment of an OpenShift management (hub) cluster using the agent-based installer on bare metal Supermicro servers.

## File Structure

- `playbook.yaml` — Main playbook. Phases: Validation, Prerequisites, DNS Server, Generate Manifests, Generate ISO, Boot Nodes via Redfish, Wait for Installation.
- `vars.yaml` — All cluster configuration: networking, storage, BMC credentials, host inventory. Contains REDACTED placeholders for secrets.
- `templates/` — Jinja2 templates rendered by Ansible:
  - `install-config.yaml.j2` — OpenShift install-config with optional mirror registry support
  - `agent-config.yaml.j2` — Agent config with bonded interfaces, VLANs, and per-host networking
  - `named.conf.j2` — BIND config snippet for the DNS container
  - `zone.db.j2` — DNS zone file with API, ingress, and host A records
  - `raid-mirror.yaml.j2` — MachineConfig for software RAID 1 boot mirror across two NVMe disks

## Key Technical Details

### Jinja2 Templates

**Do NOT use `{%-` in templates.** Ansible sets `trim_blocks=True` and `lstrip_blocks=True` by default. Using `{%-` causes double whitespace stripping, collapsing YAML onto single lines. Always use `{%` instead.

Test templates locally with Ansible-equivalent settings:
```python
env = Environment(loader=FileSystemLoader('templates'), trim_blocks=True, lstrip_blocks=True)
```

### DNS Container

Uses the Red Hat hardened BIND image (`registry.access.redhat.com/hi/bind:latest`):
- Runs as non-root (UID 65532), listens on port **8053** (not 53)
- Mount custom config to `/etc/named/hbird-defaults.conf:ro,Z` (replaces default config)
- Mount zone files to `/var/named/<zone>.zone:ro,Z`
- Files must be readable by UID 65532 (`chmod a+rX`)
- Port mapping `53:8053` via podman handles the port translation
- Do NOT mount to `/etc/named/conf.d/local.conf` with an `options` block — the base config already defines one and BIND rejects redefinitions
- Upstream source: https://gitlab.com/redhat/hummingbird/containers (images/bind)

### Networking

- bond0: cluster network (optional VLAN via `networking.vlan_id`)
- bond1: storage network for ODF (VLAN via `networking.storage_network.vlan_id`)
- Interface names are shared across all nodes via `interface_layout`
- Per-host: IP, storage IP, BMC address, BMC credentials, MAC addresses

### Storage

- Software RAID 1 boot mirror across two NVMe OS disks via Ignition/MachineConfig
- Uses `--metadata=1.0` to preserve filesystem at start of partition
- Workers have additional ODF storage disks (not managed by this automation)

### BMC / Redfish

- Uses `community.general.redfish_command` for virtual media mount and boot
- Per-host BMC credentials (different passwords per node)
- ISO served via local httpd on port 80

## Running

```bash
ansible-playbook playbook.yaml
```

Requires: sudo access (for httpd, firewalld, podman), pull secret, SSH key, BMC credentials in vars.yaml.

## Dependencies

Installed automatically by the playbook:
- RPM packages: httpd, nmstate
- Ansible collections: community.general, ansible.posix
- Binaries: openshift-install, oc (downloaded from mirror.openshift.com)

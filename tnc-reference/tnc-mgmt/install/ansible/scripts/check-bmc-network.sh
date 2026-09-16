#!/bin/bash
# Show BMC network configuration (interfaces, IPs, gateway, VLAN)
# Usage: ./check-bmc-network.sh BMC_ADDRESS USERNAME PASSWORD

set -euo pipefail

BMC_ADDRESS="${1:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"
USERNAME="${2:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"
PASSWORD="${3:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"

IFACES_URL=$(curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}/redfish/v1/Managers/1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['EthernetInterfaces']['@odata.id'])")

echo "=== BMC Network Interfaces ==="
MEMBERS=$(curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}${IFACES_URL}" \
  | python3 -c "import sys,json; [print(m['@odata.id']) for m in json.load(sys.stdin).get('Members',[])]")

for path in ${MEMBERS}; do
  iface=$(basename "${path}")
  echo "--- ${iface} ---"
  curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}${path}" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
addrs = d.get('IPv4Addresses',[])
gw = d.get('IPv4DefaultGateway','')
vlan = d.get('VLAN',{})
print(f\"  Status:   {d.get('Status',{}).get('State','unknown')}\")
for a in addrs:
    print(f\"  IPv4:     {a.get('Address','')}/{a.get('SubnetMask','')} (origin: {a.get('AddressOrigin','')})\")
    addr_gw = a.get('Gateway','')
    if addr_gw:
        print(f\"  Gateway:  {addr_gw} (from IPv4Addresses)\")
if gw:
    print(f\"  Gateway:  {gw} (from IPv4DefaultGateway)\")
static_routes = d.get('IPv4StaticRoutes',[])
if static_routes:
    for r in static_routes:
        print(f\"  Route:    {r}\")
if vlan:
    print(f\"  VLAN:     Enabled={vlan.get('VLANEnable',False)} Id={vlan.get('VLANId','')}\")
nameservers = d.get('NameServers',[])
if nameservers:
    print(f\"  DNS:      {nameservers}\")
"
done

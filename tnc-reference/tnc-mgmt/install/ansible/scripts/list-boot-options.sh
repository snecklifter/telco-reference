#!/bin/bash
# List all Redfish boot options for a Supermicro BMC
# Usage: ./list-boot-options.sh BMC_ADDRESS USERNAME PASSWORD

set -euo pipefail

BMC_ADDRESS="${1:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"
USERNAME="${2:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"
PASSWORD="${3:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"

echo "=== Boot Order ==="
curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}/redfish/v1/Systems/1" \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['Boot']; print('Order:', d.get('BootOrder',[])); print('OverrideTarget:', d.get('BootSourceOverrideTarget','')); print('OverrideEnabled:', d.get('BootSourceOverrideEnabled','')); print('OverrideMode:', d.get('BootSourceOverrideMode',''))"

echo ""
echo "=== Boot Options ==="
MEMBERS=$(curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}/redfish/v1/Systems/1/BootOptions" \
  | python3 -c "import sys,json; [print(m['@odata.id']) for m in json.load(sys.stdin).get('Members',[])]")

for path in ${MEMBERS}; do
  ref=$(basename "${path}")
  curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}${path}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"  {d.get('Id','?'):10s} {d.get('DisplayName','unknown')}\")"
done

#!/bin/bash
# Check Redfish virtual media status for a Supermicro BMC
# Usage: ./check-virtual-media.sh BMC_ADDRESS USERNAME PASSWORD

set -euo pipefail

BMC_ADDRESS="${1:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"
USERNAME="${2:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"
PASSWORD="${3:?Usage: $0 BMC_ADDRESS USERNAME PASSWORD}"

echo "=== Virtual Media Slots ==="
MEMBERS=$(curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}/redfish/v1/Managers/1/VirtualMedia" \
  | python3 -c "import sys,json; [print(m['@odata.id']) for m in json.load(sys.stdin).get('Members',[])]")

for path in ${MEMBERS}; do
  slot=$(basename "${path}")
  echo "--- ${slot} ---"
  curl -sk -u "${USERNAME}:${PASSWORD}" "https://${BMC_ADDRESS}${path}" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"  Image:        {d.get('Image','(none)')}\")
print(f\"  Inserted:     {d.get('Inserted',False)}\")
print(f\"  Connected:    {d.get('ConnectedVia','unknown')}\")
print(f\"  MediaTypes:   {d.get('MediaTypes',[])}\")
print(f\"  WriteProtect: {d.get('WriteProtected',False)}\")
"
done

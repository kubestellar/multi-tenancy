#!/bin/bash

# Script to automatically find an unused IP and create EgressIP for a tenant
# Usage: ./create-egressip.sh <tenant-name>

set -e

# Check if tenant name is provided
if [ -z "$1" ]; then
  echo "Error: Tenant name is required"
  echo "Usage: $0 <tenant-name>"
  echo "Example: $0 tenant-1"
  exit 1
fi

TENANT_NAME="$1"
NAMESPACE="${TENANT_NAME}"
EGRESS_NAME="${TENANT_NAME}-egress"

echo "Creating EgressIP for tenant: ${TENANT_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "EgressIP name: ${EGRESS_NAME}"
echo ""

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "Error: Namespace '${NAMESPACE}' does not exist"
  echo "Create it first with: kubectl create namespace ${NAMESPACE}"
  exit 1
fi

# Get used IPs from kind nodes
echo "Scanning for used IPs in kind network..."
USED_IPS=$(docker network inspect kind 2>/dev/null | jq -r '.[0].Containers[].IPv4Address' | cut -d'/' -f1)

if [ -z "$USED_IPS" ]; then
  echo "Error: Could not get IPs from kind network"
  echo "Make sure you're using a kind cluster"
  exit 1
fi

echo "Used IPs from Docker network:"
echo "$USED_IPS"
echo ""

# Get IPs already assigned to EgressIP resources
echo "Checking existing EgressIP resources..."
EGRESS_IPS=$(kubectl get egressip -o jsonpath='{.items[*].spec.egressIPs[*]}' 2>/dev/null | tr ' ' '\n')

if [ -n "$EGRESS_IPS" ]; then
  echo "IPs already assigned to EgressIP resources:"
  echo "$EGRESS_IPS"
  echo ""
  # Combine both lists
  ALL_USED_IPS=$(echo -e "${USED_IPS}\n${EGRESS_IPS}" | sort -u)
else
  echo "No existing EgressIP resources found"
  echo ""
  ALL_USED_IPS="$USED_IPS"
fi

# Find first unused IP starting from .5
echo "Finding unused IP in range 172.19.0.5-254..."
UNUSED_IP=""
for i in {5..254}; do
  IP="172.19.0.${i}"
  if ! echo "$ALL_USED_IPS" | grep -q "^${IP}$"; then
    UNUSED_IP="$IP"
    break
  fi
done

if [ -z "$UNUSED_IP" ]; then
  echo "Error: No unused IPs found in range 172.19.0.5-254"
  exit 1
fi

echo "✓ Found unused IP: ${UNUSED_IP}"
echo ""

# Generate EgressIP YAML
YAML_FILE="${TENANT_NAME}-egressip.yaml"
echo "Generating ${YAML_FILE}..."

cat <<EOF > "${YAML_FILE}"
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: ${EGRESS_NAME}
spec:
  egressIPs:
  - ${UNUSED_IP}
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${NAMESPACE}
  podSelector: {}
EOF

echo "✓ Generated ${YAML_FILE}"
echo ""

# Show the generated YAML
echo "Generated EgressIP configuration:"
echo "---"
cat "${YAML_FILE}"
echo "---"
echo ""

# Apply the YAML
echo "Applying EgressIP to cluster..."
if kubectl apply -f "${YAML_FILE}"; then
  echo "✓ EgressIP created successfully"
  echo ""
  
  # Wait a moment for it to be assigned
  sleep 2
  
  # Show the status
  echo "EgressIP status:"
  kubectl get egressip "${EGRESS_NAME}" -o wide
  echo ""
  
  echo "✓ Done! EgressIP ${UNUSED_IP} assigned to namespace ${NAMESPACE}"
  echo ""
  echo "To verify:"
  echo "  kubectl get egressip ${EGRESS_NAME}"
  echo "  kubectl describe egressip ${EGRESS_NAME}"
else
  echo "✗ Failed to apply EgressIP"
  exit 1
fi

#!/bin/bash
# Extract kubeconfig from a Kubernetes secret for a specific tenant
# Usage: ./extract-kubeconfig.sh <tenant-name> [new-server-url] [config-key]

set -e

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <tenant-name> [new-server-url] [config-key]"
    echo ""
    echo "Examples:"
    echo "  $0 tenant-1"
    echo "  $0 tenant-1 https://tenant-1-cp.localtest.me:9443"
    echo "  $0 tenant-1 https://104.104.0.3:6443"
    echo "  $0 tenant-1 https://tenant-1-cp.localtest.me:9443 config-incluster"
    exit 1
fi

TENANT_NAME="$1"
NEW_SERVER_URL="${2:-}"  # Optional: new server URL
CONFIG_KEY="${3:-config}"  # Default to 'config' if not specified
SECRET_NAME="k3s-config"
NAMESPACE="${TENANT_NAME}-cp-system"
OUTPUT_FILE="${TENANT_NAME}-kubeconfig.yaml"

echo "Extracting kubeconfig for tenant: $TENANT_NAME"
echo "  Secret: $SECRET_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Config key: $CONFIG_KEY"
echo "  Output file: $OUTPUT_FILE"
if [ -n "$NEW_SERVER_URL" ]; then
    echo "  New server URL: $NEW_SERVER_URL"
fi
echo ""

# Check if secret exists
if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "✗ Error: Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'"
    echo ""
    echo "Available secrets in namespace $NAMESPACE:"
    kubectl get secrets -n "$NAMESPACE"
    exit 1
fi

# Extract and decode the kubeconfig
kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath="{.data.$CONFIG_KEY}" | base64 -d > "$OUTPUT_FILE"

if [ $? -ne 0 ] || [ ! -s "$OUTPUT_FILE" ]; then
    echo "✗ Failed to extract kubeconfig or file is empty"
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# Replace server URL if provided
if [ -n "$NEW_SERVER_URL" ]; then
    echo "Updating server URL in kubeconfig..."
    
    # Get the current server URL
    CURRENT_SERVER=$(grep "server:" "$OUTPUT_FILE" | head -n1 | awk '{print $2}')
    echo "  Current server: $CURRENT_SERVER"
    echo "  New server: $NEW_SERVER_URL"
    
    # Replace the server URL using sed
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s|server: .*|server: $NEW_SERVER_URL|g" "$OUTPUT_FILE"
    else
        # Linux
        sed -i "s|server: .*|server: $NEW_SERVER_URL|g" "$OUTPUT_FILE"
    fi
    
    echo "✓ Server URL updated"
fi

echo ""
echo "✓ Kubeconfig extracted successfully to: $OUTPUT_FILE"
echo ""
echo "Kubeconfig contents:"
echo "---"
cat "$OUTPUT_FILE"
echo "---"
echo ""
echo "To use this kubeconfig:"
echo "  export KUBECONFIG=$(pwd)/$OUTPUT_FILE"
echo "  kubectl get nodes"
echo ""
echo "Or test it directly:"
echo "  kubectl --kubeconfig=$OUTPUT_FILE get nodes"
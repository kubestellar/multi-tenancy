#!/bin/bash
# Script to automatically extract K3s join tokens and create worker userdata secrets
# Usage: ./setup-worker-secrets.sh tenant-1 tenant-2 ...

set -e

# Check if at least one tenant is provided
if [ $# -eq 0 ]; then
  echo "Error: At least one tenant name is required"
  echo "Usage: $0 <tenant-name> [tenant-name...]"
  echo "Example: $0 tenant-1 tenant-2"
  exit 1
fi

echo "=========================================="
echo "K3s Worker Setup Script"
echo "=========================================="
echo ""

# Process each tenant
for TENANT in "$@"; do
  echo "=========================================="
  echo "Processing tenant: ${TENANT}"
  echo "=========================================="
  
  NAMESPACE="${TENANT}"
  CP_NAMESPACE="${TENANT}-cp-system"
  SECRET_NAME="${TENANT}-workers-userdata"
  SECRET_FILE="${TENANT}-workers-userdata-secret.yaml"
  
  # Check if control plane namespace exists
  if ! kubectl get namespace "${CP_NAMESPACE}" &>/dev/null; then
    echo "✗ Error: Control plane namespace '${CP_NAMESPACE}' does not exist"
    echo "  Create the control plane first with: kflex create ${TENANT}-cp --type k3s"
    continue
  fi
  
  # Check if tenant namespace exists
  if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    echo "⚠ Warning: Namespace '${NAMESPACE}' does not exist, creating it..."
    kubectl create namespace "${NAMESPACE}"
  fi
  
  echo ""
  echo "Step 1: Extracting K3s join token..."
  
  # Extract the join token
  K3S_TOKEN=$(kubectl exec -n "${CP_NAMESPACE}" k3s-server-0 -- cat /var/lib/rancher/k3s/server/node-token 2>/dev/null)
  
  if [ -z "$K3S_TOKEN" ]; then
    echo "✗ Error: Failed to extract K3s token from ${CP_NAMESPACE}/k3s-server-0"
    continue
  fi
  
  echo "✓ Token extracted: ${K3S_TOKEN:0:20}..."
  echo ""
  
  echo "Step 2: Getting K3s server UDN IP address..."
  
  # Get the K3s server UDN IP (net1 interface)
  K3S_IP=$(kubectl get pod k3s-server-0 -n "${CP_NAMESPACE}" -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | jq -r '.[] | select(.name | contains("'${TENANT}'-cp")) | .ips[0]' 2>/dev/null)
  
  if [ -z "$K3S_IP" ]; then
    echo "✗ Error: Failed to get K3s server UDN IP from ${CP_NAMESPACE}/k3s-server-0"
    echo "  Make sure the k3s-server pod has been patched with UDN annotation"
    continue
  fi
  
  echo "✓ K3s server IP: ${K3S_IP}"
  echo ""
  
  echo "Step 3: Generating ${SECRET_FILE}..."
  
  # Generate the secret YAML
  cat <<EOF > "${SECRET_FILE}"
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  userdata: |
    #cloud-config
        
    # Set password for fedora user
    password: fedora
    chpasswd: { expire: False }
    ssh_pwauth: True
    
    # Install required packages
    packages:
      - curl
      - ca-certificates
    
    # Write K3s configuration and installation script
    write_files:
      - path: /etc/k3s-config.env
        content: |
          K3S_URL=https://${K3S_IP}:6443
          K3S_TOKEN=${K3S_TOKEN}
        permissions: '0644'
      
      - path: /usr/local/bin/install-k3s-agent.sh
        content: |
          #!/bin/bash
          set -e
          
          # Source configuration
          source /etc/k3s-config.env
          
          # Wait for network interfaces to be ready
          echo "Waiting for network interfaces..."
          sleep 10
          
          # Extract IP address from secondary network (eth1)
          NODE_IP=\$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
          
          if [ -z "\$NODE_IP" ]; then
            echo "ERROR: Failed to detect IP address on eth1"
            ip addr show
            exit 1
          fi
          
          echo "Detected Node IP (eth1): \$NODE_IP"
          
          # Prepare K3s data directory
          mkdir -p /var/lib/rancher/k3s
          
          # Download k3s binary directly
          echo "Downloading k3s binary..."
          curl -sfL https://github.com/k3s-io/k3s/releases/download/v1.30.13+k3s1/k3s -o /usr/local/bin/k3s
          chmod +x /usr/local/bin/k3s
          
          # Verify k3s binary
          /usr/local/bin/k3s --version
          
          # Ensure kubepods cgroup exists (fix for Fedora 40 cgroup v2 race condition)
          echo "Ensuring kubepods cgroup slice exists..."
          if [ ! -d /sys/fs/cgroup/kubepods.slice ]; then
            systemctl set-property --runtime kubepods.slice AllowedCPUs=0-\$(nproc) || true
            mkdir -p /sys/fs/cgroup/kubepods.slice 2>/dev/null || true
          fi
          
          # Wait a bit more to ensure cgroups are fully initialized
          sleep 5
          
          # Verify cgroup exists
          if [ -d /sys/fs/cgroup/kubepods.slice ]; then
            echo "✓ kubepods cgroup slice exists"
          else
            echo "⚠ Warning: kubepods cgroup slice not found, k3s will create it"
          fi
          
          # Start k3s agent
          echo "Starting k3s agent..."
          /usr/local/bin/k3s agent \
            --server "\${K3S_URL}" \
            --token "\${K3S_TOKEN}" \
            --data-dir /var/lib/rancher/k3s \
            --node-ip "\${NODE_IP}" \
            > /var/log/k3s-agent.log 2>&1 &
          
          # Wait for agent to start
          sleep 5
          
          # Check if k3s agent is running
          if pgrep -f "k3s agent" > /dev/null; then
            echo "✓ k3s agent started successfully"
          else
            echo "ERROR: k3s agent failed to start"
            cat /var/log/k3s-agent.log
            exit 1
          fi
          
          # Mark installation complete
          echo "K3s agent installed at \$(date) with node-ip: \${NODE_IP}" > /etc/k3s-install-complete
        permissions: '0755'
    
    # Run installation script
    runcmd:
      - /usr/local/bin/install-k3s-agent.sh
EOF
  
  echo "✓ Generated ${SECRET_FILE}"
  echo ""
  
  echo "Step 4: Applying secret to cluster..."
  
  # Apply the secret
  if kubectl apply -f "${SECRET_FILE}"; then
    echo "✓ Secret ${SECRET_NAME} created/updated in namespace ${NAMESPACE}"
  else
    echo "✗ Failed to apply secret"
    continue
  fi
  
  echo ""
  echo "✓ ${TENANT} setup complete!"
  echo "  - Token: ${K3S_TOKEN:0:20}..."
  echo "  - K3s IP: ${K3S_IP}"
  echo "  - Secret: ${NAMESPACE}/${SECRET_NAME}"
  echo ""
done

echo "=========================================="
echo "All tenants processed!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Create the VMs:"
for TENANT in "$@"; do
  echo "     kubectl -n ${TENANT} create -f ${TENANT}-vm-kind.yaml"
done
echo ""
echo "  2. Wait ~10 minutes for VMs to start and join the cluster"
echo ""
echo "  3. Verify nodes:"
for TENANT in "$@"; do
  echo "     kubectl -n ${TENANT}-cp-system exec k3s-server-0 -- kubectl get nodes"
done

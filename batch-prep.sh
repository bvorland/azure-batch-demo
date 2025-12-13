#!/bin/bash
# batch-prep.sh
#
# This script automates the creation of a custom Azure VM image for Azure Batch pools (GPU or CPU),
# creates a Shared Image Gallery, and deploys an Azure Batch pool using the custom image.
# It uses Azure CLI and "az vm run-command" to configure VMs without requiring SSH access.
#
# Configuration:
#   Adjust the variables in the CONFIG section below to customize resource names, VM size, OS image,
#   admin username, Batch pool details, and container image name. Set ENABLE_GPU=true for GPU workloads.
#
# Logging and Error Handling:
#   The script logs all output to a log file (named with a timestamp) in the current directory,
#   and to stdout. A helper function (run_cmd) checks the exit status of critical commands and
#   aborts the script on failure while logging an appropriate error message.
#
# WARNING:
#   Executing this script will incur Azure resource usage, including creating VMs, images, and
#   Batch resources. Make sure to adjust variables for production use, and clean up resources
#   afterward to avoid unwanted costs.

set -euo pipefail

# ---------------------------
# CONFIGURATION SECTION
# Modify these values as needed
# ---------------------------
RESOURCE_GROUP="my-batch-rg"             # Azure Resource Group name
LOCATION="eastus2"                       # Azure region (e.g., eastus2, westeurope, southcentralus)

# GPU Configuration
ENABLE_GPU=true                          # Set to true for GPU workloads, false for CPU-only
GPU_VM_SIZE="Standard_NC4as_T4_v3"       # GPU VM size (NC4as_T4_v3, NC6s_v3, NC8as_T4_v3, etc.)
CPU_VM_SIZE="Standard_D4s_v3"            # CPU VM size for non-GPU workloads

# Auto-select VM size based on GPU setting
if [[ "$ENABLE_GPU" == "true" ]]; then
  VM_SIZE="$GPU_VM_SIZE"
else
  VM_SIZE="$CPU_VM_SIZE"
fi

VM_NAME="batch-custom-vm"                # Name of the temporary VM used to build the image
ADMIN_USERNAME="azureuser"               # Admin username for the VM

# Shared Image Gallery Configuration
GALLERY_NAME="batchImageGallery"         # Name of the Shared Image Gallery
IMAGE_DEFINITION_NAME="batchCustomImage" # Name of the image definition
IMAGE_VERSION="1.0.0"                    # Version of the image
IMAGE_PUBLISHER="MyCompany"              # Publisher name for the image
IMAGE_OFFER="BatchImages"                # Offer name for the image
IMAGE_SKU="Ubuntu2204"                   # SKU name for the image

# Batch Configuration
BATCH_ACCOUNT_NAME="mybatchaccount-$RANDOM"  # Name of Azure Batch account (append random to avoid collisions)
BATCH_POOL_ID="myBatchPool"                  # Name/ID of the Batch pool to create
NODE_AGENT_SKU="batch.node.ubuntu 22.04"     # Node agent SKU id matching OS image

# Container image(s) to prefetch (comma-separated if multiple). Use appropriate image for your workload.
if [[ "$ENABLE_GPU" == "true" ]]; then
  CONTAINER_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"
else
  CONTAINER_IMAGE="ubuntu:22.04"
fi

# Base OS image URN: Ubuntu 22.04 LTS. Use Gen1 for compatibility.
VM_IMAGE_URN="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen1:latest"
HYPERV_GENERATION="V1"                   # V1 or V2 - must match the VM image

# Create logs directory & file
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/batch_prep_$(date +%Y%m%d_%H%M%S).log"

# Redirect all output to console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Helper function to run commands with error checking
run_cmd() {
  local description="$1"
  shift
  echo "[INFO] $description: Running command..."
  if "$@"; then
    echo "[SUCCESS] $description"
  else
    echo "[ERROR] Failed: $description" >&2
    exit 1
  fi
}

# Ensure Azure CLI is installed
if ! command -v az &> /dev/null; then
  echo "[ERROR] Azure CLI (az) is not installed. Please install and run 'az login' first." >&2
  exit 1
fi

# Ensure you are logged in to Azure
if ! az account show &> /dev/null; then
  echo "[ERROR] You must be logged in to Azure CLI. Run 'az login' first." >&2
  exit 1
fi

echo "[INFO] Logs will be saved to $LOG_FILE"

echo "[INFO] Using VM size: $VM_SIZE"

echo "[INFO] Using OS image URN: $VM_IMAGE_URN"

echo "[INFO] Creating/updating resource group: $RESOURCE_GROUP in $LOCATION"
run_cmd "Create resource group" \
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# Create a VM if it does not exist
if az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &> /dev/null; then
  echo "[INFO] VM $VM_NAME already exists. Skipping VM creation."
else
  echo "[INFO] Creating VM $VM_NAME ..."
  run_cmd "Create VM" \
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --image "$VM_IMAGE_URN" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USERNAME" \
      --generate-ssh-keys \
      --public-ip-address "" \
      --no-wait
fi

# Wait until the VM is running
echo "[INFO] Waiting for VM $VM_NAME to be ready ..."
run_cmd "Wait for VM creation" \
  az vm wait --created --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
run_cmd "Wait for VM update" \
  az vm wait --updated --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
run_cmd "Wait for VM to be running" \
az vm wait --custom "instanceView.statuses[?code=='PowerState/running']" --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

echo "[INFO] VM $VM_NAME is running."

# Install NVIDIA GPU driver extension if GPU is enabled
if [[ "$ENABLE_GPU" == "true" ]]; then
  extension_status=$(az vm extension list --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --query "[?name=='NvidiaGpuDriverLinux'].properties.provisioningState" -o tsv || true)

  if [[ "$extension_status" == "Succeeded" ]]; then
    echo "[INFO] NVIDIA driver extension already installed. Skipping installation."
  else
    echo "[INFO] Installing NVIDIA GPU driver extension on $VM_NAME ..."
    run_cmd "Install NVIDIA GPU driver extension" \
      az vm extension set \
        --publisher Microsoft.HpcCompute \
        --name NvidiaGpuDriverLinux \
        --version 1.10 \
        --resource-group "$RESOURCE_GROUP" \
        --vm-name "$VM_NAME" \
        --settings '{}' \
        --output none

    # Wait for the extension to finish provisioning
    echo "[INFO] Waiting for NVIDIA driver extension provisioning ..."
    timeout=1800  # 30 minutes
    elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
      status=$(az vm extension show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --name NvidiaGpuDriverLinux --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")
      if [[ "$status" == "Succeeded" ]]; then
        echo "[INFO] GPU driver installation completed."
        break
      elif [[ "$status" == "Failed" ]]; then
        echo "[ERROR] GPU driver installation failed." >&2
        exit 1
      fi
      echo "[INFO] Extension status: $status (waiting...)"
      sleep 30
      elapsed=$((elapsed + 30))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
      echo "[ERROR] GPU driver installation timed out." >&2
      exit 1
    fi
  fi
else
  echo "[INFO] Skipping NVIDIA driver installation (GPU not enabled)"
fi

# NOTE: We do NOT install Docker here because it doesn't persist through generalization.
# Docker will be installed via the Batch pool start task instead.
echo "[INFO] Skipping Docker installation (will be installed via Batch start task)"

# Deallocate and generalize the VM
echo "[INFO] Deallocating VM $VM_NAME ..."
run_cmd "Deallocate VM" \
  az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

echo "[INFO] Generalizing VM $VM_NAME ..."
run_cmd "Generalize VM" \
  az vm generalize --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

# Create Shared Image Gallery (required for Azure Batch)
echo "[INFO] Creating Shared Image Gallery $GALLERY_NAME ..."
if az sig show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" &> /dev/null; then
  echo "[INFO] Shared Image Gallery $GALLERY_NAME already exists."
else
  run_cmd "Create Shared Image Gallery" \
    az sig create \
      --resource-group "$RESOURCE_GROUP" \
      --gallery-name "$GALLERY_NAME" \
      --location "$LOCATION" \
      --output none
fi

# Create Image Definition in the gallery
echo "[INFO] Creating image definition $IMAGE_DEFINITION_NAME ..."
if az sig image-definition show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --gallery-image-definition "$IMAGE_DEFINITION_NAME" &> /dev/null; then
  echo "[INFO] Image definition $IMAGE_DEFINITION_NAME already exists."
else
  run_cmd "Create image definition" \
    az sig image-definition create \
      --resource-group "$RESOURCE_GROUP" \
      --gallery-name "$GALLERY_NAME" \
      --gallery-image-definition "$IMAGE_DEFINITION_NAME" \
      --publisher "$IMAGE_PUBLISHER" \
      --offer "$IMAGE_OFFER" \
      --sku "$IMAGE_SKU" \
      --os-type Linux \
      --os-state Generalized \
      --hyper-v-generation "$HYPERV_GENERATION" \
      --output none
fi

# Create Image Version from the generalized VM
echo "[INFO] Creating image version $IMAGE_VERSION from VM $VM_NAME ..."
VM_ID=$(az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query id -o tsv)
run_cmd "Create image version" \
  az sig image-version create \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEFINITION_NAME" \
    --gallery-image-version "$IMAGE_VERSION" \
    --target-regions "$LOCATION" \
    --managed-image "$VM_ID" \
    --output none

echo "[INFO] Shared Image Gallery image version created: $GALLERY_NAME/$IMAGE_DEFINITION_NAME/$IMAGE_VERSION"

# Create Batch account if not existing
if az batch account show --name "$BATCH_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
  echo "[INFO] Batch account $BATCH_ACCOUNT_NAME already exists. Skipping creation."
else
  echo "[INFO] Creating Batch account $BATCH_ACCOUNT_NAME ..."
  run_cmd "Create Batch account" \
    az batch account create --name "$BATCH_ACCOUNT_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --location "$LOCATION" \
      --output none
fi

# Set current Batch account context
echo "[INFO] Setting current Batch account context for $BATCH_ACCOUNT_NAME ..."
run_cmd "Set Batch account context" \
  az batch account set --name "$BATCH_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP"

# Retrieve image ID from Shared Image Gallery
IMAGE_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/galleries/$GALLERY_NAME/images/$IMAGE_DEFINITION_NAME/versions/$IMAGE_VERSION"
echo "[INFO] Using image: $IMAGE_ID"

# Create start task script that installs Docker and NVIDIA container toolkit (if GPU enabled)
START_TASK_SCRIPT="/bin/bash -c '"
START_TASK_SCRIPT+="set -euo pipefail; "
START_TASK_SCRIPT+="echo Installing Docker...; "
START_TASK_SCRIPT+="apt-get update -y && apt-get install -y moby-engine moby-cli; "

if [[ "$ENABLE_GPU" == "true" ]]; then
  START_TASK_SCRIPT+="echo Installing NVIDIA container toolkit...; "
  START_TASK_SCRIPT+="distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID); "
  START_TASK_SCRIPT+="curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; "
  START_TASK_SCRIPT+="curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list; "
  START_TASK_SCRIPT+="apt-get update && apt-get install -y nvidia-container-toolkit; "
  START_TASK_SCRIPT+="systemctl restart docker; "
  START_TASK_SCRIPT+="echo Waiting for GPU...; "
  START_TASK_SCRIPT+="until nvidia-smi >/dev/null 2>&1; do sleep 5; done; "
  START_TASK_SCRIPT+="nvidia-smi; "
fi

START_TASK_SCRIPT+="docker --version; "
START_TASK_SCRIPT+="echo Batch node ready"
START_TASK_SCRIPT+="'"

echo "[INFO] Creating Batch pool $BATCH_POOL_ID with VM size $VM_SIZE ..."

# Create a JSON configuration for the pool
POOL_JSON=$(mktemp)
cat > "$POOL_JSON" <<EOF
{
  "id": "$BATCH_POOL_ID",
  "vmSize": "$VM_SIZE",
  "virtualMachineConfiguration": {
    "imageReference": {
      "virtualMachineImageId": "$IMAGE_ID"
    },
    "nodeAgentSKUId": "$NODE_AGENT_SKU"
  },
  "targetDedicatedNodes": 1,
  "startTask": {
    "commandLine": $START_TASK_SCRIPT,
    "waitForSuccess": true,
    "userIdentity": {
      "autoUser": {
        "scope": "pool",
        "elevationLevel": "admin"
      }
    },
    "maxTaskRetryCount": 0
  }
}
EOF

# Create the pool using the JSON configuration
run_cmd "Create Batch pool" \
  az batch pool create --json-file "$POOL_JSON"

# Cleanup temp file
rm -f "$POOL_JSON"

echo "[INFO] Batch pool $BATCH_POOL_ID created and configured."
if [[ "$ENABLE_GPU" == "true" ]]; then
  echo "[INFO] Pool is ready for GPU-enabled container workloads."
else
  echo "[INFO] Pool is ready for CPU container workloads."
fi
echo "[INFO] Full logs available at: $LOG_FILE"

# End of script

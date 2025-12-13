#!/bin/bash
# batch-prep.sh
#
# This script automates the creation of a custom Azure VM image for GPU-enabled Azure Batch pools,
# installs necessary GPU drivers and container runtimes without manually SSH-ing into the VM, and
# creates an Azure Batch pool using the custom image. It uses Azure CLI and "az vm run-command"
# to run configuration inside the VM without requiring interactive login.
#
# Configuration:
#   Adjust the variables in the CONFIG section below to customize resource names, VM size, OS image,
#   admin username, VM size (e.g. Standard_NC4as_T4_v3, Standard_NC8as_T4_v3, etc.), Batch pool
#   details, and container image name. Ensure that the VM size is supported by your chosen OS image
#   and the Azure region you deploy into.
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
RESOURCE_GROUP="my-batch-rg"           # Azure Resource Group name
LOCATION="westeurope"                 # Azure region (e.g., westeurope, eastus, etc.)

VM_NAME="batch-custom-vm"              # Name of the temporary VM used to build the image
VM_SIZE="Standard_NC4as_T4_v3"         # VM size (e.g. Standard_NC4as_T4_v3, NC8as_T4_v3, NC16as_T4_v3)
ADMIN_USERNAME="azureuser"             # Admin username for the VM

CUSTOM_IMAGE_NAME="myCustomGpuImage"    # Name of the managed image to create

BATCH_ACCOUNT_NAME="mybatchaccount-$RANDOM"  # Name of Azure Batch account (append random to avoid collisions)
BATCH_POOL_ID="myGpuPool"                    # Name/ID of the Batch pool to create
NODE_AGENT_SKU="batch.node.ubuntu 22.04"     # Node agent SKU id matching OS image (e.g. batch.node.ubuntu 22.04)

# Container image(s) to prefetch and run (comma-separated if multiple). Update with your own image.
CONTAINER_IMAGE="myacr.azurecr.io/mygpuimage:latest"

# Base OS image URN: Ubuntu 22.04 LTS (Gen2). Change if using a different OS or version.
VM_IMAGE_URN="Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"

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

# Install NVIDIA GPU driver extension (if not already installed)

extension_status=$(az vm extension list --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --query "[?name=='NvidiaDriverLinux'].properties.provisioningState" -o tsv || true)

if [[ "$extension_status" == "Succeeded" ]]; then
  echo "[INFO] NVIDIA driver extension already installed. Skipping installation."
else
  echo "[INFO] Installing NVIDIA GPU driver extension on $VM_NAME ..."
  run_cmd "Install NVIDIA GPU driver extension" \
    az vm extension set \
      --publisher Microsoft.HpcCompute \
      --name NvidiaDriverLinux \
      --version 1.4 \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$VM_NAME" \
      --settings '{}' \
      --output none

  # Wait for the extension to finish provisioning
  echo "[INFO] Waiting for NVIDIA driver extension provisioning ..."
  run_cmd "Wait for driver extension to succeed" \
    az resource wait --resource-group "$RESOURCE_GROUP" \
      --name "NvidiaDriverLinux" \
      --namespace Microsoft.Compute \
      --resource-type virtualMachines/extensions \
      --resource-name "$VM_NAME/NvidiaDriverLinux" \
      --custom "properties.provisioningState=='Succeeded'"
  echo "[INFO] GPU driver installation completed."
fi

# Prepare in-VM container runtime setup using run-command (no manual SSH is necessary)
echo "[INFO] Running container runtime setup in $VM_NAME via RunCommand..."

# Create temporary directory for local files
tmp_dir=$(mktemp -d)
cat > "$tmp_dir/gpu-setup.sh" <<'INNERSCRIPT'
#!/bin/bash
set -euo pipefail

# Update and install required packages: Moby Engine, CLI, and jq
sudo apt-get update
sudo apt-get install -y moby-engine moby-cli jq

# Install NVIDIA container toolkit for enabling GPU in Docker containers
. /etc/os-release
DISTRIB="${ID}${VERSION_ID}"
sudo curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
sudo curl -s -L https://nvidia.github.io/libnvidia-container/ubuntu${DISTRIB}/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-container.list > /dev/null
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Restart Docker to apply runtime changes
sudo systemctl restart docker
INNERSCRIPT

# Execute setup script inside VM using az vm run-command
run_cmd "Install Moby & NVIDIA container runtime in VM" \
  az vm run-command invoke \
    --command-id RunShellScript \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --scripts @"$tmp_dir/gpu-setup.sh" \
    --output none

# Cleanup temporary script and directory
rm -rf "$tmp_dir"

# Deallocate and generalize the VM
echo "[INFO] Deallocating VM $VM_NAME ..."
run_cmd "Deallocate VM" \
  az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --no-wait
run_cmd "Wait for VM to deallocate" \
  az vm wait --deallocated --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

echo "[INFO] Generalizing VM $VM_NAME ..."
run_cmd "Generalize VM" \
  az vm generalize --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"

# Create a managed image from the generalized VM
echo "[INFO] Creating managed image $CUSTOM_IMAGE_NAME ..."
run_cmd "Create managed image" \
  az image create --resource-group "$RESOURCE_GROUP" --name "$CUSTOM_IMAGE_NAME" \
    --source "$VM_NAME" --os-type Linux --output none

echo "[INFO] Managed image $CUSTOM_IMAGE_NAME created."

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

# Retrieve image ID for the custom image
IMAGE_ID="$(run_cmd "Retrieve image ID" az image show --resource-group "$RESOURCE_GROUP" --name "$CUSTOM_IMAGE_NAME" --query id -o tsv)"

echo "[INFO] Creating Batch pool $BATCH_POOL_ID with VM size $VM_SIZE ..."
run_cmd "Create Batch pool" \
  az batch pool create \
    --id "$BATCH_POOL_ID" \
    --vm-size "$VM_SIZE" \
    --image "$IMAGE_ID" \
    --image-type managed \
    --node-agent-sku-id "$NODE_AGENT_SKU" \
    --target-dedicated-nodes 1 \
    --container-configuration type=dockerCompatible containerImageNames="$CONTAINER_IMAGE" \
    --output none

echo "[INFO] Batch pool $BATCH_POOL_ID created. Adding start task ..."

run_cmd "Configure start task" \
  az batch pool set \
    --pool-id "$BATCH_POOL_ID" \
    --start-task-command-line "/bin/bash -c 'until nvidia-smi >/dev/null 2>&1; do echo Waiting for GPU; sleep 5; done'" \
    --start-task-wait-for-success true \
    --start-task-user-identity autoUser \
    --output none

echo "[INFO] Start task configured. Batch pool is ready for GPU-enabled container jobs. See $LOG_FILE for full logs."

# End of script

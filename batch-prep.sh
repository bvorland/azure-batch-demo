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
# Pre-validation:
#   The script performs comprehensive pre-validation checks before creating any resources:
#   - Azure CLI installation and login status
#   - Required resource providers (Microsoft.Compute, Microsoft.Network, Microsoft.Batch)
#   - VM size availability in the target region
#   - Quota availability for the selected VM family
#   - Permissions to create resources
#   - Location validity
#
# Usage:
#   ./batch-prep.sh              # Run full deployment
#   ./batch-prep.sh --validate   # Run pre-validation checks only
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

# Check for validation-only mode
VALIDATE_ONLY=false
if [[ "${1:-}" == "--validate" ]]; then
  VALIDATE_ONLY=true
fi

# ---------------------------
# CONFIGURATION SECTION
# Modify these values as needed
# ---------------------------
# Base OS Configuration
BASE_OS="ubuntu"                           # Base OS: "ubuntu" or "almalinux"
OS_VERSION="22.04"                         # Ubuntu: 22.04, 20.04 | AlmaLinux: 8, 9

# Auto-configure based on BASE_OS selection
if [[ "$BASE_OS" == "ubuntu" ]]; then
  VM_IMAGE_URN="Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"
  NODE_AGENT_SKU="batch.node.ubuntu 22.04"
  IMAGE_SKU="Ubuntu2204"
  DOCKERFILE="Dockerfile.gpu.ubuntu"
elif [[ "$BASE_OS" == "almalinux" ]]; then
  if [[ "$OS_VERSION" == "9" ]]; then
    VM_IMAGE_URN="almalinux:almalinux-x86_64:9-gen2:latest"
    NODE_AGENT_SKU="batch.node.el 9"
    IMAGE_SKU="AlmaLinux9"
  else
    VM_IMAGE_URN="almalinux:almalinux-x86_64:8-gen2:latest"
    NODE_AGENT_SKU="batch.node.el 8"
    IMAGE_SKU="AlmaLinux8"
  fi
  DOCKERFILE="Dockerfile.gpu.almalinux"
else
  echo "[ERROR] Invalid BASE_OS: $BASE_OS. Must be 'ubuntu' or 'almalinux'" >&2
  exit 1
fi

RESOURCE_GROUP="batch-pool-verify"       # Azure Resource Group name
LOCATION="swedencentral"                # Azure region (e.g., eastus2, westeurope, southcentralus)

# GPU Configuration
ENABLE_GPU=false                         # Set to false for CPU test (no GPU quota)
GPU_VM_SIZE="Standard_NC4as_T4_v3"       # GPU VM size (NC4as_T4_v3, NC6s_v3, NC8as_T4_v3, etc.)
CPU_VM_SIZE="Standard_D2s_v3"            # CPU VM size for non-GPU workloads (using smaller size for test)

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
IMAGE_SKU="${IMAGE_SKU}"                 # SKU name (auto-set based on BASE_OS)

# Batch Configuration
BATCH_ACCOUNT_NAME="mybatch$RANDOM"      # Name of Azure Batch account (alphanumeric only, 3-24 chars)
BATCH_POOL_ID="myBatchPool"              # Name/ID of the Batch pool to create
NODE_AGENT_SKU="${NODE_AGENT_SKU}"       # Node agent SKU (auto-set based on BASE_OS)

# Container Registry Configuration
CREATE_ACR=false                     # Set to false - skip ACR for quick test
ACR_NAME="batchacr$RANDOM"          # ACR name (alphanumeric only, 5-50 chars, globally unique)
ACR_SKU="Basic"                     # ACR SKU (Basic, Standard, Premium)
BUILD_DOCKER_IMAGE=false            # Set to false - skip Docker build for quick test
DOCKER_IMAGE_NAME="batch-gpu-pytorch"  # Docker image name
DOCKER_IMAGE_TAG="latest"           # Docker image tag
PRELOAD_IMAGES=false                # Set to false - skip image preload for quick test

# Container image(s) to prefetch (comma-separated if multiple). Use appropriate image for your workload.
if [[ "$ENABLE_GPU" == "true" ]]; then
  # Use custom ACR image if building, otherwise use public image
  if [[ "$BUILD_DOCKER_IMAGE" == "true" && "$CREATE_ACR" == "true" ]]; then
    CONTAINER_IMAGE="${ACR_NAME}.azurecr.io/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}"
  else
    CONTAINER_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"
  fi
else
  CONTAINER_IMAGE="ubuntu:22.04"
fi

echo "[INFO] Base OS: $BASE_OS $OS_VERSION"
echo "[INFO] VM Image URN: $VM_IMAGE_URN"
echo "[INFO] Node Agent SKU: $NODE_AGENT_SKU"
echo "[INFO] Dockerfile: $DOCKERFILE"
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

# ---------------------------
# PRE-VALIDATION CHECKS
# ---------------------------
echo "[INFO] Running pre-validation checks..."

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
  echo "[ERROR] Azure CLI (az) is not installed. Please install it from https://aka.ms/InstallAzureCLI" >&2
  exit 1
fi
echo "[INFO] ✓ Azure CLI is installed"

# Check if logged in to Azure
if ! az account show &> /dev/null; then
  echo "[ERROR] You must be logged in to Azure CLI. Run 'az login' first." >&2
  exit 1
fi

# Get current subscription info
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
echo "[INFO] ✓ Logged in to Azure"
echo "[INFO]   Subscription: $SUBSCRIPTION_NAME"
echo "[INFO]   Subscription ID: $SUBSCRIPTION_ID"

# Check required resource providers
echo "[INFO] Checking required resource providers..."
REQUIRED_PROVIDERS=("Microsoft.Compute" "Microsoft.Network" "Microsoft.Batch")
UNREGISTERED_PROVIDERS=()

for provider in "${REQUIRED_PROVIDERS[@]}"; do
  state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv 2>/dev/null | tr -d '\r' | xargs)
  if [[ "$state" == "Registered" ]]; then
    echo "[INFO] ✓ $provider is registered"
  else
    UNREGISTERED_PROVIDERS+=("$provider")
    echo "[WARN] Resource provider $provider needs registration (state: $state)"
  fi
done

# Register unregistered providers if needed
if [[ ${#UNREGISTERED_PROVIDERS[@]} -gt 0 ]]; then
  echo "[INFO] Registering unregistered resource providers..."
  for provider in "${UNREGISTERED_PROVIDERS[@]}"; do
    echo "[INFO] Registering $provider (this may take 1-2 minutes)..."
    az provider register --namespace "$provider" --wait
    echo "[INFO] ✓ $provider registered successfully"
  done
fi

# Check VM size availability in the region
echo "[INFO] Checking VM size availability in $LOCATION..."
vm_available=$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --all --query "[?name=='$VM_SIZE' && !restrictions]" -o tsv 2>/dev/null)
if [[ -z "$vm_available" ]]; then
  echo "[ERROR] VM size $VM_SIZE is not available in region $LOCATION or has restrictions" >&2
  echo "[INFO] Checking restrictions..." >&2
  restrictions=$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --all --query "[?name=='$VM_SIZE'].restrictions" -o json 2>/dev/null)
  if [[ "$restrictions" != "[]" && "$restrictions" != "" ]]; then
    echo "[ERROR] VM size restrictions: $restrictions" >&2
  fi
  echo "[INFO] Run this command to check available sizes: az vm list-sizes --location $LOCATION --output table" >&2
  exit 1
fi
echo "[INFO] ✓ VM size $VM_SIZE is available in $LOCATION"

# Check quota for the VM family
if [[ "$ENABLE_GPU" == "true" ]]; then
  echo "[INFO] Checking GPU quota for $VM_SIZE..."
  
  # Determine quota family based on VM size
  if [[ "$VM_SIZE" == *"NC4as_T4"* || "$VM_SIZE" == *"NC8as_T4"* || "$VM_SIZE" == *"NC16as_T4"* || "$VM_SIZE" == *"NC64as_T4"* ]]; then
    QUOTA_FAMILY="NCASv3_T4"
  elif [[ "$VM_SIZE" == *"NC6s_v3"* || "$VM_SIZE" == *"NC12s_v3"* || "$VM_SIZE" == *"NC24s_v3"* ]]; then
    QUOTA_FAMILY="NCSv3"
  elif [[ "$VM_SIZE" == *"NC"* ]]; then
    QUOTA_FAMILY="NC"
  else
    QUOTA_FAMILY="Standard"
  fi
  
  quota_info=$(az vm list-usage --location "$LOCATION" --query "[?contains(name.value, '$QUOTA_FAMILY')].{Name:name.localizedValue, Current:currentValue, Limit:limit}" -o json 2>/dev/null)
  quota_limit=$(echo "$quota_info" | jq -r '.[0].Limit // "0"' 2>/dev/null)
  
  if [[ "$quota_limit" == "0" || -z "$quota_limit" ]]; then
    echo "[ERROR] No quota available for $QUOTA_FAMILY family in $LOCATION" >&2
    echo "[ERROR] Current quota limit: $quota_limit" >&2
    echo "[INFO] Request a quota increase:" >&2
    echo "[INFO]   1. Go to Azure Portal > Quotas" >&2
    echo "[INFO]   2. Search for 'Standard $QUOTA_FAMILY Family vCPUs'" >&2
    echo "[INFO]   3. Request an increase for region $LOCATION" >&2
    echo "[INFO] Or run: az vm list-usage --location $LOCATION --query \"[?contains(name.value, 'NC')]\" -o table" >&2
    exit 1
  fi
  echo "[INFO] ✓ GPU quota available: $quota_limit vCPUs for $QUOTA_FAMILY family"
else
  echo "[INFO] Skipping GPU quota check (ENABLE_GPU=false)"
fi

# Check permissions to create resources in the subscription
echo "[INFO] Checking permissions to create resources..."
user_email=$(az account show --query user.name -o tsv 2>/dev/null | tr -d '\r' | xargs)
if [[ -n "$user_email" ]]; then
  role_check=$(az role assignment list --assignee "$user_email" --query "[?contains(roleDefinitionName, 'Contributor') || contains(roleDefinitionName, 'Owner')].roleDefinitionName" -o tsv 2>/dev/null | tr -d '\r' | head -1 | xargs)
  if [[ -z "$role_check" ]]; then
    echo "[WARN] Could not verify Contributor/Owner role. You may encounter permission errors."
  else
    echo "[INFO] ✓ Sufficient permissions detected: $role_check"
  fi
else
  echo "[WARN] Could not determine user identity. Skipping permission check."
fi

# Verify the location is valid
echo "[INFO] Verifying location $LOCATION..."
location_valid=$(az account list-locations --query "[?name=='$LOCATION'].name" -o tsv)
if [[ -z "$location_valid" ]]; then
  echo "[ERROR] Location '$LOCATION' is not valid" >&2
  echo "[INFO] Run this command to see valid locations: az account list-locations --query '[].name' -o table" >&2
  exit 1
fi
echo "[INFO] ✓ Location $LOCATION is valid"

# Check if Batch provider is registered (required for Batch account creation)
batch_provider_state=$(az provider show --namespace "Microsoft.Batch" --query "registrationState" -o tsv 2>/dev/null)
if [[ "$batch_provider_state" != "Registered" ]]; then
  echo "[INFO] Registering Microsoft.Batch provider..."
  az provider register --namespace "Microsoft.Batch" --wait
  echo "[INFO] ✓ Microsoft.Batch provider registered"
fi

echo "[INFO] ✓ All pre-validation checks passed"

# Exit if validation-only mode
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  echo ""
  echo "=========================================="
  echo "VALIDATION SUCCESSFUL"
  echo "=========================================="
  echo "All prerequisites are met. You can now run the script without --validate to create resources."
  echo ""
  exit 0
fi

echo "[INFO] Starting resource provisioning..."
echo ""

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

# Create Azure Container Registry if enabled
if [[ "$CREATE_ACR" == "true" ]]; then
  echo "[INFO] Creating Azure Container Registry $ACR_NAME ..."
  
  # Check if ACR already exists
  if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
    echo "[INFO] ACR $ACR_NAME already exists."
  else
    run_cmd "Create Azure Container Registry" \
      az acr create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ACR_NAME" \
        --sku "$ACR_SKU" \
        --location "$LOCATION" \
        --admin-enabled true \
        --output none
    echo "[INFO] ACR $ACR_NAME created successfully."
  fi
  
  # Get ACR credentials
  ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query "username" -o tsv)
  ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)
  ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
  
  echo "[INFO] ACR Login Server: $ACR_LOGIN_SERVER"
fi

# Build and push Docker image if enabled
if [[ "$BUILD_DOCKER_IMAGE" == "true" && "$CREATE_ACR" == "true" ]]; then
  echo "[INFO] Building and pushing Docker image to ACR..."
  
  # Check if Docker is available locally
  if ! command -v docker &> /dev/null; then
    echo "[ERROR] Docker is not installed locally. Please install Docker to build images." >&2
    echo "[INFO] You can skip this step by setting BUILD_DOCKER_IMAGE=false" >&2
    exit 1
  fi
  
  # Check if Dockerfile exists
  DOCKERFILE_PATH="./$DOCKERFILE"
  if [[ ! -f "$DOCKERFILE_PATH" ]]; then
    echo "[ERROR] Dockerfile not found at $DOCKERFILE_PATH" >&2
    echo "[INFO] Available Dockerfiles for $BASE_OS:" >&2
    ls -1 Dockerfile.gpu.* 2>/dev/null >&2 || echo "  No Dockerfiles found" >&2
    exit 1
  fi
  
  echo "[INFO] Building Docker image $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG ..."
  FULL_IMAGE_NAME="${ACR_LOGIN_SERVER}/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}"
  
  run_cmd "Build Docker image" \
    docker build -f "$DOCKERFILE_PATH" -t "$FULL_IMAGE_NAME" .
  
  echo "[INFO] Logging in to ACR..."
  run_cmd "Login to ACR" \
    az acr login --name "$ACR_NAME"
  
  echo "[INFO] Pushing image to ACR..."
  run_cmd "Push Docker image to ACR" \
    docker push "$FULL_IMAGE_NAME"
  
  echo "[INFO] Docker image pushed successfully: $FULL_IMAGE_NAME"
  
  # Update CONTAINER_IMAGE variable
  CONTAINER_IMAGE="$FULL_IMAGE_NAME"
fi

# Preload Docker images on the VM if enabled
if [[ "$PRELOAD_IMAGES" == "true" ]]; then
  echo "[INFO] Preloading Docker images on VM $VM_NAME ..."
  
  # Create script to pull and save Docker images
  tmp_dir=$(mktemp -d)
  cat > "$tmp_dir/preload-images.sh" <<INNERSCRIPT
#!/bin/bash
set -euo pipefail

echo "Installing Docker..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io

echo "Starting Docker service..."
systemctl start docker
systemctl enable docker

echo "Pulling container images..."
INNERSCRIPT

  # Add ACR login if ACR is being used
  if [[ "$CREATE_ACR" == "true" && "$BUILD_DOCKER_IMAGE" == "true" ]]; then
    cat >> "$tmp_dir/preload-images.sh" <<INNERSCRIPT
echo "Logging in to ACR..."
echo "$ACR_PASSWORD" | docker login "$ACR_LOGIN_SERVER" -u "$ACR_USERNAME" --password-stdin

INNERSCRIPT
  fi

  # Add image pull commands
  cat >> "$tmp_dir/preload-images.sh" <<INNERSCRIPT
echo "Pulling image: $CONTAINER_IMAGE"
docker pull "$CONTAINER_IMAGE"

echo "Verifying image..."
docker images | grep "${DOCKER_IMAGE_NAME}" || docker images | grep "ubuntu\|cuda"

echo "Docker images preloaded successfully!"
INNERSCRIPT

  # Execute preload script on VM
  run_cmd "Preload Docker images on VM" \
    az vm run-command invoke \
      --command-id RunShellScript \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --scripts @"$tmp_dir/preload-images.sh" \
      --output none

  # Cleanup temporary script
  rm -rf "$tmp_dir"
  
  echo "[INFO] Docker images preloaded on VM"
else
  echo "[INFO] Skipping Docker image preloading"
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

# Create a temporary managed image from the generalized VM
TEMP_IMAGE_NAME="${VM_NAME}-image"
echo "[INFO] Creating temporary managed image $TEMP_IMAGE_NAME ..."
run_cmd "Create managed image" \
  az image create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$TEMP_IMAGE_NAME" \
    --source "$VM_NAME" \
    --os-type Linux \
    --hyper-v-generation "$HYPERV_GENERATION" \
    --output none

# Create Image Version from the managed image
echo "[INFO] Creating image version $IMAGE_VERSION from managed image ..."
run_cmd "Create image version" \
  az sig image-version create \
    --resource-group "$RESOURCE_GROUP" \
    --gallery-name "$GALLERY_NAME" \
    --gallery-image-definition "$IMAGE_DEFINITION_NAME" \
    --gallery-image-version "$IMAGE_VERSION" \
    --target-regions "$LOCATION" \
    --managed-image "$TEMP_IMAGE_NAME" \
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
START_TASK_SCRIPT+="apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io; "

# Add ACR login if using custom ACR
if [[ "$CREATE_ACR" == "true" && "$BUILD_DOCKER_IMAGE" == "true" ]]; then
  START_TASK_SCRIPT+="echo Logging in to ACR...; "
  START_TASK_SCRIPT+="echo \\\"$ACR_PASSWORD\\\" | docker login $ACR_LOGIN_SERVER -u $ACR_USERNAME --password-stdin; "
fi

if [[ "$ENABLE_GPU" == "true" ]]; then
  START_TASK_SCRIPT+="echo Installing NVIDIA container toolkit...; "
  START_TASK_SCRIPT+="distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID); "
  START_TASK_SCRIPT+="curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; "
  START_TASK_SCRIPT+="curl -s -L https://nvidia.github.io/libnvidia-container/\$distribution/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list; "
  START_TASK_SCRIPT+="apt-get update && apt-get install -y nvidia-container-toolkit; "
  START_TASK_SCRIPT+="nvidia-ctk runtime configure --runtime=docker; "
  START_TASK_SCRIPT+="systemctl restart docker; "
  START_TASK_SCRIPT+="echo Waiting for GPU...; "
  START_TASK_SCRIPT+="until nvidia-smi >/dev/null 2>&1; do sleep 5; done; "
  START_TASK_SCRIPT+="nvidia-smi; "
fi

# Verify or pull the container image
START_TASK_SCRIPT+="echo Verifying container image...; "
START_TASK_SCRIPT+="docker images | grep -q \\\"${DOCKER_IMAGE_NAME}\\\" || docker pull \\\"$CONTAINER_IMAGE\\\"; "
START_TASK_SCRIPT+="docker --version; "
START_TASK_SCRIPT+="echo Batch node ready"
START_TASK_SCRIPT+="'"

echo "[INFO] Creating Batch pool $BATCH_POOL_ID with VM size $VM_SIZE ..."

# Create a JSON configuration for the pool in the current directory
# This avoids WSL /tmp path translation issues
POOL_JSON="./pool_config_${BATCH_POOL_ID}.json"

# Use Python to properly create the JSON - pass values as environment variables
POOL_ID="$BATCH_POOL_ID" \
POOL_VM_SIZE="$VM_SIZE" \
POOL_IMAGE_ID="$IMAGE_ID" \
POOL_NODE_AGENT="$NODE_AGENT_SKU" \
POOL_START_TASK="$START_TASK_SCRIPT" \
python3 << 'PYTHON_EOF' > "$POOL_JSON"
import json
import os

pool_config = {
    "id": os.environ["POOL_ID"],
    "vmSize": os.environ["POOL_VM_SIZE"],
    "virtualMachineConfiguration": {
        "imageReference": {
            "virtualMachineImageId": os.environ["POOL_IMAGE_ID"]
        },
        "nodeAgentSKUId": os.environ["POOL_NODE_AGENT"]
    },
    "targetDedicatedNodes": 1,
    "startTask": {
        "commandLine": os.environ["POOL_START_TASK"],
        "waitForSuccess": True,
        "userIdentity": {
            "autoUser": {
                "scope": "pool",
                "elevationLevel": "admin"
            }
        },
        "maxTaskRetryCount": 0
    }
}

print(json.dumps(pool_config, indent=2))
PYTHON_EOF

# Verify the JSON file was created and is valid
if [[ ! -f "$POOL_JSON" ]]; then
  echo "[ERROR] Failed to create pool configuration file: $POOL_JSON" >&2
  exit 1
fi

echo "[INFO] Pool configuration file created: $POOL_JSON"
echo "[INFO] Validating JSON syntax..."
if ! python3 -m json.tool "$POOL_JSON" > /dev/null 2>&1; then
  echo "[WARN] JSON validation failed, but continuing anyway..."
fi

# Create the pool using the JSON configuration with explicit account details
run_cmd "Create Batch pool" \
  az batch pool create \
    --account-name "$BATCH_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --json-file "$POOL_JSON"

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

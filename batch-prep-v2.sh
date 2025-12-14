#!/bin/bash
# batch-prep-v2.sh - Modular Azure Batch Setup Script
#
# This script provides three execution modes for Azure Batch infrastructure:
#   --image-only: Create VM image only (~20-25 min)
#   --batch-only: Create Batch pool from existing image (~5-10 min) 
#   --full: Create both image and Batch infrastructure (default)
#
# For detailed documentation, run: ./batch-prep-v2.sh --help

set -euo pipefail

# ---------------------------
# EXECUTION MODE VARIABLES
# ---------------------------
EXECUTION_MODE="full"
VALIDATE_ONLY=false
DRY_RUN=false
OVERRIDE_POOL_ID=""
OVERRIDE_VM_SIZE=""
OVERRIDE_NODE_COUNT="1"
OVERRIDE_IMAGE_ID=""
OVERRIDE_GPU=""
OVERRIDE_OS=""

# ---------------------------
# PARSE COMMAND LINE ARGUMENTS
# ---------------------------
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --image-only) EXECUTION_MODE="image-only"; shift ;;
      --batch-only) EXECUTION_MODE="batch-only"; shift ;;
      --full) EXECUTION_MODE="full"; shift ;;
      --validate) EXECUTION_MODE="validate"; VALIDATE_ONLY=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --pool-id) OVERRIDE_POOL_ID="$2"; shift 2 ;;
      --vm-size) OVERRIDE_VM_SIZE="$2"; shift 2 ;;
      --nodes) OVERRIDE_NODE_COUNT="$2"; shift 2 ;;
      --image-id) OVERRIDE_IMAGE_ID="$2"; shift 2 ;;
      --gpu) OVERRIDE_GPU="true"; shift ;;
      --cpu) OVERRIDE_GPU="false"; shift ;;
      --os) OVERRIDE_OS="$2"; shift 2 ;;
      --help|-h) show_help; exit 0 ;;
      *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
    esac
  done
}

show_help() {
  cat << 'EOF'
Azure Batch Pool Setup Script (Modular Version)

USAGE:
  ./batch-prep-v2.sh [MODE] [OPTIONS]

EXECUTION MODES:
  (default)           Full deployment - create image and Batch infrastructure (~25-30 min)
  --image-only        Create VM image only (~20-25 min)
  --batch-only        Create Batch pool from existing image (~5-10 min)
  --validate          Run pre-validation checks only

OPTIONS:
  --pool-id <id>      Override Batch pool ID (batch-only mode)
  --vm-size <size>    Override VM size (batch-only mode)
  --nodes <count>     Override node count (default: 1)
  --image-id <id>     Use specific image resource ID (batch-only mode)
  --gpu               Enable GPU support
  --cpu               Enable CPU-only mode
  --os <ubuntu|almalinux>  Select base OS
  --dry-run           Show what would be done without executing
  --help, -h          Show this help message

EXAMPLES:
  # Create base image once (25 min)
  ./batch-prep-v2.sh --image-only --gpu --os ubuntu

  # Create multiple pools from same image (5 min each)
  ./batch-prep-v2.sh --batch-only --pool-id dev-pool --vm-size Standard_NC6 --nodes 1
  ./batch-prep-v2.sh --batch-only --pool-id test-pool --vm-size Standard_NC6 --nodes 2
  ./batch-prep-v2.sh --batch-only --pool-id prod-pool --vm-size Standard_NC12 --nodes 10

  # Full deployment (backward compatible)
  ./batch-prep-v2.sh --gpu --os ubuntu

  # Validation only
  ./batch-prep-v2.sh --validate

OUTPUT FILES:
  image_metadata.json    - Created by --image-only mode
  batch_metadata.json    - Created by --batch-only mode
  logs/*.log             - Execution logs

TIME SAVINGS:
  Traditional: 3 pools × 25 min = 75 minutes
  Modular: 25 min (image) + 3 × 5 min (pools) = 40 minutes
  Savings: 35 minutes (47% faster)
EOF
}

# Parse arguments
parse_arguments "$@"

# ---------------------------
# CONFIGURATION SECTION
# ---------------------------
BASE_OS="${OVERRIDE_OS:-ubuntu}"
OS_VERSION="22.04"
RESOURCE_GROUP="batch-pool-verify"
LOCATION="swedencentral"

# GPU Configuration
if [[ -n "$OVERRIDE_GPU" ]]; then
  ENABLE_GPU="$OVERRIDE_GPU"
else
  ENABLE_GPU=false
fi

GPU_VM_SIZE="Standard_NC4as_T4_v3"
CPU_VM_SIZE="Standard_D2s_v3"

# Apply VM size override
if [[ -n "$OVERRIDE_VM_SIZE" ]]; then
  VM_SIZE="$OVERRIDE_VM_SIZE"
elif [[ "$ENABLE_GPU" == "true" ]]; then
  VM_SIZE="$GPU_VM_SIZE"
else
  VM_SIZE="$CPU_VM_SIZE"
fi

VM_NAME="batch-custom-vm"
ADMIN_USERNAME="azureuser"

# Shared Image Gallery Configuration
GALLERY_NAME="batchImageGallery"
IMAGE_DEFINITION_NAME="batchCustomImage"
IMAGE_VERSION="1.0.0"
IMAGE_PUBLISHER="MyCompany"
IMAGE_OFFER="BatchImages"

# Batch Configuration
BATCH_ACCOUNT_NAME="mybatch$RANDOM"
BATCH_POOL_ID="${OVERRIDE_POOL_ID:-myBatchPool}"

# Container Registry Configuration
CREATE_ACR=false
ACR_NAME="batchacr$RANDOM"
ACR_SKU="Basic"
BUILD_DOCKER_IMAGE=false
DOCKER_IMAGE_NAME="batch-gpu-pytorch"
DOCKER_IMAGE_TAG="latest"
PRELOAD_IMAGES=false

# Metadata file paths
IMAGE_METADATA_FILE="image_metadata.json"
BATCH_METADATA_FILE="batch_metadata.json"

# Auto-configure based on BASE_OS selection
configure_os_settings() {
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
  
  # Container image selection
  if [[ "$ENABLE_GPU" == "true" ]]; then
    if [[ "$BUILD_DOCKER_IMAGE" == "true" && "$CREATE_ACR" == "true" ]]; then
      CONTAINER_IMAGE="${ACR_NAME}.azurecr.io/${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}"
    else
      CONTAINER_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"
    fi
  else
    CONTAINER_IMAGE="ubuntu:22.04"
  fi
}

configure_os_settings

HYPERV_GENERATION="V1"

# Create logs directory
LOG_DIR="./logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/batch_prep_v2_$(date +%Y%m%d_%H%M%S).log"

# Redirect all output to console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Azure Batch Setup Script (Modular v2)"
echo "=========================================="
echo "[INFO] Execution mode: $EXECUTION_MODE"
echo "[INFO] Base OS: $BASE_OS $OS_VERSION"
echo "[INFO] GPU Enabled: $ENABLE_GPU"
echo "[INFO] VM Size: $VM_SIZE"
echo "[INFO] Location: $LOCATION"
echo "[INFO] Logs: $LOG_FILE"
echo ""

# ---------------------------
# HELPER FUNCTIONS
# ---------------------------
run_cmd() {
  local description="$1"
  shift
  echo "[INFO] $description..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would run: $*"
    return 0
  fi
  
  if "$@"; then
    echo "[SUCCESS] $description"
  else
    echo "[ERROR] Failed: $description" >&2
    exit 1
  fi
}

# Save image metadata to JSON file
save_image_metadata() {
  local image_id="$1"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  echo "[INFO] Saving image metadata to $IMAGE_METADATA_FILE..."
  
  cat > "$IMAGE_METADATA_FILE" << EOF
{
  "imageId": "$image_id",
  "nodeAgentSku": "$NODE_AGENT_SKU",
  "galleryName": "$GALLERY_NAME",
  "imageName": "$IMAGE_DEFINITION_NAME",
  "version": "$IMAGE_VERSION",
  "location": "$LOCATION",
  "baseOS": "$BASE_OS",
  "osVersion": "$OS_VERSION",
  "gpuEnabled": $ENABLE_GPU,
  "vmSize": "$VM_SIZE",
  "createdAt": "$timestamp",
  "resourceGroup": "$RESOURCE_GROUP"
}
EOF
  
  echo "[SUCCESS] Image metadata saved to $IMAGE_METADATA_FILE"
}

# Load image metadata from JSON file
load_image_metadata() {
  if [[ -n "$OVERRIDE_IMAGE_ID" ]]; then
    IMAGE_ID="$OVERRIDE_IMAGE_ID"
    echo "[INFO] Using override image ID: $IMAGE_ID"
    return 0
  fi
  
  if [[ ! -f "$IMAGE_METADATA_FILE" ]]; then
    echo "[ERROR] Image metadata file not found: $IMAGE_METADATA_FILE" >&2
    echo "[ERROR] You must run --image-only mode first OR provide --image-id" >&2
    echo "[INFO] Available images in gallery:" >&2
    az sig image-version list --gallery-name "$GALLERY_NAME" \
      --gallery-image-definition "$IMAGE_DEFINITION_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --query "[].{Version:name,State:provisioningState}" -o table 2>/dev/null || echo "  (No images found)"
    exit 1
  fi
  
  echo "[INFO] Loading image metadata from $IMAGE_METADATA_FILE..."
  
  # Parse JSON using Python
  if command -v python3 &> /dev/null; then
    IMAGE_ID=$(python3 -c "import json; print(json.load(open('$IMAGE_METADATA_FILE'))['imageId'])" 2>/dev/null || echo "")
    NODE_AGENT_SKU=$(python3 -c "import json; print(json.load(open('$IMAGE_METADATA_FILE')).get('nodeAgentSku', '$NODE_AGENT_SKU'))" 2>/dev/null || echo "$NODE_AGENT_SKU")
    LOCATION=$(python3 -c "import json; print(json.load(open('$IMAGE_METADATA_FILE')).get('location', '$LOCATION'))" 2>/dev/null || echo "$LOCATION")
  else
    echo "[ERROR] Python3 is required to parse metadata file" >&2
    exit 1
  fi
  
  if [[ -z "$IMAGE_ID" ]]; then
    echo "[ERROR] Failed to load image ID from metadata file" >&2
    exit 1
  fi
  
  echo "[SUCCESS] Loaded image metadata"
  echo "[INFO]   Image ID: $IMAGE_ID"
  echo "[INFO]   Node Agent SKU: $NODE_AGENT_SKU"
}

# Save batch metadata to JSON file
save_batch_metadata() {
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  echo "[INFO] Saving batch metadata to $BATCH_METADATA_FILE..."
  
  cat > "$BATCH_METADATA_FILE" << EOF
{
  "batchAccount": "$BATCH_ACCOUNT_NAME",
  "poolId": "$BATCH_POOL_ID",
  "imageId": "$IMAGE_ID",
  "vmSize": "$VM_SIZE",
  "nodeCount": $OVERRIDE_NODE_COUNT,
  "location": "$LOCATION",
  "gpuEnabled": $ENABLE_GPU,
  "baseOS": "$BASE_OS",
  "createdAt": "$timestamp",
  "resourceGroup": "$RESOURCE_GROUP"
}
EOF
  
  echo "[SUCCESS] Batch metadata saved to $BATCH_METADATA_FILE"
}

# ---------------------------
# VALIDATION FUNCTIONS
# ---------------------------
run_prevalidation_checks() {
  echo ""
  echo "=========================================="
  echo "PRE-VALIDATION CHECKS"
  echo "=========================================="
  
  # Check Azure CLI
  if ! command -v az &> /dev/null; then
    echo "[ERROR] Azure CLI not installed. Visit: https://aka.ms/InstallAzureCLI" >&2
    exit 1
  fi
  echo "[INFO] ✓ Azure CLI is installed"
  
  # Check Azure login
  if ! az account show &> /dev/null; then
    echo "[ERROR] Not logged in to Azure. Run: az login" >&2
    exit 1
  fi
  
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
  SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
  echo "[INFO] ✓ Logged in to Azure"
  echo "[INFO]   Subscription: $SUBSCRIPTION_NAME"
  
  # Check Python3 (required for JSON parsing)
  if ! command -v python3 &> /dev/null; then
    echo "[ERROR] Python3 is required but not found" >&2
    exit 1
  fi
  echo "[INFO] ✓ Python3 is available"
  
  # Check resource providers
  echo "[INFO] Checking required resource providers..."
  REQUIRED_PROVIDERS=("Microsoft.Compute" "Microsoft.Network" "Microsoft.Batch")
  
  for provider in "${REQUIRED_PROVIDERS[@]}"; do
    state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv 2>/dev/null | tr -d '\r' | xargs)
    if [[ "$state" == "Registered" ]]; then
      echo "[INFO] ✓ $provider is registered"
    else
      echo "[WARN] $provider needs registration (state: $state)"
      if [[ "$DRY_RUN" != "true" ]]; then
        echo "[INFO] Registering $provider..."
        az provider register --namespace "$provider" --wait
        echo "[INFO] ✓ $provider registered"
      fi
    fi
  done
  
  # Check VM size availability
  echo "[INFO] Checking VM size availability in $LOCATION..."
  vm_available=$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --all --query "[?name=='$VM_SIZE' && !restrictions]" -o tsv 2>/dev/null)
  if [[ -z "$vm_available" ]]; then
    echo "[ERROR] VM size $VM_SIZE is not available in region $LOCATION" >&2
    exit 1
  fi
  echo "[INFO] ✓ VM size $VM_SIZE is available in $LOCATION"
  
  # Check GPU quota if needed
  if [[ "$ENABLE_GPU" == "true" ]]; then
    echo "[INFO] Checking GPU quota..."
    
    # Determine quota family based on VM size
    if [[ "$VM_SIZE" == *"NC4as_T4"* || "$VM_SIZE" == *"NC8as_T4"* || "$VM_SIZE" == *"NC16as_T4"* || "$VM_SIZE" == *"NC64as_T4"* ]]; then
      QUOTA_FAMILY="NCASv3_T4"
    elif [[ "$VM_SIZE" == *"NC6s_v3"* || "$VM_SIZE" == *"NC12s_v3"* || "$VM_SIZE" == *"NC24s_v3"* ]]; then
      QUOTA_FAMILY="NCSv3"
    else
      QUOTA_FAMILY="NC"
    fi
    
    quota_info=$(az vm list-usage --location "$LOCATION" --query "[?contains(name.value, '$QUOTA_FAMILY')]" -o json 2>/dev/null)
    quota_limit=$(echo "$quota_info" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[0]['limit'] if data else 0)" 2>/dev/null || echo "0")
    
    if [[ "$quota_limit" == "0" ]]; then
      echo "[ERROR] No GPU quota available for $QUOTA_FAMILY family in $LOCATION" >&2
      echo "[INFO] Request a quota increase in Azure Portal > Quotas" >&2
      exit 1
    fi
    echo "[INFO] ✓ GPU quota available: $quota_limit vCPUs for $QUOTA_FAMILY family"
  fi
  
  echo "[INFO] ✓ All pre-validation checks passed"
  echo ""
}

# ---------------------------
# WORKFLOW FUNCTIONS
# ---------------------------

# Image creation workflow
create_image_workflow() {
  echo ""
  echo "=========================================="
  echo "IMAGE CREATION WORKFLOW"
  echo "=========================================="
  echo "[INFO] This will take approximately 20-25 minutes"
  echo ""
  
  # Create resource group
  echo "[INFO] Creating/updating resource group..."
  run_cmd "Create resource group" \
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
  
  # Create VM
  if az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" &> /dev/null; then
    echo "[INFO] VM $VM_NAME already exists. Skipping VM creation."
  else
    echo "[INFO] Creating VM $VM_NAME..."
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
  
  # Wait for VM
  echo "[INFO] Waiting for VM to be ready..."
  run_cmd "Wait for VM" \
    az vm wait --created --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
  run_cmd "Wait for VM running state" \
    az vm wait --updated --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
  
  echo "[SUCCESS] VM is running"
  
  # Install GPU drivers if enabled
  if [[ "$ENABLE_GPU" == "true" ]]; then
    echo "[INFO] Installing NVIDIA GPU drivers..."
    extension_status=$(az vm extension list --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --query "[?name=='NvidiaGpuDriverLinux'].properties.provisioningState" -o tsv 2>/dev/null || echo "")
    
    if [[ "$extension_status" == "Succeeded" ]]; then
      echo "[INFO] GPU drivers already installed"
    else
      run_cmd "Install NVIDIA GPU drivers" \
        az vm extension set \
          --resource-group "$RESOURCE_GROUP" \
          --vm-name "$VM_NAME" \
          --name NvidiaGpuDriverLinux \
          --publisher Microsoft.HpcCompute \
          --version 1.10 \
          --output none
      
      echo "[INFO] Waiting for GPU driver installation (this may take 5-10 minutes)..."
      sleep 60
      
      # Wait for extension to complete
      timeout=1200  # 20 minutes
      elapsed=0
      while [[ $elapsed -lt $timeout ]]; do
        status=$(az vm extension show --resource-group "$RESOURCE_GROUP" --vm-name "$VM_NAME" --name NvidiaGpuDriverLinux --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")
        if [[ "$status" == "Succeeded" ]]; then
          echo "[SUCCESS] GPU drivers installed"
          break
        elif [[ "$status" == "Failed" ]]; then
          echo "[ERROR] GPU driver installation failed" >&2
          exit 1
        fi
        echo "[INFO] Extension status: $status (waiting...)"
        sleep 30
        elapsed=$((elapsed + 30))
      done
      
      if [[ $elapsed -ge $timeout ]]; then
        echo "[ERROR] GPU driver installation timed out" >&2
        exit 1
      fi
    fi
  fi
  
  # Install Docker
  echo "[INFO] Installing Docker on VM..."
  
  if [[ "$BASE_OS" == "ubuntu" ]]; then
    DOCKER_INSTALL_SCRIPT='sudo apt-get update && sudo apt-get install -y docker.io && sudo systemctl start docker && sudo systemctl enable docker && sudo usermod -aG docker $USER'
  else
    # AlmaLinux
    DOCKER_INSTALL_SCRIPT='sudo dnf install -y docker && sudo systemctl start docker && sudo systemctl enable docker && sudo usermod -aG docker $USER'
  fi
  
  run_cmd "Install Docker" \
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "$DOCKER_INSTALL_SCRIPT" \
      --output none
  
  echo "[SUCCESS] Docker installed"
  
  # Deallocate and generalize VM
  echo "[INFO] Deallocating VM..."
  run_cmd "Deallocate VM" \
    az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
  
  echo "[INFO] Generalizing VM..."
  run_cmd "Generalize VM" \
    az vm generalize --resource-group "$RESOURCE_GROUP" --name "$VM_NAME"
  
  # Create Shared Image Gallery
  echo "[INFO] Creating Shared Image Gallery..."
  if ! az sig show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" &> /dev/null; then
    run_cmd "Create Shared Image Gallery" \
      az sig create --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --output none
  else
    echo "[INFO] Gallery already exists"
  fi
  
  # Create image definition
  echo "[INFO] Creating image definition..."
  if ! az sig image-definition show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --gallery-image-definition "$IMAGE_DEFINITION_NAME" &> /dev/null; then
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
  else
    echo "[INFO] Image definition already exists"
  fi
  
  # Create managed image
  echo "[INFO] Creating managed image..."
  MANAGED_IMAGE_NAME="${VM_NAME}-image"
  
  if az image show --resource-group "$RESOURCE_GROUP" --name "$MANAGED_IMAGE_NAME" &> /dev/null; then
    echo "[INFO] Deleting existing managed image..."
    az image delete --resource-group "$RESOURCE_GROUP" --name "$MANAGED_IMAGE_NAME" --yes
  fi
  
  run_cmd "Create managed image" \
    az image create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$MANAGED_IMAGE_NAME" \
      --source "$VM_NAME" \
      --output none
  
  MANAGED_IMAGE_ID=$(az image show --resource-group "$RESOURCE_GROUP" --name "$MANAGED_IMAGE_NAME" --query id -o tsv | tr -d '\n\r\t')
  
  # Create image version
  echo "[INFO] Creating image version in gallery..."
  if az sig image-version show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --gallery-image-definition "$IMAGE_DEFINITION_NAME" --gallery-image-version "$IMAGE_VERSION" &> /dev/null; then
    echo "[INFO] Deleting existing image version..."
    az sig image-version delete \
      --resource-group "$RESOURCE_GROUP" \
      --gallery-name "$GALLERY_NAME" \
      --gallery-image-definition "$IMAGE_DEFINITION_NAME" \
      --gallery-image-version "$IMAGE_VERSION"
  fi
  
  run_cmd "Create image version" \
    az sig image-version create \
      --resource-group "$RESOURCE_GROUP" \
      --gallery-name "$GALLERY_NAME" \
      --gallery-image-definition "$IMAGE_DEFINITION_NAME" \
      --gallery-image-version "$IMAGE_VERSION" \
      --managed-image "$MANAGED_IMAGE_ID" \
      --replica-count 1 \
      --output none
  
  # Set IMAGE_ID for saving metadata
  SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr -d '\n\r\t')
  IMAGE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/galleries/$GALLERY_NAME/images/$IMAGE_DEFINITION_NAME/versions/$IMAGE_VERSION"
  
  save_image_metadata "$IMAGE_ID"
  
  echo ""
  echo "=========================================="
  echo "IMAGE CREATION COMPLETE"
  echo "=========================================="
  echo "[INFO] Image ID: $IMAGE_ID"
  echo "[INFO] Metadata: $IMAGE_METADATA_FILE"
  echo "[INFO] Use --batch-only mode to create pools from this image"
  echo ""
}

# Batch pool creation workflow
create_batch_workflow() {
  echo ""
  echo "=========================================="
  echo "BATCH POOL CREATION WORKFLOW"
  echo "=========================================="
  echo "[INFO] This will take approximately 5-10 minutes"
  echo ""
  
  # Load image metadata if in batch-only mode
  if [[ "$EXECUTION_MODE" == "batch-only" ]]; then
    load_image_metadata
  else
    # In full mode, IMAGE_ID is already set
    SUBSCRIPTION_ID=$(az account show --query id -o tsv | tr -d '\n\r\t')
    IMAGE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/galleries/$GALLERY_NAME/images/$IMAGE_DEFINITION_NAME/versions/$IMAGE_VERSION"
  fi
  
  # Create resource group if needed
  echo "[INFO] Creating/updating resource group..."
  run_cmd "Create resource group" \
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
  
  # Create Batch account
  if az batch account show --name "$BATCH_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
    echo "[INFO] Batch account $BATCH_ACCOUNT_NAME already exists"
  else
    echo "[INFO] Creating Batch account $BATCH_ACCOUNT_NAME..."
    run_cmd "Create Batch account" \
      az batch account create \
        --name "$BATCH_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    
    echo "[INFO] Waiting for Batch account to be ready..."
    sleep 30
  fi
  
  # Set Batch context
  run_cmd "Set Batch account context" \
    az batch account login --name "$BATCH_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP"
  
  echo "[INFO] Using image: $IMAGE_ID"
  
  # Create pool configuration JSON
  POOL_JSON="./pool_config_${BATCH_POOL_ID}.json"
  
  # Define start task for container runtime
  if [[ "$ENABLE_GPU" == "true" ]]; then
    START_TASK_CMD="/bin/bash -c 'nvidia-smi || echo No GPU; docker --version || echo No Docker'"
  else
    START_TASK_CMD="/bin/bash -c 'docker --version || echo No Docker'"
  fi
  
  echo "[INFO] Creating pool configuration..."
  cat > "$POOL_JSON" << EOF
{
  "id": "$BATCH_POOL_ID",
  "vmSize": "$VM_SIZE",
  "virtualMachineConfiguration": {
    "imageReference": {
      "virtualMachineImageId": "$IMAGE_ID"
    },
    "nodeAgentSKUId": "$NODE_AGENT_SKU"
  },
  "targetDedicatedNodes": $OVERRIDE_NODE_COUNT,
  "startTask": {
    "commandLine": "$START_TASK_CMD",
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
  
  # Validate JSON
  if ! python3 -m json.tool "$POOL_JSON" > /dev/null 2>&1; then
    echo "[ERROR] Invalid JSON in pool configuration" >&2
    cat "$POOL_JSON"
    exit 1
  fi
  
  echo "[INFO] Pool configuration created: $POOL_JSON"
  
  # Create pool
  echo "[INFO] Creating Batch pool $BATCH_POOL_ID..."
  run_cmd "Create Batch pool" \
    az batch pool create \
      --account-name "$BATCH_ACCOUNT_NAME" \
      --json-file "$POOL_JSON"
  
  # Clean up temp file
  rm -f "$POOL_JSON"
  
  save_batch_metadata
  
  echo ""
  echo "=========================================="
  echo "BATCH POOL CREATION COMPLETE"
  echo "=========================================="
  echo "[INFO] Batch Account: $BATCH_ACCOUNT_NAME"
  echo "[INFO] Pool ID: $BATCH_POOL_ID"
  echo "[INFO] VM Size: $VM_SIZE"
  echo "[INFO] Node Count: $OVERRIDE_NODE_COUNT"
  echo "[INFO] Metadata: $BATCH_METADATA_FILE"
  echo ""
}

# ---------------------------
# MAIN EXECUTION FLOW
# ---------------------------

# Run validation checks
run_prevalidation_checks

# Exit if validation-only mode
if [[ "$VALIDATE_ONLY" == "true" ]]; then
  echo "=========================================="
  echo "VALIDATION SUCCESSFUL"
  echo "=========================================="
  echo "All prerequisites are met. You can now run the script to create resources."
  exit 0
fi

# Execute based on mode
case "$EXECUTION_MODE" in
  "image-only")
    create_image_workflow
    ;;
  "batch-only")
    create_batch_workflow
    ;;
  "full")
    create_image_workflow
    create_batch_workflow
    ;;
  *)
    echo "[ERROR] Unknown execution mode: $EXECUTION_MODE" >&2
    exit 1
    ;;
esac

echo ""
echo "=========================================="
echo "DEPLOYMENT COMPLETE"
echo "=========================================="

if [[ "$EXECUTION_MODE" == "image-only" ]]; then
  echo "[INFO] VM image created successfully"
  echo "[INFO] Next: Use --batch-only mode to create pools"
  echo ""
  echo "Example:"
  echo "  ./batch-prep-v2.sh --batch-only --pool-id my-pool --nodes 2"
elif [[ "$EXECUTION_MODE" == "batch-only" ]]; then
  echo "[INFO] Batch pool created successfully"
  echo "[INFO] Pool is ready for job submission"
  echo ""
  echo "Submit jobs using:"
  echo "  az batch job create --id my-job --pool-id $BATCH_POOL_ID"
else
  echo "[INFO] Full deployment completed successfully"
  echo "[INFO] Batch pool is ready for job submission"
fi

echo ""
echo "[INFO] Full logs available at: $LOG_FILE"
echo ""

# End of script

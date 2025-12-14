# Quick Start Guide

## Prerequisites Check

```bash
# Check Azure CLI is installed
az --version

# Login to Azure
az login

# Check your subscription
az account show --output table

# Run pre-validation (recommended)
cd azure-batch-demo
./batch-prep.sh --validate
```

If validation passes, you're ready to deploy!

## Deployment Approaches

The script supports two workflows:

### Traditional: Full Deployment (Simple but Slower)
Create everything in one run (~25-30 minutes):
```bash
./batch-prep.sh
```

**With verification** (recommended to test pool configuration):
```bash
./batch-prep.sh --verify
```

### Modular: Separate Image and Pool Creation (Recommended for Multiple Pools)
**Time Savings: 47% faster when creating multiple pools**

**Step 1: Create base image once** (~20-25 minutes):
```bash
./batch-prep.sh --image-only
```

**Step 2: Create multiple pools from same image** (~5 minutes each):
```bash
# Development pool with verification
./batch-prep.sh --batch-only --pool-id dev-pool --vm-size Standard_NC4as_T4_v3 --nodes 1 --verify

# Testing pool
./batch-prep.sh --batch-only --pool-id test-pool --vm-size Standard_NC6s_v3 --nodes 2

# Production pool
./batch-prep.sh --batch-only --pool-id prod-pool --vm-size Standard_NC12s_v3 --nodes 10
```

**Why use modular workflow?**
- ✅ Create image once, reuse for many pools
- ✅ Rapid pool creation (5 min vs 25 min)
- ✅ Test different VM sizes without rebuilding image
- ✅ Separate dev/test/prod environments efficiently
- ✅ Save 35+ minutes when creating 3+ pools

**Time Comparison:**
- Traditional: 3 pools × 25 min = 75 minutes
- Modular: 25 min (image) + 3 × 5 min (pools) = 40 minutes
- **Savings: 35 minutes (47% faster)**

## Choosing Your Base OS

The script supports both Ubuntu and AlmaLinux. Choose based on your needs:

**Ubuntu 22.04** (Default):
- Best for: Maximum compatibility, easiest setup
- Includes: All libraries including OpenSlide
- Best for: New users, development, ML workloads

**AlmaLinux 8/9**:
- Best for: Enterprise environments, RHEL compatibility
- Note: OpenSlide not included (must build from source)
- Best for: Production, compliance requirements

See [MULTI-OS-GUIDE.md](MULTI-OS-GUIDE.md) for detailed comparison.

## GPU Workload Setup

### 1. Choose Your OS

Edit `batch-prep.sh`:
```bash
# For Ubuntu (recommended)
BASE_OS="ubuntu"
OS_VERSION="22.04"

# OR for AlmaLinux
BASE_OS="almalinux"
OS_VERSION="8"
```

### 2. Check GPU Quota

```bash
# Check quota for T4 GPUs (NCASv3_T4 family)
az vm list-usage --location eastus2 --query "[?contains(name.value, 'NCASv3_T4')]" -o table

# Check quota for V100 GPUs (NCSv3 family)
az vm list-usage --location eastus2 --query "[?contains(name.value, 'NCSv3')]" -o table
```

### 3. Configure Script for GPU with Custom Docker Image

Edit `batch-prep.sh`:
```bash
ENABLE_GPU=true
GPU_VM_SIZE="Standard_NC4as_T4_v3"
LOCATION="eastus2"
RESOURCE_GROUP="my-gpu-batch"

# Docker/ACR Configuration
CREATE_ACR=true
BUILD_DOCKER_IMAGE=true
PRELOAD_IMAGES=true
```

**Note**: Building the Docker image requires Docker installed locally. If you don't have Docker, set `BUILD_DOCKER_IMAGE=false` and use a public image.

### 3. Run Script

```bash
chmod +x batch-prep.sh

# Run pre-validation first
./batch-prep.sh --validate

# Option A: Full deployment (traditional)
./batch-prep.sh

# Option B: Modular workflow (recommended for multiple pools)
# Create image only
./batch-prep.sh --image-only

# Then create pool(s) when ready
./batch-prep.sh --batch-only --pool-id my-pool --nodes 2
```

**What happens (full deployment):**
1. ✓ Creates resource group
2. ✓ Creates Azure Container Registry
3. ✓ Builds Docker image with PyTorch, models (15-30 min)
4. ✓ Pushes image to ACR
5. ✓ Creates VM with GPU drivers
6. ✓ Preloads Docker image on VM
7. ✓ Creates Batch account and pool

**Metadata Files:**
- `image_metadata.json` - Created by --image-only, used by --batch-only
- `batch_metadata.json` - Created by --batch-only with pool details

### 4. Verify GPU Pool

```bash
# Check pool status
az batch pool show --pool-id myBatchPool --account-name YOUR_BATCH_ACCOUNT \
  --query "{ID:id, State:allocationState, Nodes:currentDedicatedNodes}" -o table

# List nodes
az batch node list --pool-id myBatchPool --account-name YOUR_BATCH_ACCOUNT -o table

# Check node has GPU
az batch node file list --pool-id myBatchPool --node-id NODE_ID \
  --account-name YOUR_BATCH_ACCOUNT --path startup
```

## CPU Workload Setup

### 1. Configure Script for CPU

Edit `batch-prep.sh`:
```bash
ENABLE_GPU=false
CPU_VM_SIZE="Standard_D4s_v3"
LOCATION="eastus2"
RESOURCE_GROUP="my-cpu-batch"
```

### 2. Run Script

```bash
# Full deployment
./batch-prep.sh

# Or modular (if creating multiple CPU pools)
./batch-prep.sh --image-only
./batch-prep.sh --batch-only --pool-id cpu-pool-1 --nodes 4
```

## Using Your Own Docker Image

If you already have a Docker image, you can use it instead of building one:

```bash
# Edit batch-prep.sh
CREATE_ACR=false
BUILD_DOCKER_IMAGE=false
PRELOAD_IMAGES=true
CONTAINER_IMAGE="myacr.azurecr.io/myapp:v1.0"

# Create image with preloaded Docker image
./batch-prep.sh --image-only

# Create pool
./batch-prep.sh --batch-only --pool-id my-pool
```

**Supported registries:**
- Azure Container Registry (ACR)
- Docker Hub (public or private)
- Any private registry (may require auth configuration)

See README.md "Using Your Own Docker Image" section for more details.

## Verifying Your Deployment

After creating a pool, you can verify its configuration using the `--verify` flag:

```bash
# Verify during deployment
./batch-prep.sh --verify

# Or verify existing pool
./batch-prep.sh --batch-only --pool-id my-pool --verify
```

**What gets tested:**
- ✓ System configuration and OS version
- ✓ Docker installation
- ✓ GPU drivers and availability (if GPU enabled)
- ✓ Preloaded Docker images (if PRELOAD_IMAGES=true)
- ✓ Container execution capability

**Example output:**
```
=== System Info ===
Linux batch-node 5.15.0-1052-azure x86_64

=== Docker Info ===
Docker version 24.0.7

=== Docker Images ===
myacr.azurecr.io/batch-gpu-pytorch   latest   abc123   5.2GB

=== GPU Info ===
Tesla T4, Driver Version: 525.125.06

✓ Image preloaded successfully
✓ Docker container executed successfully

[SUCCESS] ✓ Verification passed (exit code: 0)
```

The verification job takes 1-2 minutes and helps catch configuration issues before production use.

## Common Commands

### Monitor Pool Creation

```bash
# Watch pool allocation
watch -n 10 'az batch pool show --pool-id myBatchPool --account-name YOUR_BATCH_ACCOUNT \
  --query "{State:allocationState, Current:currentDedicatedNodes, Target:targetDedicatedNodes}"'
```

### View Start Task Logs

```bash
# Get node ID
NODE_ID=$(az batch node list --pool-id myBatchPool --account-name YOUR_BATCH_ACCOUNT \
  --query "[0].id" -o tsv)

# Download stdout
az batch node file download --pool-id myBatchPool --node-id $NODE_ID \
  --file-path startup/stdout.txt --destination stdout.txt \
  --account-name YOUR_BATCH_ACCOUNT

# Download stderr
az batch node file download --pool-id myBatchPool --node-id $NODE_ID \
  --file-path startup/stderr.txt --destination stderr.txt \
  --account-name YOUR_BATCH_ACCOUNT

# View logs
cat stdout.txt
cat stderr.txt
```

### Test Docker on Node

```bash
# Connect to node (requires SSH setup)
# Or use run-command:
az batch node exec --pool-id myBatchPool --node-id $NODE_ID \
  --account-name YOUR_BATCH_ACCOUNT --command "docker --version"

# Test GPU access (GPU pools only)
az batch node exec --pool-id myBatchPool --node-id $NODE_ID \
  --account-name YOUR_BATCH_ACCOUNT --command "nvidia-smi"
```

### Resize Pool

```bash
# Scale up
az batch pool resize --pool-id myBatchPool --target-dedicated-nodes 5 \
  --account-name YOUR_BATCH_ACCOUNT --resource-group RESOURCE_GROUP

# Scale down
az batch pool resize --pool-id myBatchPool --target-dedicated-nodes 1 \
  --account-name YOUR_BATCH_ACCOUNT --resource-group RESOURCE_GROUP
```

### Delete Pool

```bash
az batch pool delete --pool-id myBatchPool \
  --account-name YOUR_BATCH_ACCOUNT --yes
```

## Cleanup Everything

```bash
# Delete entire resource group
az group delete --name RESOURCE_GROUP --yes --no-wait

# Or delete specific resources
az batch pool delete --pool-id myBatchPool --account-name YOUR_BATCH_ACCOUNT --yes
az batch account delete --name YOUR_BATCH_ACCOUNT --resource-group RESOURCE_GROUP --yes
az sig delete --resource-group RESOURCE_GROUP --gallery-name batchImageGallery
az vm delete --resource-group RESOURCE_GROUP --name batch-custom-vm --yes
az network vnet delete --resource-group RESOURCE_GROUP --name batch-custom-vmVNET
az network nsg delete --resource-group RESOURCE_GROUP --name batch-custom-vmNSG
```

## Troubleshooting Quick Fixes

### Quota Issue
```bash
# Request increase via portal or CLI
az support tickets create --title "GPU Quota Increase" ...
# Or use Azure Portal > Quotas
```

### VM Not Available in Region
```bash
# Check availability
az vm list-skus --location eastus2 --size Standard_NC --all \
  --query "[?name=='Standard_NC4as_T4_v3']" -o table

# Try different regions
for region in eastus2 southcentralus westus2; do
  echo "=== $region ==="
  az vm list-skus --location $region --size Standard_NC4as_T4_v3 \
    --query "[0].restrictions" -o table
done
```

### Start Task Fails
```bash
# Common causes:
# 1. Docker installation timeout - increase start task timeout
# 2. GPU driver not ready - check nvidia-smi in logs
# 3. Network issues - check node connectivity

# View detailed logs
NODE_ID=$(az batch node list --pool-id myBatchPool --account-name YOUR_BATCH_ACCOUNT --query "[0].id" -o tsv)
az batch node file download --pool-id myBatchPool --node-id $NODE_ID \
  --file-path startup/stderr.txt --destination - --account-name YOUR_BATCH_ACCOUNT
```

## Time Estimates

### Full Deployment
- VM creation: 3-5 minutes
- GPU driver installation: 5-10 minutes
- Docker image build (if enabled): 15-30 minutes
- Image creation: 10-15 minutes
- Batch pool creation: 1-2 minutes
- Node startup (with start task): 5-10 minutes

**Total time**: 25-45 minutes for complete setup

### Modular Workflow
- **Image creation** (--image-only): 20-25 minutes (one time)
- **Pool creation** (--batch-only): 5-10 minutes (per pool)

**Multiple pools example:**
- 1st pool (full): 25 min
- 2nd pool (batch-only): 5 min
- 3rd pool (batch-only): 5 min
- **Total: 35 min** (vs 75 min traditional)

## Cost Estimates (per hour)

- Standard_NC4as_T4_v3 (1x T4 GPU): ~$0.50-0.80
- Standard_NC6s_v3 (1x V100 GPU): ~$3.00-4.00
- Standard_D4s_v3 (CPU): ~$0.20-0.30

Prices vary by region. Check [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) for exact costs.

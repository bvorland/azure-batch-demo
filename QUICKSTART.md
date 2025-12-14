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

## GPU Workload Setup

### 1. Check GPU Quota

```bash
# Check quota for T4 GPUs (NCASv3_T4 family)
az vm list-usage --location eastus2 --query "[?contains(name.value, 'NCASv3_T4')]" -o table

# Check quota for V100 GPUs (NCSv3 family)
az vm list-usage --location eastus2 --query "[?contains(name.value, 'NCSv3')]" -o table
```

### 2. Configure Script for GPU with Custom Docker Image

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

# If validation passes, run full deployment
./batch-prep.sh
```

**What happens:**
1. ✓ Creates resource group
2. ✓ Creates Azure Container Registry
3. ✓ Builds Docker image with PyTorch, models (15-30 min)
4. ✓ Pushes image to ACR
5. ✓ Creates VM with GPU drivers
6. ✓ Optionally preloads Docker image
7. ✓ Creates Batch account and pool

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
./batch-prep.sh
```

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

- VM creation: 3-5 minutes
- GPU driver installation: 5-10 minutes
- Image creation: 10-15 minutes
- Batch pool creation: 1-2 minutes
- Node startup (with start task): 5-10 minutes

**Total time**: 25-45 minutes for complete setup

## Cost Estimates (per hour)

- Standard_NC4as_T4_v3 (1x T4 GPU): ~$0.50-0.80
- Standard_NC6s_v3 (1x V100 GPU): ~$3.00-4.00
- Standard_D4s_v3 (CPU): ~$0.20-0.30

Prices vary by region. Check [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) for exact costs.

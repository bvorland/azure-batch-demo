# batch-prep.sh

A bash script that automates the creation of custom Azure VM images for GPU-enabled Azure Batch pools. This script handles the entire process of setting up GPU drivers and container runtimes without requiring manual SSH access to VMs.

## What It Does

This script automates the following workflow:

1. Creates an Azure VM with GPU support
2. Installs NVIDIA GPU drivers via Azure VM extensions
3. Configures Docker/Moby container runtime with NVIDIA container toolkit
4. Generalizes the VM and creates a custom managed image
5. Creates an Azure Batch account (if needed)
6. Creates an Azure Batch pool using the custom GPU-enabled image

All VM configuration is done using Azure CLI's `az vm run-command`, eliminating the need for SSH access.

## Prerequisites

- Azure CLI installed and configured
- Active Azure subscription
- Bash shell (Linux, macOS, or WSL on Windows)
- Sufficient Azure quota for GPU VMs in your target region
- Appropriate permissions to create Azure resources

## Installation

1. Clone or download this repository
2. Make the script executable:
   ```bash
   chmod +x batch-prep.sh
   ```

## Configuration

Edit the configuration section at the top of the script to customize your deployment:

### Required Settings

- **RESOURCE_GROUP**: Azure Resource Group name (default: `my-batch-rg`)
- **LOCATION**: Azure region (default: `westeurope`)
- **VM_SIZE**: GPU-enabled VM size (default: `Standard_NC4as_T4_v3`)
  - Options: `Standard_NC4as_T4_v3`, `Standard_NC8as_T4_v3`, `Standard_NC16as_T4_v3`, etc.
- **ADMIN_USERNAME**: VM admin username (default: `azureuser`)
- **CUSTOM_IMAGE_NAME**: Name for the managed image to create
- **BATCH_ACCOUNT_NAME**: Batch account name (random suffix added automatically)
- **BATCH_POOL_ID**: Batch pool identifier
- **CONTAINER_IMAGE**: Docker container image to use (update with your registry/image)
- **VM_IMAGE_URN**: Base OS image (default: Ubuntu 22.04 LTS)
- **NODE_AGENT_SKU**: Batch node agent matching OS (default: `batch.node.ubuntu 22.04`)

### Example Configuration

```bash
RESOURCE_GROUP="my-batch-rg"
LOCATION="westeurope"
VM_NAME="batch-custom-vm"
VM_SIZE="Standard_NC4as_T4_v3"
ADMIN_USERNAME="azureuser"
CUSTOM_IMAGE_NAME="myCustomGpuImage"
BATCH_ACCOUNT_NAME="mybatchaccount-$RANDOM"
BATCH_POOL_ID="myGpuPool"
NODE_AGENT_SKU="batch.node.ubuntu 22.04"
CONTAINER_IMAGE="myacr.azurecr.io/mygpuimage:latest"
VM_IMAGE_URN="Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"
```

## Usage

1. Login to Azure CLI:
   ```bash
   az login
   ```

2. Run the script:
   ```bash
   ./batch-prep.sh
   ```

3. Monitor progress in the console output or check the log file in `./logs/batch_prep_YYYYMMDD_HHMMSS.log`

## What Gets Installed

Inside the VM, the script installs:
- Moby Engine (Docker runtime)
- Moby CLI
- jq (JSON processor)
- NVIDIA Container Toolkit
- NVIDIA GPU drivers (via Azure VM extension)

## Logging

All script output is logged to both:
- Console (stdout)
- Log file: `./logs/batch_prep_YYYYMMDD_HHMMSS.log`

The script includes comprehensive error handling and will exit on any critical failure.

## Cost Warning

Running this script will create Azure resources that incur costs, including:
- Virtual machines (especially GPU-enabled VMs)
- Managed images
- Azure Batch accounts and pools
- Associated storage and networking

Remember to clean up resources when finished to avoid ongoing charges.

## Cleanup

To remove created resources:

```bash
# Delete the resource group (removes all resources within it)
az group delete --name my-batch-rg --yes --no-wait

# Or delete individual resources
az batch pool delete --pool-id myGpuPool --yes
az batch account delete --name mybatchaccount-XXXXX --resource-group my-batch-rg --yes
az image delete --resource-group my-batch-rg --name myCustomGpuImage
az vm delete --resource-group my-batch-rg --name batch-custom-vm --yes
```

## Troubleshooting

### Azure CLI not found
```bash
# Install Azure CLI (Ubuntu/Debian)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Or visit: https://docs.microsoft.com/cli/azure/install-azure-cli
```

### Not logged in to Azure
```bash
az login
```

### VM size not available in region
Check available VM sizes in your region:
```bash
az vm list-sizes --location westeurope --output table
```

### Insufficient quota
Request quota increase through Azure Portal under Quotas section.

### Extension installation fails
Check extension status:
```bash
az vm extension list --resource-group my-batch-rg --vm-name batch-custom-vm
```

## Advanced Usage

### Using a Different Base OS

To use a different OS image, update both:
1. `VM_IMAGE_URN` - the base OS image
2. `NODE_AGENT_SKU` - must match the OS (see [Azure Batch node agent SKUs](https://docs.microsoft.com/azure/batch/batch-linux-nodes))

### Multiple Container Images

To prefetch multiple container images, use comma-separated values:
```bash
CONTAINER_IMAGE="image1.azurecr.io/app:latest,image2.azurecr.io/tool:v1"
```

### Skipping VM Creation

If the VM already exists, the script will skip creation and proceed with configuration.

## License

This script is provided as-is without warranty. Use at your own risk.

## Support

For Azure-specific issues, consult the [Azure Batch documentation](https://docs.microsoft.com/azure/batch/) or [Azure CLI documentation](https://docs.microsoft.com/cli/azure/).

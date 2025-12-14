# batch-prep.sh

A bash script that automates the creation of custom Azure VM images for Azure Batch pools supporting both GPU and CPU workloads. This script handles the entire process of setting up GPU drivers (optional), creating Shared Image Gallery images, and deploying Azure Batch pools without requiring manual SSH access to VMs.

## What It Does

This script automates the following workflow:

1. Creates an Azure VM (GPU or CPU based on configuration)
2. Installs NVIDIA GPU drivers via Azure VM extensions (if GPU enabled)
3. Generalizes the VM and creates a Shared Image Gallery image
4. Creates an Azure Batch account (if needed)
5. Creates an Azure Batch pool using the custom image
6. Configures pool start task to install Docker and NVIDIA container toolkit (if GPU enabled)

All VM configuration is done using Azure CLI's `az vm run-command` and VM extensions, eliminating the need for SSH access. Docker is installed via Batch start task to ensure it persists correctly.

## Prerequisites

- Azure CLI installed and configured
- Active Azure subscription
- Bash shell (Linux, macOS, or WSL on Windows)
- Sufficient Azure quota for your target VM size in your region
- Appropriate permissions to create resources (Contributor or Owner role)

**Pro Tip**: Run `./batch-prep.sh --validate` first to verify all prerequisites are met before creating any resources.

## Installation

1. Clone or download this repository
2. Make the script executable:
   ```bash
   chmod +x batch-prep.sh
   ```

## Configuration

Edit the configuration section at the top of the script to customize your deployment:

### Core Settings

- **RESOURCE_GROUP**: Azure Resource Group name (default: `my-batch-rg`)
- **LOCATION**: Azure region (default: `eastus2`)
  - For GPU VMs, recommended: `eastus2`, `southcentralus`, `westus2`, `westeurope`

### GPU vs CPU Configuration

- **ENABLE_GPU**: Set to `true` for GPU workloads, `false` for CPU-only (default: `true`)
- **GPU_VM_SIZE**: GPU-enabled VM size (default: `Standard_NC4as_T4_v3`)
  - Options: `Standard_NC4as_T4_v3`, `Standard_NC6s_v3`, `Standard_NC8as_T4_v3`, etc.
- **CPU_VM_SIZE**: CPU VM size for non-GPU workloads (default: `Standard_D4s_v3`)

### Shared Image Gallery Settings

- **GALLERY_NAME**: Name of the Shared Image Gallery
- **IMAGE_DEFINITION_NAME**: Name of the image definition
- **IMAGE_VERSION**: Version of the image (default: `1.0.0`)
- **IMAGE_PUBLISHER**: Publisher name for the image
- **IMAGE_OFFER**: Offer name for the image
- **IMAGE_SKU**: SKU name for the image

### Batch Configuration

- **BATCH_ACCOUNT_NAME**: Batch account name (random suffix added automatically)
- **BATCH_POOL_ID**: Batch pool identifier
- **NODE_AGENT_SKU**: Batch node agent matching OS (default: `batch.node.ubuntu 22.04`)

### Container Registry & Docker Configuration

- **CREATE_ACR**: Set to `true` to create Azure Container Registry (default: `false`)
- **ACR_NAME**: ACR name (alphanumeric only, globally unique, random suffix added)
- **ACR_SKU**: ACR tier - Basic, Standard, or Premium (default: `Basic`)
- **BUILD_DOCKER_IMAGE**: Set to `true` to build custom Docker image (default: `false`)
- **DOCKER_IMAGE_NAME**: Name for the Docker image (default: `batch-gpu-pytorch`)
- **DOCKER_IMAGE_TAG**: Docker image tag (default: `latest`)
- **PRELOAD_IMAGES**: Set to `true` to preload Docker images on VM (default: `false`)

When `BUILD_DOCKER_IMAGE=true`, the script will:
1. Create an Azure Container Registry (if `CREATE_ACR=true`)
2. Select appropriate Dockerfile based on BASE_OS (Dockerfile.gpu.ubuntu or Dockerfile.gpu.almalinux)
3. Build a GPU-enabled Docker image with PyTorch, OpenCV, FAISS, and pre-loaded Hugging Face models
4. Push the image to your ACR
5. Optionally preload the image on the VM before generalization
6. Configure the Batch pool to use this image

See [DOCKER.md](DOCKER.md) for details on the Docker image contents.

### Example Configuration

#### Ubuntu 22.04 with GPU:
```bash
BASE_OS="ubuntu"
OS_VERSION="22.04"
ENABLE_GPU=true
GPU_VM_SIZE="Standard_NC4as_T4_v3"
LOCATION="eastus2"

# Docker/ACR Configuration
CREATE_ACR=true
BUILD_DOCKER_IMAGE=true
PRELOAD_IMAGES=true
```

#### AlmaLinux 8 with GPU:
```bash
BASE_OS="almalinux"
OS_VERSION="8"
ENABLE_GPU=true
GPU_VM_SIZE="Standard_NC4as_T4_v3"
LOCATION="eastus2"

# Docker/ACR Configuration
CREATE_ACR=true
BUILD_DOCKER_IMAGE=true
PRELOAD_IMAGES=true
```

#### Ubuntu 22.04 CPU Only:
```bash
BASE_OS="ubuntu"
OS_VERSION="22.04"
ENABLE_GPU=false
CPU_VM_SIZE="Standard_D4s_v3"
LOCATION="eastus2"

# Skip Docker image building for CPU
CREATE_ACR=false
BUILD_DOCKER_IMAGE=false
```

## Usage

### Pre-validation (Recommended)

Before running the full script, it's recommended to validate your environment:

```bash
./batch-prep.sh --validate
```

This will check:
- Azure CLI installation and login status
- Required resource providers (automatically registers if needed)
- VM size availability in your target region
- Quota availability for your selected VM family  
- Permissions to create resources
- Location validity

If validation passes, you'll see "VALIDATION SUCCESSFUL" and can proceed with deployment.

### Full Deployment

1. Login to Azure CLI:
   ```bash
   az login
   ```

2. Run the script:
   ```bash
   ./batch-prep.sh
   ```

3. Run with verification (recommended):
   ```bash
   ./batch-prep.sh --verify
   ```
   
   This will automatically test the pool after creation by running a verification job that checks:
   - System configuration
   - Docker installation
   - GPU availability (if enabled)
   - Preloaded Docker images (if PRELOAD_IMAGES=true)

4. Monitor progress in the console output or check the log file in `./logs/batch_prep_YYYYMMDD_HHMMSS.log`

## What Gets Installed

### On the VM Image:
- NVIDIA GPU drivers (via Azure VM extension, if GPU enabled)
- Base Ubuntu 22.04 LTS or AlmaLinux 8/9 system

### On Batch Pool Nodes (via start task):
- Docker (docker.io on Ubuntu, docker-ce on AlmaLinux)
- NVIDIA Container Toolkit (if GPU enabled)

### In the Docker Container (optional custom image):
If you enable `BUILD_DOCKER_IMAGE=true`, a custom Docker image will be built with:
- Python 3.10 (Ubuntu) or 3.11 (AlmaLinux) with pip and setuptools
- PyTorch 2.1.2 with CUDA 12.1 support
- Computer vision libraries: OpenCV, FAISS
  - Note: OpenSlide included on Ubuntu, not available on AlmaLinux
- Hugging Face Transformers with pre-loaded models:
  - facebook/dino-vits8
  - facebook/dino-vits16
- NVIDIA CUDA 12.1.0 with cuDNN 8

See [DOCKER.md](DOCKER.md) for complete details on the Docker image.

The Docker installation happens via the Batch pool start task to ensure it persists correctly across pool nodes.

## Important Notes

### Shared Image Gallery Requirement
Azure Batch requires custom images to be stored in a **Shared Image Gallery**, not as direct managed images. The script automatically creates:
1. A Shared Image Gallery
2. An image definition within the gallery
3. An image version from your generalized VM

### GPU Quota Requirements
For GPU workloads, you need quota for the specific GPU VM family in your region. Common families:
- **NCASv3_T4**: For T4 GPUs (NC4as_T4_v3, NC8as_T4_v3, etc.)
- **NCSv3**: For V100 GPUs (NC6s_v3, NC12s_v3, etc.)

Check your quota with:
```bash
az vm list-usage --location eastus2 --query "[?contains(name.value, 'NC')]" -o table
```

Request increases through Azure Portal > Quotas if needed.

### Hypervisor Generation
The script uses Gen1 (V1) hypervisor for maximum compatibility. If you need Gen2 (V2), update both:
- `VM_IMAGE_URN` to a Gen2 image
- `HYPERV_GENERATION` to `V2`

### Docker Installation Strategy
Docker is installed via the Batch pool start task, not during VM image creation. This ensures:
- Docker persists correctly on pool nodes
- Each node gets a fresh Docker installation
- The image generalization process doesn't remove Docker

## Logging

All script output is logged to both:
- Console (stdout)
- Log file: `./logs/batch_prep_YYYYMMDD_HHMMSS.log`

The script includes comprehensive error handling and will exit on any critical failure.

## Cost Warning

Running this script will create Azure resources that incur costs, including:
- Virtual machines (especially GPU-enabled VMs which can be expensive)
- Shared Image Gallery storage
- Azure Batch accounts and pools
- Associated storage and networking

**Important**: GPU VMs can cost $1-10+ per hour depending on the size. Remember to clean up resources when finished to avoid ongoing charges.

## Cleanup

To remove created resources:

```bash
# Delete the entire resource group (removes all resources within it)
az group delete --name my-batch-rg --yes --no-wait

# Or delete individual resources
az batch pool delete --pool-id myBatchPool --account-name mybatchaccount-XXXXX --resource-group my-batch-rg --yes
az batch account delete --name mybatchaccount-XXXXX --resource-group my-batch-rg --yes
az sig delete --resource-group my-batch-rg --gallery-name batchImageGallery
az vm delete --resource-group my-batch-rg --name batch-custom-vm --yes
```

## Preload Images Feature

### Overview
The script supports preloading Docker images into your custom VM image, which significantly reduces task startup time and network costs for containerized workloads.

### How It Works
When enabled, the script will:
1. Create an Azure Container Registry (ACR)
2. Build your Docker image using `az acr build`
3. Push the image to ACR
4. Pull the image onto the VM before generalization
5. Configure the Batch pool with container support

### Configuration Variables

- **CREATE_ACR** (default: `false`) - Create Azure Container Registry
- **BUILD_DOCKER_IMAGE** (default: `false`) - Build and push Docker image to ACR
- **PRELOAD_IMAGES** (default: `false`) - Preload Docker image on VM before generalization
- **ACR_NAME** - Name for the ACR (auto-generated with random suffix)
- **ACR_SKU** - ACR tier: Basic, Standard, or Premium (default: `Basic`)
- **DOCKER_IMAGE_NAME** - Docker image name (default: `batch-gpu-pytorch`)
- **DOCKER_IMAGE_TAG** - Docker image tag (default: `latest`)

### Usage Examples

#### Example 1: Create image with preloaded Docker container

```bash
CREATE_ACR=true
BUILD_DOCKER_IMAGE=true
PRELOAD_IMAGES=true
ENABLE_GPU=true

./batch-prep.sh
```

This will:
1. Create an ACR
2. Build the Docker image from Dockerfile.gpu.ubuntu (or Dockerfile.gpu.almalinux based on BASE_OS)
3. Push the image to ACR
4. Pull the image onto the VM
5. Create the custom VM image with Docker image cached
6. Create a Batch pool configured to use the preloaded container

#### Example 2: Use existing ACR

```bash
CREATE_ACR=false
BUILD_DOCKER_IMAGE=false
PRELOAD_IMAGES=true
CONTAINER_IMAGE="myacr.azurecr.io/myimage:latest"

./batch-prep.sh
```

### Benefits

- **Faster task startup**: No need to pull large images from ACR on each node
- **Reduced network costs**: Images pulled once during image creation
- **Better for GPU workloads**: Large ML/AI images (PyTorch, TensorFlow, etc.) are pre-cached
- **Consistent environment**: Same image version across all pool nodes

### Pool Container Configuration

When `PRELOAD_IMAGES=true`, the Batch pool is automatically configured with:

```json
"containerConfiguration": {
  "type": "dockerCompatible",
  "containerImageNames": ["<ACR_IMAGE_URL>"]
}
```

This makes the preloaded image available to tasks running on pool nodes.

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
az vm list-sizes --location eastus2 --output table
```

For GPU VMs, check specific availability:
```bash
az vm list-skus --location eastus2 --size Standard_NC --all --output table
```

### Insufficient quota
Check your quota:
```bash
az vm list-usage --location eastus2 --query "[?contains(name.value, 'NC')]" -o table
```
Request quota increase through Azure Portal under Quotas section.

### GPU driver installation fails
Check extension status:
```bash
az vm extension list --resource-group my-batch-rg --vm-name batch-custom-vm
az vm extension show --resource-group my-batch-rg --vm-name batch-custom-vm --name NvidiaGpuDriverLinux
```

### Start task fails on Batch nodes
Download start task logs:
```bash
# List nodes
az batch node list --pool-id myBatchPool --account-name mybatchaccount-XXXXX

# Download logs (replace NODE_ID)
az batch node file download --pool-id myBatchPool --node-id NODE_ID \
  --file-path startup/stdout.txt --destination stdout.txt --account-name mybatchaccount-XXXXX
az batch node file download --pool-id myBatchPool --node-id NODE_ID \
  --file-path startup/stderr.txt --destination stderr.txt --account-name mybatchaccount-XXXXX
```

### Image generation mismatch
If you get "Hypervisor generation mismatch" errors, ensure:
- VM image URN matches HYPERV_GENERATION setting
- Use Gen1 images with `HYPERV_GENERATION="V1"`
- For Gen2, use `-gen2` image URNs

## Advanced Usage

### Switching Between GPU and CPU

Simply change the `ENABLE_GPU` setting:

```bash
# For GPU workloads
ENABLE_GPU=true
GPU_VM_SIZE="Standard_NC4as_T4_v3"
CONTAINER_IMAGE="nvidia/cuda:12.0.0-base-ubuntu22.04"

# For CPU workloads
ENABLE_GPU=false
CPU_VM_SIZE="Standard_D4s_v3"
CONTAINER_IMAGE="ubuntu:22.04"
```

### Using Different GPU VM Sizes

Update the `GPU_VM_SIZE` variable to use different GPU configurations:

```bash
# T4 GPUs (NCASv3_T4 family)
GPU_VM_SIZE="Standard_NC4as_T4_v3"   # 1x T4, 4 vCPUs
GPU_VM_SIZE="Standard_NC8as_T4_v3"   # 1x T4, 8 vCPUs
GPU_VM_SIZE="Standard_NC16as_T4_v3"  # 1x T4, 16 vCPUs
GPU_VM_SIZE="Standard_NC64as_T4_v3"  # 4x T4, 64 vCPUs

# V100 GPUs (NCSv3 family)
GPU_VM_SIZE="Standard_NC6s_v3"       # 1x V100, 6 vCPUs
GPU_VM_SIZE="Standard_NC12s_v3"      # 2x V100, 12 vCPUs
GPU_VM_SIZE="Standard_NC24s_v3"      # 4x V100, 24 vCPUs
```

### Using a Different Base OS

To use a different OS image, update:
```bash
VM_IMAGE_URN="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen1:latest"  # Ubuntu 22.04 Gen1
# or
VM_IMAGE_URN="Canonical:0001-com-ubuntu-server-focal:20_04-lts-gen1:latest"  # Ubuntu 20.04 Gen1

# Also update the node agent SKU to match
NODE_AGENT_SKU="batch.node.ubuntu 22.04"  # For Ubuntu 22.04
# or
NODE_AGENT_SKU="batch.node.ubuntu 20.04"  # For Ubuntu 20.04
```

See [Azure Batch node agent SKUs](https://docs.microsoft.com/azure/batch/batch-linux-nodes) for compatible combinations.

### Scaling the Pool

To create a pool with multiple nodes, modify the pool creation JSON in the script:
```bash
"targetDedicatedNodes": 5,  # Change from 1 to desired number
```

Or after pool creation:
```bash
az batch pool resize --pool-id myBatchPool --target-dedicated-nodes 5 \
  --account-name mybatchaccount-XXXXX
```

### Using Your Own Docker Image

If you already have a Docker image (in Docker Hub, ACR, or another registry), you can use it with the preload feature:

#### Option 1: Use Existing Image from Azure Container Registry

```bash
# Configure to use your existing ACR and image
CREATE_ACR=false                    # Don't create new ACR
BUILD_DOCKER_IMAGE=false            # Don't build new image
PRELOAD_IMAGES=true                 # Enable preloading
CONTAINER_IMAGE="myacr.azurecr.io/myapp:v1.0"  # Your image

# Run the script
./batch-prep.sh
```

The script will:
1. Pull your image onto the VM during image creation
2. Configure the Batch pool with container support
3. Make the image available on all pool nodes

#### Option 2: Use Image from Docker Hub

```bash
# Configure to use public Docker Hub image
CREATE_ACR=false
BUILD_DOCKER_IMAGE=false
PRELOAD_IMAGES=true
CONTAINER_IMAGE="pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime"

./batch-prep.sh
```

#### Option 3: Use Image from Private Registry

If using a private registry, you'll need to handle authentication:

```bash
# Set your image
CONTAINER_IMAGE="myregistry.io/myapp:latest"
PRELOAD_IMAGES=true

# Modify the preload_docker_images() function to include:
# docker login myregistry.io -u USERNAME -p PASSWORD
```

#### Important Notes:

- **Image Requirements**: Your image should be compatible with the base OS (Ubuntu or AlmaLinux)
- **GPU Images**: For GPU workloads, ensure your image has CUDA libraries matching your drivers
- **Size Considerations**: Large images (>5GB) will take longer to preload but save time across all pool nodes
- **Registry Access**: Ensure the VM can access your registry (check firewall/network rules)

#### Without Preloading

If you don't want to preload the image (pull on-demand per task):

```bash
CREATE_ACR=false
BUILD_DOCKER_IMAGE=false
PRELOAD_IMAGES=false
CONTAINER_IMAGE="myregistry.azurecr.io/myapp:latest"

./batch-prep.sh
```

Tasks will pull the image when first needed. This uses less VM image storage but increases task startup time.

### Testing and Verification

After creating your Batch pool, you can automatically verify its configuration using the `--verify` flag:

```bash
# Create pool and run verification
./batch-prep.sh --verify
```

The verification job will:
1. Create a test job on the newly created pool
2. Submit a task that checks:
   - System information (OS, kernel version)
   - Docker installation and version
   - GPU availability (if `ENABLE_GPU=true`)
   - Preloaded Docker images (if `PRELOAD_IMAGES=true`)
   - Docker container execution
3. Display the task output and exit code
4. Provide commands to view full task details

**Example verification output for a GPU pool with preloaded images:**
```
=== System Info ===
Linux batch-node 5.15.0-1052-azure #60-Ubuntu SMP x86_64 GNU/Linux

=== Docker Info ===
Docker version 24.0.7, build afdd53b

=== Docker Images ===
REPOSITORY                              TAG       IMAGE ID       SIZE
myacr.azurecr.io/batch-gpu-pytorch     latest    abc123def456   5.2GB

=== GPU Info ===
Tesla T4, Driver Version: 525.125.06, CUDA Version: 12.0

✓ Image preloaded successfully
✓ Docker container executed successfully
```

**Manual verification:**
You can also manually check your pool without the `--verify` flag:

```bash
# Create a test job
az batch job create --id test-job --pool-id myBatchPool --account-name mybatchaccount

# Create a test task
az batch task create \
  --job-id test-job \
  --task-id test-1 \
  --command-line "/bin/bash -c 'nvidia-smi; docker images'" \
  --account-name mybatchaccount
```

### Reusing Existing Images

If you've already created a Shared Image Gallery image, you can skip the VM creation steps and directly create the Batch pool:

```bash
# Manually set IMAGE_ID to your existing image
IMAGE_ID="/subscriptions/YOUR_SUB/resourceGroups/YOUR_RG/providers/Microsoft.Compute/galleries/YOUR_GALLERY/images/YOUR_IMAGE/versions/1.0.0"

# Then run only the Batch account and pool creation commands
```

## License

This script is provided as-is without warranty. Use at your own risk.

## Support

For Azure-specific issues, consult the [Azure Batch documentation](https://docs.microsoft.com/azure/batch/) or [Azure CLI documentation](https://docs.microsoft.com/cli/azure/).

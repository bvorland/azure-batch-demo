# PRELOAD_IMAGES Feature Summary

## What Was Added

### 1. New Functions

#### setup_container_registry()
- Creates Azure Container Registry (ACR) when CREATE_ACR=true
- Builds Docker image using az acr build when BUILD_DOCKER_IMAGE=true
- Pushes image to ACR
- Updates CONTAINER_IMAGE variable with ACR image URL

#### preload_docker_images()
- Pulls Docker images onto VM before generalization when PRELOAD_IMAGES=true
- Logs into ACR using admin credentials
- Pulls the container image so it's cached on the VM image

### 2. Container Configuration Support

The pool JSON now conditionally adds containerConfiguration when PRELOAD_IMAGES=true:

```json
"containerConfiguration": {
  "type": "dockerCompatible",
  "containerImageNames": ["<ACR_IMAGE_URL>"]
}
```

### 3. Workflow Integration

Functions are called in the image creation workflow:
1. After Docker is installed on the VM
2. Before the VM is deallocated and generalized

## Configuration Variables

- **CREATE_ACR** (default: false) - Create Azure Container Registry
- **BUILD_DOCKER_IMAGE** (default: false) - Build and push Docker image to ACR
- **PRELOAD_IMAGES** (default: false) - Preload Docker image on VM before generalization
- **ACR_NAME** - Name for the ACR (auto-generated)
- **DOCKER_IMAGE_NAME** - Docker image name (default: "batch-gpu-pytorch")
- **DOCKER_IMAGE_TAG** - Docker image tag (default: "latest")

## How to Use

### Example 1: Create image with preloaded Docker container

```bash
CREATE_ACR=true \
BUILD_DOCKER_IMAGE=true \
PRELOAD_IMAGES=true \
ENABLE_GPU=true \
./batch-prep-v2.sh --image-only
```

This will:
1. Create an ACR
2. Build the Docker image from Dockerfile.gpu.ubuntu (or almalinux)
3. Push the image to ACR
4. Pull the image onto the VM
5. Create the custom VM image with Docker image cached

### Example 2: Create Batch pool that uses preloaded images

After creating the image with PRELOAD_IMAGES=true, create a pool:

```bash
PRELOAD_IMAGES=true \
./batch-prep-v2.sh --batch-only
```

The pool will be configured with containerConfiguration, making the preloaded image available to tasks.

## Benefits

- Faster task startup (no need to pull large images from ACR on each node)
- Reduced network costs (images pulled once during image creation)
- Better for GPU workloads with large ML/AI images
- Consistent image across all pool nodes

## Files Modified

- **batch-prep-v2.sh** - Added Docker/ACR functions and container configuration support

## Testing

The script has been syntax-validated and all features verified:
- ✓ PRELOAD_IMAGES variable
- ✓ setup_container_registry() function
- ✓ preload_docker_images() function  
- ✓ containerConfiguration support in pool JSON
- ✓ Functions integrated into workflow
- ✓ Script syntax valid

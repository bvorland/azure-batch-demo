# Script Updates and Fixes Summary

## Issues Fixed

### 1. Shared Image Gallery Requirement
**Problem**: Azure Batch requires Shared Image Gallery images, not direct managed images.

**Fix**: 
- Added complete Shared Image Gallery creation workflow
- Creates gallery, image definition, and image version
- Properly handles Gen1/Gen2 hypervisor generation matching

### 2. Docker Installation Persistence
**Problem**: Docker installed during VM setup doesn't persist through generalization.

**Fix**:
- Removed Docker installation from VM preparation phase
- Moved Docker installation to Batch pool start task
- Docker now installs fresh on each pool node via start task

### 3. GPU/CPU Dynamic Configuration
**Problem**: Script was hardcoded for specific workload type.

**Fix**:
- Added `ENABLE_GPU` toggle (true/false)
- Auto-selects VM size based on GPU setting
- Conditionally installs NVIDIA drivers only when GPU enabled
- Conditionally installs NVIDIA container toolkit in start task
- Auto-selects appropriate container images

### 4. Start Task Configuration
**Problem**: Start task didn't properly install required software.

**Fix**:
- Created comprehensive start task script
- Installs Docker (Moby) on node startup
- Installs NVIDIA container toolkit if GPU enabled
- Waits for GPU to be available before completing
- Verifies installation with nvidia-smi and docker --version

### 5. NVIDIA Driver Extension Version
**Problem**: Used outdated driver extension version.

**Fix**:
- Updated from version 1.4 to 1.10
- Added proper timeout and status checking for driver installation
- Improved error handling for failed installations

### 6. Image Generation Compatibility
**Problem**: Mismatch between VM Gen2 and image expectations.

**Fix**:
- Switched to Gen1 images for maximum compatibility
- Updated VM_IMAGE_URN to use gen1 suffix
- Set HYPERV_GENERATION="V1" explicitly
- Documented how to use Gen2 if needed

## New Features

### Dynamic GPU/CPU Support
Users can now easily switch between GPU and CPU workloads by changing one variable:

```bash
# GPU workload
ENABLE_GPU=true

# CPU workload  
ENABLE_GPU=false
```

### Flexible VM Sizing
Separate configuration for GPU and CPU VM sizes:

```bash
GPU_VM_SIZE="Standard_NC4as_T4_v3"  # T4 GPU
CPU_VM_SIZE="Standard_D4s_v3"        # CPU only
```

### Improved Error Handling
- Better timeout handling for GPU driver installation
- Proper status checking at each step
- More descriptive error messages

### Better Documentation
- Clear GPU vs CPU configuration examples
- Quota checking instructions
- Troubleshooting section with common issues
- Advanced usage scenarios

## Configuration Changes

### Before (Old Config):
```bash
VM_SIZE="Standard_NC4as_T4_v3"
CONTAINER_IMAGE="myacr.azurecr.io/mygpuimage:latest"
CUSTOM_IMAGE_NAME="myCustomGpuImage"
```

### After (New Config):
```bash
ENABLE_GPU=true
GPU_VM_SIZE="Standard_NC4as_T4_v3"
CPU_VM_SIZE="Standard_D4s_v3"
GALLERY_NAME="batchImageGallery"
IMAGE_DEFINITION_NAME="batchCustomImage"
IMAGE_VERSION="1.0.0"
HYPERV_GENERATION="V1"
```

## Workflow Changes

### Old Workflow:
1. Create VM
2. Install GPU drivers (extension)
3. Install Docker via run-command
4. Generalize VM
5. Create managed image
6. Create Batch pool
7. Configure start task (simple validation)

### New Workflow:
1. Create VM
2. Install GPU drivers (extension) - if GPU enabled
3. Skip Docker installation
4. Generalize VM
5. Create Shared Image Gallery + definition + version
6. Create Batch pool with start task that:
   - Installs Docker
   - Installs NVIDIA container toolkit (if GPU)
   - Waits for GPU availability (if GPU)
   - Validates installation

## Testing Recommendations

### For GPU Workloads:
1. Ensure you have GPU quota in target region
2. Test with smallest GPU VM first (NC4as_T4_v3)
3. Verify nvidia-smi works on pool nodes
4. Test Docker GPU access: `docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi`

### For CPU Workloads:
1. Set ENABLE_GPU=false
2. Use smaller CPU VMs for testing
3. Verify Docker works: `docker run --rm ubuntu:22.04 echo "Hello"`

## Migration Guide

If you have an existing deployment using the old script:

1. Update your config variables to new names
2. Set ENABLE_GPU based on your workload
3. Expect Shared Image Gallery resources to be created
4. Plan for longer initial pool startup (Docker installation in start task)
5. Clean up old managed images if no longer needed

## Known Limitations

1. Start task adds 2-5 minutes to first node startup
2. Each node installs Docker fresh (no image pre-baking)
3. Gen1 images only by default (Gen2 requires config change)
4. Single region deployment (multi-region requires script modification)

## Files Changed

- `batch-prep.sh` - Complete rewrite of image and pool creation logic
- `README.md` - Updated documentation with GPU/CPU examples and troubleshooting

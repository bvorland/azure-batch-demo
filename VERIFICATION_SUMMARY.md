# Test PRELOAD_IMAGES Feature

## Changes Made

### 1. Script Updates (batch-prep-v2.sh)

**New Functions Added:**
- `setup_container_registry()` - Lines ~418-464
  - Creates ACR when CREATE_ACR=true
  - Builds Docker image when BUILD_DOCKER_IMAGE=true
  - Pushes image to ACR using az acr build
  - Updates CONTAINER_IMAGE variable

- `preload_docker_images()` - Lines ~467-490
  - Pulls Docker image onto VM when PRELOAD_IMAGES=true
  - Authenticates with ACR using admin credentials
  - Caches image on VM before generalization

**Workflow Integration:**
- Functions called at lines 604 and 607
- Called after Docker installation, before VM generalization
- Ensures images are cached in the custom VM image

**Pool Configuration:**
- Added containerConfiguration support (lines 673-682)
- Conditionally adds container config when PRELOAD_IMAGES=true
- Includes dockerCompatible type and containerImageNames array

### 2. Documentation Updates

**README.md:**
- Fixed default values for CREATE_ACR, BUILD_DOCKER_IMAGE, PRELOAD_IMAGES
- Changed from `true` to `false` to match actual script defaults
- Documentation already comprehensive for these features

**PRELOAD_IMAGES_FEATURE.md:**
- New file documenting the complete feature
- Usage examples for both image-only and full workflows
- Benefits and configuration details

## Verification Results

✓ All configuration variables defined correctly
✓ Both functions defined and implemented
✓ Functions integrated into workflow at correct points
✓ Container configuration support added to pool JSON
✓ Script syntax valid (bash -n passed)
✓ Documentation updated with correct defaults

## How to Test

### Test 1: Image-only with Docker preload
```bash
CREATE_ACR=true \
BUILD_DOCKER_IMAGE=true \
PRELOAD_IMAGES=true \
ENABLE_GPU=true \
BASE_OS=ubuntu \
./batch-prep-v2.sh --image-only
```

This will:
1. Create resource group and VM
2. Install GPU drivers
3. Install Docker
4. Create ACR
5. Build Docker image from Dockerfile.gpu.ubuntu
6. Push image to ACR
7. Pull image onto VM
8. Generalize VM
9. Create custom image with cached Docker image

### Test 2: Batch pool with preloaded image
```bash
PRELOAD_IMAGES=true \
./batch-prep-v2.sh --batch-only
```

This will:
1. Create Batch account
2. Create pool with containerConfiguration
3. Pool nodes will have Docker image already cached

## Files Modified
- batch-prep-v2.sh (+96 lines)
- README.md (fixed 3 default values)
- PRELOAD_IMAGES_FEATURE.md (new file, 104 lines)

## Git Commits
1. Commit bc25d0b: Documentation updates
2. Commit 102c942: Script implementation

All changes pushed to origin/main successfully.

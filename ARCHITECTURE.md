# Execution Mode Architecture

## Current Monolithic Flow
```
┌─────────────────────────────────────────────────────────────┐
│                    batch-prep.sh                            │
│  (Always runs everything: ~25-30 minutes)                   │
├─────────────────────────────────────────────────────────────┤
│  1. Validate Prerequisites                                  │
│  2. Create Resource Group                                   │
│  3. Create VM                                               │
│  4. Install NVIDIA Drivers (if GPU)                         │
│  5. Install Docker                                          │
│  6. Create ACR (optional)                                   │
│  7. Build & Push Docker Image (optional)                    │
│  8. Preload Images (optional)                               │
│  9. Deallocate & Generalize VM                              │
│ 10. Create Shared Image Gallery                             │
│ 11. Create Image Definition                                 │
│ 12. Create Managed Image                                    │
│ 13. Create Image Version                                    │
│ 14. Create Batch Account                                    │
│ 15. Create Batch Pool                                       │
│ 16. Cleanup                                                 │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
    All Resources Created
    (Image + Batch Infrastructure)
```

## New Modular Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           batch-prep.sh                                     │
│                      (Command-line Arguments)                               │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                ┌───────────────────┼───────────────────┐
                │                   │                   │
                ▼                   ▼                   ▼
        ┌──────────────┐    ┌──────────────┐   ┌──────────────┐
        │ --image-only │    │ --batch-only │   │    --full    │
        │  (~20-25 min)│    │  (~5-10 min) │   │  (~25-30 min)│
        └──────────────┘    └──────────────┘   └──────────────┘
                │                   │                   │
                │                   │                   └──────┐
                ▼                   ▼                          │
    ┌─────────────────────┐  ┌──────────────────┐            │
    │  IMAGE CREATION     │  │ BATCH CREATION   │            │
    │  WORKFLOW           │  │ WORKFLOW         │            │
    ├─────────────────────┤  ├──────────────────┤            │
    │ 1. Validate         │  │ 1. Validate      │◄───────────┤
    │ 2. Create VM        │  │ 2. Load Image    │            │
    │ 3. Install Drivers  │  │    Metadata      │            │
    │ 4. Install Docker   │  │ 3. Create Batch  │            │
    │ 5. Setup ACR        │  │    Account       │            │
    │ 6. Build Images     │  │ 4. Generate Pool │            │
    │ 7. Generalize VM    │  │    Config        │            │
    │ 8. Create Gallery   │  │ 5. Create Pool   │            │
    │ 9. Create Version   │  │ 6. Validate      │            │
    │ 10. Save Metadata   │  │ 7. Save Metadata │            │
    └─────────────────────┘  └──────────────────┘            │
                │                   │                          │
                ▼                   ▼                          │
    ┌─────────────────────┐  ┌──────────────────┐            │
    │ image_metadata.json │  │batch_metadata.json│           │
    │                     │  │                   │            │
    │ - Image ID          │  │ - Batch Account  │            │
    │ - Gallery Name      │  │ - Pool ID        │            │
    │ - Version           │  │ - VM Size        │            │
    │ - Node Agent SKU    │  │ - Node Count     │            │
    │ - Location          │  │ - State          │            │
    │ - Base OS           │  │ - Image ID       │            │
    │ - GPU Enabled       │  └──────────────────┘            │
    └─────────────────────┘                                   │
                │                                              │
                └──────────────────────────────────────────────┘
                                    │
                                    ▼
                          All Resources Created
```

## Usage Patterns

### Pattern 1: One Image, Multiple Pools (RECOMMENDED)

```
┌─────────────────────────────────────────────────────────────┐
│ STEP 1: Create Base Image (DevOps/Platform Team)           │
└─────────────────────────────────────────────────────────────┘
    ./batch-prep.sh --image-only --gpu --os ubuntu --version 22.04
                            │
                            ▼
                ┌───────────────────────┐
                │ Shared Image Gallery  │
                │   batchCustomImage    │
                │     version 1.0.0     │
                └───────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
        ▼                   ▼                   ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ STEP 2a:     │    │ STEP 2b:     │    │ STEP 2c:     │
│ Dev Pool     │    │ Test Pool    │    │ Prod Pool    │
└──────────────┘    └──────────────┘    └──────────────┘
./batch-prep.sh     ./batch-prep.sh     ./batch-prep.sh
--batch-only        --batch-only        --batch-only
--pool-id dev       --pool-id test      --pool-id prod
--vm-size NC6       --vm-size NC6       --vm-size NC12
--nodes 1           --nodes 2           --nodes 10

  (5 min)              (5 min)             (5 min)
```

**Benefit**: Create image once (25 min), then create pools quickly (5 min each)

### Pattern 2: Different OS/GPU Configurations

```
┌────────────────────┐       ┌────────────────────┐
│  Ubuntu GPU Image  │       │  AlmaLinux CPU     │
│                    │       │  Image             │
├────────────────────┤       ├────────────────────┤
│ ./batch-prep.sh    │       │ ./batch-prep.sh    │
│ --image-only       │       │ --image-only       │
│ --gpu              │       │ --cpu              │
│ --os ubuntu        │       │ --os almalinux     │
└────────────────────┘       └────────────────────┘
         │                             │
         ▼                             ▼
    ┌─────────┐                   ┌─────────┐
    │ GPU     │                   │ CPU     │
    │ Pools   │                   │ Pools   │
    └─────────┘                   └─────────┘
```

### Pattern 3: CI/CD Pipeline Integration

```
┌───────────────────────────────────────────────────────────────┐
│                    CI/CD Pipeline                             │
└───────────────────────────────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │                               │
        ▼                               ▼
┌──────────────────┐           ┌──────────────────┐
│  Image Pipeline  │           │  Deploy Pipeline │
│  (Weekly/Manual) │           │  (On Demand)     │
├──────────────────┤           ├──────────────────┤
│ 1. Build Image   │           │ 1. Get Latest    │
│    --image-only  │           │    Image         │
│                  │           │ 2. Create Pool   │
│ 2. Test Image    │           │    --batch-only  │
│                  │           │                  │
│ 3. Tag Version   │           │ 3. Deploy Jobs   │
│    (e.g., 1.0.1) │           │                  │
└──────────────────┘           └──────────────────┘
```

### Pattern 4: Rapid Testing Cycle

```
Development Workflow:
┌──────────────────────────────────────────────────────────────┐
│ DAY 1: Create Image                                          │
│   ./batch-prep.sh --image-only --gpu                         │
│   Time: 25 minutes                                           │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ DAYS 2-N: Rapid Pool Iterations                             │
│                                                               │
│  Test 1: ./batch-prep.sh --batch-only --vm-size NC6         │
│          (5 min) → Test → Delete Pool                        │
│                                                               │
│  Test 2: ./batch-prep.sh --batch-only --vm-size NC12        │
│          (5 min) → Test → Delete Pool                        │
│                                                               │
│  Test 3: ./batch-prep.sh --batch-only --nodes 5             │
│          (5 min) → Test → Delete Pool                        │
└──────────────────────────────────────────────────────────────┘

Traditional approach: 25 min × 3 tests = 75 minutes
New approach: 25 min + (5 min × 3) = 40 minutes
Time saved: 35 minutes (47% faster)
```

## Comparison Table

| Scenario | Current Method | New Method (image-only + batch-only) | Time Saved |
|----------|----------------|--------------------------------------|------------|
| Single deployment | 25 min | 25 min (same) | 0 min |
| Create 3 pools (different sizes) | 75 min (3×25) | 40 min (25 + 3×5) | 35 min |
| Create 5 pools | 125 min | 50 min (25 + 5×5) | 75 min |
| Iterate pool config 10 times | 250 min | 75 min (25 + 10×5) | 175 min |
| Update 1 pool config | 25 min (rebuild all) | 5 min (pool only) | 20 min |

## Function Call Flow

### --image-only Mode
```
main()
  ├─ parse_arguments()
  ├─ validate_prerequisites()
  ├─ validate_resources()
  ├─ create_resource_group()
  ├─ create_base_vm()
  ├─ configure_vm_drivers()
  ├─ configure_vm_docker()
  ├─ configure_vm_acr()
  ├─ generalize_vm()
  ├─ create_image_gallery()
  ├─ create_image_version()
  ├─ save_image_metadata()
  ├─ cleanup_resources("image-only")
  └─ print_summary("image-only")
```

### --batch-only Mode
```
main()
  ├─ parse_arguments()
  ├─ validate_prerequisites()
  ├─ validate_resources()
  ├─ validate_image_exists()
  ├─ load_image_metadata()
  ├─ create_resource_group()
  ├─ create_batch_account()
  ├─ generate_pool_config()
  ├─ create_batch_pool()
  ├─ save_batch_metadata()
  ├─ cleanup_resources("batch-only")
  └─ print_summary("batch-only")
```

### --full Mode (Default)
```
main()
  ├─ parse_arguments()
  ├─ validate_prerequisites()
  ├─ validate_resources()
  │
  ├─ [IMAGE CREATION WORKFLOW]
  │   ├─ create_resource_group()
  │   ├─ create_base_vm()
  │   ├─ configure_vm_drivers()
  │   ├─ configure_vm_docker()
  │   ├─ configure_vm_acr()
  │   ├─ generalize_vm()
  │   ├─ create_image_gallery()
  │   ├─ create_image_version()
  │   └─ save_image_metadata()
  │
  ├─ [BATCH CREATION WORKFLOW]
  │   ├─ create_batch_account()
  │   ├─ generate_pool_config()
  │   ├─ create_batch_pool()
  │   ├─ create_verification_job()  # Optional: if --verify flag used
  │   └─ save_batch_metadata()
  │
  ├─ cleanup_resources("full")
  └─ print_summary("full")
```

## New Features

### 1. Verification Job (--verify flag)
Creates a test job after pool creation to validate:
- System configuration
- Docker installation
- GPU availability (if enabled)
- Preloaded images (if PRELOAD_IMAGES=true)
- Container execution

### 2. Enhanced PRELOAD_IMAGES
Now supports custom Docker images from:
- Azure Container Registry (with auto-authentication)
- Docker Hub (public images)
- Any registry (with CONTAINER_IMAGE variable)

**Configuration:**
```bash
CONTAINER_IMAGE="myacr.azurecr.io/myapp:v1.0"
PRELOAD_IMAGES=true
./batch-prep.sh
```

## Metadata Files Enable Reuse

### image_metadata.json (Created by --image-only)
```json
{
  "imageId": "/subscriptions/.../versions/1.0.0",
  "nodeAgentSku": "batch.node.ubuntu 22.04",
  "galleryName": "batchImageGallery",
  "imageName": "batchCustomImage",
  "version": "1.0.0",
  "vmSize": "Standard_NC4as_T4_v3",
  "location": "swedencentral"
}
```
**Used by**: --batch-only mode to reference the image

### batch_metadata.json (Created by --batch-only)
```json
{
  "batchAccount": "mybatch12345",
  "poolId": "myBatchPool",
  "imageId": "/subscriptions/.../versions/1.0.0",
  "vmSize": "Standard_D2s_v3",
  "nodes": 1
}
```
**Used by**: Application code to submit jobs

## Error Handling

### --image-only Mode Errors
- VM creation fails → Clean up resource group
- Driver installation fails → Keep VM for debugging (if --keep-vm)
- Image creation fails → Clean up VM, keep logs

### --batch-only Mode Errors
- Image not found → Error with helpful message + list available images
- Pool already exists → Option to update or fail
- Quota exceeded → Show quota info + suggest smaller VM size

---

## Summary

The refactored architecture provides:

1. **Flexibility**: Choose what to create (image, pool, or both)
2. **Efficiency**: Avoid redundant operations
3. **Reusability**: One image, many pools
4. **Speed**: Faster iterations during development
5. **Cost**: Lower Azure costs through efficiency
6. **Maintainability**: Modular, testable code
7. **Team Workflow**: Separation of concerns between teams
8. **CI/CD Ready**: Easy pipeline integration

Ready to implement! 🚀

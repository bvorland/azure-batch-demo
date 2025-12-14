# Docker Image for Azure Batch GPU Workloads

This directory contains Docker configurations for building GPU-enabled containers with PyTorch, computer vision libraries, and pre-loaded AI models for Azure Batch.

**Multi-OS Support**: Ubuntu and AlmaLinux base images available.

## Image Contents

### Base Image
- **NVIDIA CUDA**: 12.1.0 with cuDNN 8 on Ubuntu 22.04
- Optimized for GPU compute workloads

### Python & Core Libraries
- **Python**: 3.10
- **PyTorch**: 2.1.2 with CUDA 12.1 support
- **TorchVision**: 0.16.2
- **TorchAudio**: 2.1.2

### Computer Vision & ML Libraries
- **OpenCV**: 4.9.0 (opencv-python)
- **OpenSlide**: 1.3.1 with tools (for whole slide imaging)
- **FAISS**: 1.7.4 (CPU version for similarity search)
- **Pillow**: 10.1.0
- **NumPy**: 1.26.3
- **SciPy**: 1.11.4

### Hugging Face Ecosystem
- **Transformers**: 4.36.2
- **Accelerate**: 0.25.0
- **Timm**: 0.9.12 (PyTorch Image Models)
- **Hugging Face Hub**: 0.20.2

### Pre-loaded Models
The following models are downloaded and cached in the image to reduce startup time:
- **facebook/dino-vits8**: Vision Transformer (ViT-S/8) trained with DINO
- **facebook/dino-vits16**: Vision Transformer (ViT-S/16) trained with DINO

Models are stored in `/app/models` directory.

## Files

- **Dockerfile**: Basic GPU image (legacy, simpler version)
- **Dockerfile.gpu**: Legacy single-OS version
- **Dockerfile.gpu.ubuntu**: Production Ubuntu image with pre-loaded models
- **Dockerfile.gpu.almalinux**: Production AlmaLinux image with pre-loaded models
- **build-and-push-docker.sh**: Helper script to build and push to ACR

## OS-Specific Considerations

### Ubuntu 22.04
- **Python**: 3.10
- **Package Manager**: apt-get
- **Docker**: docker.io
- **OpenSlide**: ✓ Available via apt
- **Best for**: Maximum compatibility, easier dependency installation

### AlmaLinux 8/9
- **Python**: 3.11
- **Package Manager**: dnf
- **Docker**: docker-ce
- **OpenSlide**: ✗ Not easily available (must build from source)
- **Best for**: Enterprise environments, RHEL compatibility

## Building Locally

### Prerequisites
- Docker installed with GPU support (NVIDIA Docker)
- Azure CLI installed and logged in
- Access to an Azure Container Registry

### Quick Build
```bash
# Build the image
docker build -f Dockerfile.gpu -t batch-gpu-pytorch:latest .

# Test the image locally (requires NVIDIA GPU)
docker run --rm --gpus all batch-gpu-pytorch:latest python3 -c "import torch; print(f'CUDA Available: {torch.cuda.is_available()}')"
```

### Build and Push to ACR
```bash
# Make the helper script executable
chmod +x build-and-push-docker.sh

# Build and push to your ACR
./build-and-push-docker.sh <your-acr-name> latest
```

Or manually:
```bash
ACR_NAME="myacr"
IMAGE_NAME="batch-gpu-pytorch"
TAG="latest"

# Build
docker build -f Dockerfile.gpu -t ${IMAGE_NAME}:${TAG} .

# Tag for ACR
docker tag ${IMAGE_NAME}:${TAG} ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${TAG}

# Login to ACR
az acr login --name ${ACR_NAME}

# Push
docker push ${ACR_NAME}.azurecr.io/${IMAGE_NAME}:${TAG}
```

## Using with Azure Batch

### Automated Setup (Recommended)
The `batch-prep.sh` script can automatically:
1. Create an Azure Container Registry
2. Build and push this Docker image
3. Preload the image on the Batch node pool
4. Configure pool to use the image

Simply set these variables in `batch-prep.sh`:
```bash
CREATE_ACR=true
BUILD_DOCKER_IMAGE=true
PRELOAD_IMAGES=true
ENABLE_GPU=true
```

### Manual Setup
If you've already built and pushed the image:

1. Update `batch-prep.sh`:
```bash
CREATE_ACR=false
BUILD_DOCKER_IMAGE=false
CONTAINER_IMAGE="myacr.azurecr.io/batch-gpu-pytorch:latest"
```

2. Run the batch script:
```bash
./batch-prep.sh
```

## Testing the Image

### Verify CUDA
```bash
docker run --rm --gpus all <image-name> python3 << 'EOF'
import torch
print(f"PyTorch version: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")
print(f"CUDA version: {torch.version.cuda}")
if torch.cuda.is_available():
    print(f"GPU device: {torch.cuda.get_device_name(0)}")
EOF
```

### Verify Libraries
```bash
docker run --rm <image-name> python3 << 'EOF'
import cv2
import openslide
import faiss
from transformers import AutoModel
import torch

print(f"✓ OpenCV: {cv2.__version__}")
print(f"✓ OpenSlide: OK")
print(f"✓ FAISS: {faiss.__version__}")
print(f"✓ Transformers: OK")
print(f"✓ PyTorch: {torch.__version__}")
EOF
```

### Verify Pre-loaded Models
```bash
docker run --rm <image-name> python3 << 'EOF'
from transformers import AutoModel
import os

models_dir = "/app/models"
print(f"Models directory: {models_dir}")
print(f"Directory exists: {os.path.exists(models_dir)}")

# Check cached models
for root, dirs, files in os.walk(models_dir):
    if 'dino' in root.lower():
        print(f"Found: {root}")

print("\nLoading models from cache...")
model_s8 = AutoModel.from_pretrained('facebook/dino-vits8')
model_s16 = AutoModel.from_pretrained('facebook/dino-vits16')
print("✓ Both models loaded successfully from cache!")
EOF
```

### Run Interactive Shell
```bash
docker run --rm -it --gpus all <image-name> /bin/bash
```

## Image Size and Build Time

- **Image Size**: ~8-10 GB (due to CUDA, PyTorch, and pre-loaded models)
- **Build Time**: 15-30 minutes (depending on network speed and hardware)
  - Model downloads: 5-10 minutes
  - PyTorch installation: 5-10 minutes
  - Other dependencies: 5-10 minutes

## Optimization Tips

### Reduce Image Size
1. Use multi-stage builds
2. Clean up apt cache
3. Use `.dockerignore` file

### Speed Up Builds
1. Use Docker BuildKit: `DOCKER_BUILDKIT=1 docker build ...`
2. Cache model downloads separately
3. Use `--cache-from` flag for incremental builds

### Production Recommendations
1. **Pin all versions** (already done in Dockerfile.gpu)
2. **Use specific CUDA version** matching your GPU architecture
3. **Enable Docker BuildKit** for better caching
4. **Tag with semantic versions** not just `latest`
5. **Scan for vulnerabilities**: `az acr task run` or `docker scan`

## Troubleshooting

### CUDA Version Mismatch
Ensure the CUDA version in the Docker image matches your GPU driver capabilities:
```bash
nvidia-smi  # Check driver CUDA version
```

### Out of Memory During Build
Increase Docker's memory limit in Docker Desktop settings or add swap space on Linux.

### Slow Model Downloads
Models are downloaded from Hugging Face Hub. If slow:
1. Use a mirror or cache
2. Pre-download models and COPY them into the image
3. Download models at runtime instead of build time

### Permission Errors
The image runs as non-root user `appuser` (UID 1000). Ensure mounted volumes have appropriate permissions:
```bash
chown -R 1000:1000 /path/to/data
```

## Customization

### Add Your Own Models
Edit `Dockerfile.gpu` and add to the model download section:
```dockerfile
RUN python3 -c "from transformers import AutoModel; \
    AutoModel.from_pretrained('your-org/your-model')"
```

### Add Additional Libraries
```dockerfile
RUN pip3 install --no-cache-dir \
    your-library==version
```

### Change Python Version
Update the base image and install commands:
```dockerfile
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04
RUN apt-get install -y python3.11 python3.11-pip
```

## Security

- Image runs as non-root user (`appuser`)
- No secrets or credentials baked into image
- Use Azure Key Vault or Batch secrets for runtime credentials
- Regularly update base image and dependencies
- Scan image for vulnerabilities before production use

## Support

For issues or questions:
1. Check Azure Batch documentation
2. Review Docker and NVIDIA Docker documentation
3. Check Hugging Face model card for model-specific issues

## License

This Dockerfile configuration is provided as-is for use with Azure Batch. Please review and comply with licenses for:
- NVIDIA CUDA
- PyTorch
- Hugging Face models and libraries
- All other included libraries

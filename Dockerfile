# Use NVIDIA CUDA base image with Ubuntu 22.04
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV TORCH_CUDA_ARCH_LIST="7.0 7.5 8.0 8.6 8.9 9.0+PTX"

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    python3-dev \
    git \
    wget \
    openslide-tools \
    libopenslide-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip and install setuptools
RUN pip3 install --upgrade pip setuptools wheel

# Install PyTorch with CUDA support
RUN pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# Install Python libraries
RUN pip3 install \
    faiss-cpu \
    opencv-python \
    openslide-python \
    transformers \
    accelerate \
    timm \
    pillow \
    numpy \
    scipy

# Create cache directory for Hugging Face models
ENV HF_HOME=/app/models
RUN mkdir -p /app/models

# Pre-download Hugging Face models
RUN python3 -c "from transformers import AutoModel, AutoImageProcessor; \
    AutoModel.from_pretrained('facebook/dino-vits8'); \
    AutoImageProcessor.from_pretrained('facebook/dino-vits8'); \
    AutoModel.from_pretrained('facebook/dino-vits16'); \
    AutoImageProcessor.from_pretrained('facebook/dino-vits16')"

# Set working directory
WORKDIR /app

# Create a non-root user
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Default command
CMD ["/bin/bash"]

# Multi-OS Support Guide

Azure Batch Demo supports both Ubuntu and AlmaLinux base operating systems for maximum flexibility.

## Supported Operating Systems

### Ubuntu 22.04 LTS (Default)
- **Recommended for**: Most use cases, maximum software compatibility
- **Python Version**: 3.10
- **Package Manager**: apt-get / dpkg
- **Docker**: docker.io
- **NVIDIA Support**: Excellent
- **Benefits**:
  - Largest software ecosystem
  - Best documentation and community support
  - All libraries available (OpenCV, OpenSlide, FAISS)
  - Easiest dependency installation

### AlmaLinux 8/9
- **Recommended for**: Enterprise environments, RHEL compatibility requirements
- **Python Version**: 3.11
- **Package Manager**: dnf / yum
- **Docker**: docker-ce
- **NVIDIA Support**: Good
- **Benefits**:
  - RHEL-compatible
  - Long-term enterprise support
  - Strong security focus
- **Limitations**:
  - OpenSlide not readily available (requires building from source)
  - Smaller ML/AI package ecosystem

## Configuration

Set these variables in `batch-prep.sh`:

```bash
BASE_OS="ubuntu"        # or "almalinux"
OS_VERSION="22.04"      # Ubuntu: "22.04", "20.04" | AlmaLinux: "8", "9"
```

The script automatically configures:
- VM image URN
- Batch node agent SKU  
- Dockerfile selection
- Package management commands

## Feature Comparison

| Feature | Ubuntu 22.04 | AlmaLinux 8/9 |
|---------|-------------|---------------|
| Python | 3.10 | 3.11 |
| PyTorch | ✓ Full support | ✓ Full support |
| OpenCV | ✓ Full support | ✓ Full support |
| FAISS | ✓ Full support | ✓ Full support |
| OpenSlide | ✓ Via apt | ✗ Manual build required |
| Transformers | ✓ Full support | ✓ Full support |
| NVIDIA CUDA | ✓ 12.1.0 | ✓ 12.1.0 |
| Docker Build Time | ~15-20 min | ~15-20 min |
| Image Size | ~8-10 GB | ~8-10 GB |
| Enterprise Support | Community | Enterprise (RHEL-compatible) |

## Docker Images

### Ubuntu: Dockerfile.gpu.ubuntu
```dockerfile
FROM nvidia/cuda:12.1.0-cudnn8-runtime-ubuntu22.04

# Uses apt-get for packages
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    openslide-tools \
    ...
```

### AlmaLinux: Dockerfile.gpu.almalinux
```dockerfile
FROM nvidia/cuda:12.1.0-cudnn8-runtime-rockylinux8

# Uses dnf for packages
RUN dnf install -y epel-release && \
    dnf install -y \
    python3.11 \
    python3.11-pip \
    ...
```

## Choosing the Right OS

### Choose Ubuntu if:
- You need OpenSlide for whole slide imaging
- You want the easiest setup and best compatibility
- You're new to Azure Batch or ML workloads
- You need the largest selection of pre-built packages
- You prioritize community support and documentation

### Choose AlmaLinux if:
- You require RHEL compatibility
- Your organization has enterprise Linux standards
- You don't need OpenSlide
- You need long-term support for production deployments
- You have existing AlmaLinux infrastructure

## Migration Between OS

To switch from one OS to another:

1. Update configuration:
```bash
# Change from Ubuntu to AlmaLinux
BASE_OS="almalinux"
OS_VERSION="8"
```

2. The script will automatically:
   - Use the correct VM image
   - Select the appropriate Dockerfile
   - Configure the right node agent SKU
   - Install packages using the correct package manager

3. Rebuild your custom image:
```bash
./batch-prep.sh
```

## Known Issues and Workarounds

### AlmaLinux: OpenSlide Not Available

If you need OpenSlide on AlmaLinux, you have these options:

1. **Use Ubuntu** - Simplest solution
2. **Build from source** - Add to Dockerfile:
```dockerfile
RUN dnf install -y openslide-devel cairo-devel \
    && git clone https://github.com/openslide/openslide-python.git \
    && cd openslide-python && python3 setup.py install
```
3. **Use pre-built container** - Mount volume with OpenSlide

### AlmaLinux 9: Python 3.11 Compatibility

Some older Python packages may have issues with Python 3.11. Test thoroughly before production use.

## Testing Your OS Choice

Run pre-validation to verify OS configuration:

```bash
./batch-prep.sh --validate
```

The script will check:
- VM image availability in your region
- Dockerfile exists for your OS choice
- Required resource providers
- Quota availability

## Performance Considerations

Both Ubuntu and AlmaLinux provide similar performance for ML/AI workloads:
- GPU compute performance: Identical (same CUDA/cuDNN)
- Docker container overhead: Negligible
- Build time: Similar (~15-25 minutes)
- Runtime performance: No significant difference

Choose based on compatibility requirements, not performance.

## Support and Documentation

### Ubuntu Resources
- [Ubuntu on Azure](https://ubuntu.com/azure)
- [Batch Node Agent for Ubuntu](https://docs.microsoft.com/azure/batch/batch-linux-nodes)
- Large community forums and Stack Overflow support

### AlmaLinux Resources
- [AlmaLinux on Azure](https://wiki.almalinux.org/cloud/Azure.html)
- [Batch Node Agent for RHEL](https://docs.microsoft.com/azure/batch/batch-linux-nodes)
- [AlmaLinux Forums](https://forums.almalinux.org/)

## Best Practices

1. **Test in dev first**: Always test your OS choice in a development environment
2. **Pin versions**: Specify exact OS versions for reproducibility
3. **Document dependencies**: List any OS-specific dependencies in your code
4. **Use same OS throughout**: Keep VM image and Docker base consistent
5. **Monitor build times**: Initial builds may take longer with new OS

## Getting Help

If you encounter OS-specific issues:
1. Check TEST-RESULTS.md for validated configurations
2. Review Dockerfile.gpu.{os} for your OS
3. Open GitHub issue with OS details and error logs
4. Consult OS-specific documentation linked above

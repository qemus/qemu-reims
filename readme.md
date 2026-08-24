<h1 align="center">Reims<br />
<div align="center">
  
[![Build]][build_url]
[![Version]][release_url]
[![Size]][release_url]

</div></h1>

Custom QEMU build with [Reims vGPU](https://github.com/steelbrain/reims-vgpu) support for hardware-accelerated macOS graphics and the enhanced [QEMU VMVGA](https://github.com/qemus/qemu-vmvga) VMware SVGA II implementation.

## What is Reims? 🚀

Reims is a paravirtualized GPU implementation for macOS guests. It exposes a virtual Apple-compatible GPU to macOS and uses the stock `AppleParavirtGPU.kext` already present in the guest, so no custom guest kernel extension is required.

On the Linux host the macOS GPU command stream is decoded by Reims and executed through Vulkan on the host GPU. The physical GPU remains owned by Linux instead of being dedicated to the virtual machine through PCI passthrough.

At a high level:

```text
macOS application
      │
      ▼
Metal
      │
      ▼
AppleParavirtGPU.kext
      │
      ▼
reims-vgpu-pci
      │
      ▼
QEMU + Reims
      │
      ▼
metal2vulkan
      │
      ▼
Host Vulkan driver
      │
      ▼
Physical GPU
```

## VMware SVGA II support 🖥️

This build also includes the enhanced [QEMU VMVGA](https://github.com/qemus/qemu-vmvga) implementation. It replaces QEMU's standard `vmware-svga` display-device source with broader VMware SVGA register, FIFO command, capability, cursor and display support, including newer VMware SVGA definitions.

A compatible VMware SVGA guest driver is still required to use device-specific features.

## Runtime requirements ⚙️

- KVM acceleration.
- The Reims vGPU PCI device.
- Shared memfd-backed guest RAM.
- A Vulkan 1.2 or newer host driver.
- The Reims GOP option ROM for EFI display output.

## Acknowledgements 🙏

Special thanks to [steelbrain](https://github.com/steelbrain), this project would not exist without his invaluable work.

[build_url]: https://github.com/qemus/qemu-reims/
[release_url]: https://github.com/qemus/qemu-reims/releases/

[Build]: https://github.com/qemus/qemu-reims/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/badge/size-18.4_MB-steelblue?style=flat&color=066da5
[Version]: https://img.shields.io/github/v/tag/qemus/qemu-reims?label=version&sort=semver&color=066da5

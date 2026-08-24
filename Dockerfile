# syntax=docker/dockerfile:1

FROM debian:trixie-slim AS builder

ARG VERSION_ARG="0.0.0"
ARG QEMU_VERSION="11.1.0"

ARG QEMU_REF="84f07211cc5b4fc6a371559bf8a5de4fb068e648"
ARG REIMS_REF="2844274c34baa1043d37995f5b1a9f1d265eae03"
ARG REIMS_QEMU_REF="e17ddb98f71df5697daf2f830587f672a8f4f5a7"
ARG REIMS_QEMU_BASE="b83371668192a705b878e909c5ae9c1233cbd5fb"

ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBIAN_SNAPSHOT="20260819T142328Z"

RUN <<EOF_BUILD_DEPS
  set -eu

  apt-get update
  apt-get install --no-install-recommends -y ca-certificates

  cat > /etc/apt/sources.list.d/qemu-snapshot.list <<EOF_SOURCES
deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ sid main
deb-src [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ sid main
EOF_SOURCES

  apt-get update
  apt-get build-dep --no-install-recommends -y -t sid qemu
  apt-get install --no-install-recommends -y -t sid \
    binutils \
    dpkg-dev \
    git \
    libdrm-dev \
    libepoxy-dev \
    libgbm-dev \
    libglib2.0-dev \
    libvulkan-dev \
    meson \
    ninja-build \
    pkg-config \
    python3-mako \
    python3-yaml \
    rustup

  rustup set profile minimal
  rustup default stable
  rustup target add x86_64-unknown-uefi

  rm -rf /var/lib/apt/lists/*
EOF_BUILD_DEPS

WORKDIR /src

RUN <<EOF_SOURCE
  set -eu

  # Pin the Reims parent repository. It supplies the Rust GPU implementation,
  # ABI header and GOP source used by the QEMU device integration below.
  git init reims
  git -C reims remote add origin https://github.com/steelbrain/reims-vgpu.git
  git -C reims fetch --depth=1 origin "${REIMS_REF}"
  git -C reims checkout --detach FETCH_HEAD

  actual="$(git -C reims rev-parse HEAD)"
  if [ "$actual" != "${REIMS_REF}" ]; then
    echo "FAIL: Reims resolved to $actual instead of ${REIMS_REF}."
    exit 1
  fi

  # Populate the author's pinned QEMU fork only as the source of the Reims
  # device delta. The binary itself is built from upstream QEMU 11.1.0 below.
  git -C reims submodule update --init --depth=1 vendor/qemu

  actual="$(git -C reims/vendor/qemu rev-parse HEAD)"
  if [ "$actual" != "${REIMS_QEMU_REF}" ]; then
    echo "FAIL: Reims QEMU resolved to $actual instead of ${REIMS_QEMU_REF}."
    exit 1
  fi

  # Fetch the exact fork point needed to generate a minimal Reims-only diff.
  # The range does not need the intervening history; git diff only needs the
  # two pinned trees.
  git -C reims/vendor/qemu remote add upstream https://github.com/qemu/qemu.git
  git -C reims/vendor/qemu fetch --depth=1 upstream "${REIMS_QEMU_BASE}"

  # Fetch the exact upstream QEMU 11.1.0 release commit into a sibling source
  # directory. Keeping it under reims/vendor preserves Reims' existing Meson
  # assumption that the parent project is two directories above QEMU.
  git init reims/vendor/qemu-11.1
  git -C reims/vendor/qemu-11.1 remote add origin https://github.com/qemu/qemu.git
  git -C reims/vendor/qemu-11.1 fetch --depth=1 origin "${QEMU_REF}"
  git -C reims/vendor/qemu-11.1 checkout --detach FETCH_HEAD

  actual="$(git -C reims/vendor/qemu-11.1 rev-parse HEAD)"
  if [ "$actual" != "${QEMU_REF}" ]; then
    echo "FAIL: upstream QEMU resolved to $actual instead of ${QEMU_REF}."
    exit 1
  fi

  actual="$(cat reims/vendor/qemu-11.1/VERSION)"
  if [ "$actual" != "${QEMU_VERSION}" ]; then
    echo "FAIL: upstream QEMU reports version $actual instead of ${QEMU_VERSION}."
    exit 1
  fi

  # Port only the Reims display/device integration onto QEMU 11.1.0. Deliberately
  # exclude the fork's unrelated vmapple/HVF/ARM changes. Modified integration
  # files were unchanged upstream between REIMS_QEMU_BASE and QEMU 11.1.0; the
  # apply --check below also makes future accidental incompatibility fail hard.
  git -C reims/vendor/qemu diff --binary \
    "${REIMS_QEMU_BASE}" "${REIMS_QEMU_REF}" -- \
    hw/display/Kconfig \
    hw/display/meson.build \
    hw/display/reims-vgpu-dirty.c \
    hw/display/reims-vgpu-dirty.h \
    hw/display/reims-vgpu-mmio.c \
    hw/display/reims-vgpu-pci.c \
    hw/display/reims-vgpu-shim.c \
    hw/display/reims-vgpu-shim.h \
    hw/display/trace-events \
    meson_options.txt \
    > /tmp/reims-qemu.patch

  test -s /tmp/reims-qemu.patch
  git -C reims/vendor/qemu-11.1 apply --check /tmp/reims-qemu.patch
  git -C reims/vendor/qemu-11.1 apply --index /tmp/reims-qemu.patch
  git -C reims/vendor/qemu-11.1 diff --cached --check

  # Make sure the port stayed in the intended x86/display integration surface.
  actual="$(git -C reims/vendor/qemu-11.1 diff --cached --name-only | sort)"
  expected="$(printf '%s\n' \
    hw/display/Kconfig \
    hw/display/meson.build \
    hw/display/reims-vgpu-dirty.c \
    hw/display/reims-vgpu-dirty.h \
    hw/display/reims-vgpu-mmio.c \
    hw/display/reims-vgpu-pci.c \
    hw/display/reims-vgpu-shim.c \
    hw/display/reims-vgpu-shim.h \
    hw/display/trace-events \
    meson_options.txt | sort)"

  if [ "$actual" != "$expected" ]; then
    echo "FAIL: unexpected files in the QEMU 11.1 Reims port."
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual"
    exit 1
  fi

  # Keep QEMU configure offline after source preparation. These Meson wraps are
  # needed by the same system-only build configuration used by qemus/qemu.
  meson subprojects download --sourcedir reims/vendor/qemu-11.1 \
    keycodemapdb \
    berkeley-softfloat-3 \
    berkeley-testfloat-3
EOF_SOURCE

RUN <<'EOF_BUILD'
  set -eu

  mkdir /build /out
  cd /build

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  export DEB_CFLAGS_MAINT_APPEND="-ffile-prefix-map=/src/reims=."

  extra_cflags="$(dpkg-buildflags --get CFLAGS) $(dpkg-buildflags --get CPPFLAGS)"
  extra_ldflags="$(dpkg-buildflags --get LDFLAGS)"

  printf 'Debian CFLAGS/CPPFLAGS: %s\n' "$extra_cflags"
  printf 'Debian LDFLAGS: %s\n' "$extra_ldflags"

  /src/reims/vendor/qemu-11.1/configure \
    --with-pkgversion="Reims ${VERSION_ARG}" \
    --target-list=x86_64-softmmu \
    --prefix=/usr \
    --libdir="/usr/lib/${multiarch}" \
    --libexecdir=/usr/lib/qemu \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --mandir=/usr/share/man \
    --firmwarepath=/usr/share/qemu:/usr/share/seabios \
    --extra-cflags="$extra_cflags" \
    --extra-ldflags="$extra_ldflags" \
    --audio-drv-list=alsa,oss \
    --disable-blkio \
    --disable-bzip2 \
    --disable-cocoa \
    --disable-containers \
    --disable-curl \
    --disable-docs \
    --disable-download \
    --disable-gtk \
    --disable-hvf \
    --disable-install-blobs \
    --disable-jack \
    --disable-libiscsi \
    --disable-libnfs \
    --disable-libssh \
    --disable-linux-user \
    --disable-modules \
    --disable-pa \
    --disable-pipewire \
    --disable-rbd \
    --disable-relocatable \
    --disable-sdl \
    --disable-sndio \
    --disable-strip \
    --disable-tools \
    --disable-user \
    --disable-vte \
    --disable-xkbcommon \
    --disable-xen \
    --enable-system \
    --enable-attr \
    --enable-bpf \
    --enable-brlapi \
    --enable-cap-ng \
    --enable-capstone \
    --enable-curses \
    --enable-fdt \
    --enable-fuse \
    --enable-gnutls \
    --enable-kvm \
    --enable-libpmem \
    --enable-libusb \
    --enable-libudev \
    --enable-linux-aio \
    --enable-linux-io-uring \
    --enable-nettle \
    --enable-numa \
    --enable-opengl \
    --enable-pixman \
    --enable-png \
    --enable-rdma \
    --enable-seccomp \
    --enable-slirp \
    --enable-smartcard \
    --enable-spice \
    --enable-tcg \
    --enable-usb-redir \
    --enable-vde \
    --enable-vhost-net \
    --enable-vhost-user \
    --enable-vhost-vdpa \
    --enable-virglrenderer \
    --enable-virtfs \
    --enable-vnc \
    --enable-vnc-jpeg \
    --enable-vnc-sasl \
    --enable-zstd \
    -Dreims_vgpu_backend=vulkan

  # Every explicitly enabled QEMU feature above is a hard configure-time
  # requirement, while the Reims backend is stored as a Meson option so later
  # Meson regeneration cannot silently switch it away from Vulkan.
  meson configure /build

  ninja qemu-system-x86_64

  install -Dm755 /build/qemu-system-x86_64 /out/qemu-system-x86_64
  strip --strip-unneeded /out/qemu-system-x86_64

  /out/qemu-system-x86_64 --version | grep -F "QEMU emulator version 11.1.0"

  # Reims is compiled into this QEMU binary rather than loaded as a QEMU module.
  /out/qemu-system-x86_64 -device reims-vgpu-pci,help >/dev/null 2>&1 || {
    echo "FAIL: reims-vgpu-pci is not registered in the built QEMU binary."
    exit 1
  }

  /out/qemu-system-x86_64 -accel help 2>/dev/null | grep -qi kvm || {
    echo "FAIL: KVM acceleration is not available in the built QEMU binary."
    exit 1
  }

  strings /out/qemu-system-x86_64 | grep -Fq '/usr/share/qemu' || {
    echo "FAIL: QEMU was not built with the /usr/share/qemu data path."
    exit 1
  }

  # Build the EFI GOP option ROM used by the same reims-vgpu-pci function.
  /src/reims/crates/reims-vgpu-efi/scripts/reims-vgpu-efi-rom/reims-vgpu-efi-rom.sh
  install -Dm644 \
    /src/reims/crates/reims-vgpu-efi/out/reims-vgpu-gop.rom \
    /out/reims-vgpu-gop.rom
EOF_BUILD

# Test the produced executable inside the actual qemux/qemu runtime image.
# Modules stay disabled so the custom executable does not depend on external
# QEMU modules even if the Debian package receives a point-release update.
FROM qemux/qemu:latest AS verify

COPY --from=builder /out/qemu-system-x86_64 /tmp/qemu-system-x86_64
COPY --from=builder /out/reims-vgpu-gop.rom /tmp/reims-vgpu-gop.rom

RUN <<'EOF_VERIFY'
  set -eu

  binary=/tmp/qemu-system-x86_64
  rom=/tmp/reims-vgpu-gop.rom

  deps="$(ldd "$binary" 2>&1)"
  printf '%s\n' "$deps"
  if printf '%s\n' "$deps" | grep -q 'not found'; then
    echo "FAIL: one or more QEMU runtime dependencies could not be resolved."
    exit 1
  fi

  # Eager binding is intentionally only a publication-time compatibility test.
  # dockur/macOS does not need LD_BIND_NOW when it later copies this executable.
  LD_BIND_NOW=1 "$binary" --version \
    | grep -F "QEMU emulator version 11.1.0"

  # Probe normal QEMU operation separately from eager ELF binding. The binary
  # is built with QEMU modules disabled, so no QEMU_MODULE_DIR override is needed.
  if ! "$binary" -device reims-vgpu-pci,help >/tmp/reims-pci-help 2>&1; then
    cat /tmp/reims-pci-help
    echo "FAIL: reims-vgpu-pci is not usable in the qemux/qemu runtime."
    exit 1
  fi

  if ! "$binary" -display help >/tmp/display-help 2>&1; then
    cat /tmp/display-help
    echo "FAIL: QEMU display help failed in the qemux/qemu runtime."
    exit 1
  fi
  grep -F "vnc" /tmp/display-help || {
    cat /tmp/display-help
    echo "FAIL: VNC display support is missing in the qemux/qemu runtime."
    exit 1
  }

  if ! "$binary" -accel help >/tmp/accel-help 2>&1; then
    cat /tmp/accel-help
    echo "FAIL: QEMU accelerator help failed in the qemux/qemu runtime."
    exit 1
  fi
  grep -i "kvm" /tmp/accel-help || {
    cat /tmp/accel-help
    echo "FAIL: KVM acceleration is missing in the qemux/qemu runtime."
    exit 1
  }

  test -s "$rom"

  sig="$(xxd -p -l 2 "$rom")"
  if [ "$sig" != "55aa" ]; then
    echo "FAIL: Reims GOP ROM does not start with the PCI option-ROM signature."
    exit 1
  fi

  install -Dm755 "$binary" /out/qemu-system-x86_64
  install -Dm644 "$rom" /out/reims-vgpu-gop.rom
EOF_VERIFY

FROM scratch AS artifact

ARG VERSION_ARG="0.0.0"

LABEL org.opencontainers.image.title="Reims" \
      org.opencontainers.image.description="QEMU build with Reims vGPU support for macOS guests." \
      org.opencontainers.image.version="${VERSION_ARG}"

COPY --from=verify /out/qemu-system-x86_64 /usr/bin/qemu-system-x86_64
COPY --from=verify /out/reims-vgpu-gop.rom /usr/share/qemu/reims-vgpu-gop.rom

# syntax=docker/dockerfile:1

FROM debian:trixie-slim AS builder

ARG VERSION_ARG="0.0.0"
ARG QEMU_VERSION="11.0.50"
ARG REIMS_REF="2844274c34baa1043d37995f5b1a9f1d265eae03"
ARG QEMU_REF="e17ddb98f71df5697daf2f830587f672a8f4f5a7"

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
  apt-get install --no-install-recommends -y \
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

  git init reims
  git -C reims remote add origin https://github.com/steelbrain/reims-vgpu.git
  git -C reims fetch --depth=1 origin "${REIMS_REF}"
  git -C reims checkout --detach FETCH_HEAD

  actual="$(git -C reims rev-parse HEAD)"
  if [ "$actual" != "${REIMS_REF}" ]; then
    echo "FAIL: Reims resolved to $actual instead of ${REIMS_REF}."
    exit 1
  fi

  git -C reims submodule update --init --depth=1 vendor/qemu

  actual="$(git -C reims/vendor/qemu rev-parse HEAD)"
  if [ "$actual" != "${QEMU_REF}" ]; then
    echo "FAIL: Reims QEMU resolved to $actual instead of ${QEMU_REF}."
    exit 1
  fi

  actual="$(cat reims/vendor/qemu/VERSION)"
  if [ "$actual" != "${QEMU_VERSION}" ]; then
    echo "FAIL: Reims QEMU reports version $actual instead of ${QEMU_VERSION}."
    exit 1
  fi

  # Keep QEMU configure offline after source preparation. These Meson wraps are
  # needed by the same system-only build configuration used by qemus/qemu.
  meson subprojects download --sourcedir reims/vendor/qemu \
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

  /src/reims/vendor/qemu/configure \
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

  # Reims is compiled into this QEMU binary rather than loaded as a QEMU module.
  /out/qemu-system-x86_64 -device reims-vgpu-mmio,help >/dev/null 2>&1 || {
    echo "FAIL: reims-vgpu-mmio is not registered in the built QEMU binary."
    exit 1
  }

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
# Modules stay disabled so a Reims QEMU release does not depend on the module
# ABI of the Debian QEMU point release used by qemux/qemu.
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

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 "$binary" --version \
    | grep -F "QEMU emulator version 11.0.50"

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -device reims-vgpu-mmio,help >/tmp/reims-mmio-help 2>&1

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -device reims-vgpu-pci,help >/tmp/reims-pci-help 2>&1

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -display help >/tmp/display-help 2>&1
  grep -F "vnc" /tmp/display-help

  QEMU_MODULE_DIR=/nonexistent LD_BIND_NOW=1 \
    "$binary" -accel help >/tmp/accel-help 2>&1
  grep -i "kvm" /tmp/accel-help

  test -s "$rom"

  # The ROM builder already validates the complete PCI/PE structure. Keep a
  # lightweight independent check here after crossing the stage boundary.
  [ "$(od -An -tx1 -N2 "$rom" | tr -d ' \n')" = "55aa" ] || {
    echo "FAIL: Reims GOP ROM is missing the PCI option-ROM signature."
    exit 1
  }

  install -Dm755 "$binary" /out/qemu-system-x86_64
  install -Dm644 "$rom" /out/reims-vgpu-gop.rom

  qemu_size="$(stat -c %s /out/qemu-system-x86_64)"
  rom_size="$(stat -c %s /out/reims-vgpu-gop.rom)"
  echo "Verified qemu-system-x86_64 (${qemu_size} bytes)"
  echo "Verified reims-vgpu-gop.rom (${rom_size} bytes)"
EOF_VERIFY

FROM scratch AS artifact

ARG VERSION_ARG="0.0.0"

LABEL org.opencontainers.image.title="Reims" \
      org.opencontainers.image.description="Reims-enabled QEMU build for accelerated macOS graphics." \
      org.opencontainers.image.version="${VERSION_ARG}"

COPY --from=verify /out/qemu-system-x86_64 /usr/bin/qemu-system-x86_64
COPY --from=verify /out/reims-vgpu-gop.rom /usr/share/qemu/reims-vgpu-gop.rom

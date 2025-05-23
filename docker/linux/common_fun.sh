#!/bin/bash -e

set -o pipefail

ARCH="$(uname -m)"

DEB_ARCH=amd64
case $ARCH in
    'aarch64' )
        DEB_ARCH=arm64
        BAZELISK_SHA256SUM="$BAZELISK_SHA256SUM_ARM64"
        LLVM_DISTRO="$LLVM_DISTRO_ARM64"
        LLVM_SHA256SUM="$LLVM_SHA256SUM_ARM64"
        ;;
esac


download_and_check () {
    local to=$1
    local url=$2
    local sha256=$3
    echo "Download: ${url} -> ${to}"
    wget -q -O "${to}" "${url}"
    echo "${sha256}  ${to}" | sha256sum --check
}

install_llvm_bins () {
    LLVM_RELEASE="clang+llvm-${LLVM_VERSION}-${LLVM_DISTRO}"
    download_and_check "${LLVM_RELEASE}.tar.xz" "${LLVM_DOWNLOAD_PREFIX}${LLVM_VERSION}/${LLVM_RELEASE}.tar.xz" "${LLVM_SHA256SUM}"
    mkdir /opt/llvm
    tar Jxf "${LLVM_RELEASE}.tar.xz" --strip-components=1 -C /opt/llvm
    chown -R root:root /opt/llvm
    rm "./${LLVM_RELEASE}.tar.xz"
    LLVM_HOST_TARGET="$(/opt/llvm/bin/llvm-config --host-target)"
    echo "/opt/llvm/lib/${LLVM_HOST_TARGET}" > /etc/ld.so.conf.d/llvm.conf
    ldconfig
}

install_libcxx () {
    local LLVM_USE_SANITIZER=$1
    local LIBCXX_PATH=$2
    pushd llvm-project-llvmorg-${LLVM_VERSION}
    cmake -GNinja \
          -B "${LIBCXX_PATH}" \
          -S "runtimes" \
          -DLLVM_ENABLE_RUNTIMES="libcxxabi;libcxx;libunwind" \
          -DLLVM_USE_LINKER=lld \
          -DLLVM_USE_SANITIZER="${LLVM_USE_SANITIZER}" \
          -DCMAKE_BUILD_TYPE=RelWithDebInfo \
          -DCMAKE_C_COMPILER=clang \
          -DCMAKE_CXX_COMPILER=clang++ \
          -DCMAKE_INSTALL_PREFIX="/opt/libcxx_${LIBCXX_PATH}" \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    ninja -C "${LIBCXX_PATH}" install-cxx install-cxxabi
    if [[ -n "$(diff --exclude=module.modulemap --exclude=__config_site -r "/opt/libcxx_${LIBCXX_PATH}/include/c++" /opt/llvm/include/c++)" ]]; then
        echo "Different libc++ is installed"
        exit 1
    fi
    rm -rf "/opt/libcxx_${LIBCXX_PATH}/include"
    popd
}

install_san () {
    # Install sanitizer instrumented libc++, skipping for architectures other than x86_64 for now.
    if [[ "$(uname -m)" != "x86_64" ]]; then
        mkdir /opt/libcxx_msan
        mkdir /opt/libcxx_tsan
        return 0
    fi
    export PATH="/opt/llvm/bin:${PATH}"
    WORKDIR=$(mktemp -d)
    pushd "${WORKDIR}"
    wget -q -O -  "https://github.com/llvm/llvm-project/archive/llvmorg-${LLVM_VERSION}.tar.gz" | tar zx
    install_libcxx MemoryWithOrigins msan
    install_libcxx Thread tsan
    popd
}

## Build install fun
install_build_tools () {
    # bazelisk
    download_and_check \
        /usr/local/bin/bazel \
        "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-${DEB_ARCH}" \
        "${BAZELISK_SHA256SUM}"
    chmod +x /usr/local/bin/bazel
}

install_lcov () {
    download_and_check "lcov-${LCOV_VERSION}.tar.gz" "https://github.com/linux-test-project/lcov/releases/download/v${LCOV_VERSION}/lcov-${LCOV_VERSION}.tar.gz" \
                       "${LCOV_SHA256SUM}"
    tar zxf "lcov-${LCOV_VERSION}.tar.gz"
    make -C "lcov-${LCOV_VERSION}" install
    rm -rf "lcov-${LCOV_VERSION}" "./lcov-${LCOV_VERSION}.tar.gz"
}

install_clang_tools () {
    if [[ -z "$CLANG_TOOLS_SHA256SUM" ]]; then
        return
    fi
    # Pick `run-clang-tidy.py` from `clang-tools-extra` and place in filepath expected by Envoy CI.
    # Only required for more recent LLVM/Clang versions
    ENVOY_CLANG_TIDY_PATH=/opt/llvm/share/clang/run-clang-tidy.py
    CLANG_TOOLS_SRC="clang-tools-extra-${LLVM_VERSION}.src"
    CLANG_TOOLS_TARBALL="${CLANG_TOOLS_SRC}.tar.xz"
    download_and_check "./${CLANG_TOOLS_TARBALL}" "${LLVM_DOWNLOAD_PREFIX}${LLVM_VERSION}/${CLANG_TOOLS_TARBALL}" "$CLANG_TOOLS_SHA256SUM"
    mkdir -p /opt/llvm/share/clang/
    tar JxfO "./${CLANG_TOOLS_TARBALL}" "${CLANG_TOOLS_SRC}/clang-tidy/tool/run-clang-tidy.py" > "$ENVOY_CLANG_TIDY_PATH"
    rm "./${CLANG_TOOLS_TARBALL}"
}

install_build () {
    setup_tcpdump
    install_build_tools
    install_clang_tools
    install_lcov
    git config --global --add safe.directory /source
    mv ~/.gitconfig /etc/gitconfig
    export PATH="/opt/llvm/bin:${PATH}"
}

setup_tcpdump () {
    # Setup tcpdump for non-root.
    groupadd -r pcap
    chgrp pcap /usr/sbin/tcpdump
    chmod 750 /usr/sbin/tcpdump
    setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump
}

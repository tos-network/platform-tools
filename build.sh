#!/usr/bin/env bash
set -ex

# Parallel build configuration
PARALLEL_JOBS=${PARALLEL_JOBS:-8}
export MAKEFLAGS="-j${PARALLEL_JOBS}"
export CARGO_BUILD_JOBS=${PARALLEL_JOBS}

# Log file configuration
LOG_DIR="/tmp"
LOG_FILE="${LOG_DIR}/platform-tools-build-$(date +%Y%m%d-%H%M%S).log"

# Redirect all output to both console and log file
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=========================================="
echo "Platform-tools build started at $(date)"
echo "Parallel jobs: ${PARALLEL_JOBS}"
echo "Log file: ${LOG_FILE}"
echo "=========================================="

function build_newlib() {
    mkdir -p newlib_build_"$1"
    mkdir -p newlib_"$1"
    pushd newlib_build_"$1"

    local c_flags="-O2"
    if [[ "$1" != "v0" ]] ; then
      c_flags="${c_flags} -mcpu=$1"
    fi

    CFLAGS="${c_flags}" \
    CC="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/clang" \
      AR="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/llvm-ar" \
      RANLIB="${OUT_DIR}/rust/build/${HOST_TRIPLE}/llvm/bin/llvm-ranlib" \
      ../newlib/newlib/configure --target=tbf-tos-tos --host=tbf-tos --build="${HOST_TRIPLE}" --prefix="${OUT_DIR}/newlib_$1"
    make -j${PARALLEL_JOBS} install
    popd
}

function copy_newlib() {
    local folder_name=""
    if [[ "$1" != "v0" ]] ; then
        folder_name="$1"
    fi

    mkdir -p deploy/llvm/lib/tbpf"${folder_name}"
    mkdir -p deploy/llvm/tbpf"${folder_name}"
    cp -R newlib_"$1"/tbf-tos/lib/lib{c,m}.a deploy/llvm/lib/tbpf"${folder_name}"/
    cp -R newlib_"$1"/tbf-tos/include deploy/llvm/tbpf"${folder_name}"/   
}

unameOut="$(uname -s)"
case "${unameOut}" in
    Darwin*)
        EXE_SUFFIX=
        if [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
            HOST_TRIPLE=aarch64-apple-darwin
            ARTIFACT=tos-platform-tools-osx-aarch64.tar.bz2
        else
            HOST_TRIPLE=x86_64-apple-darwin
            ARTIFACT=tos-platform-tools-osx-x86_64.tar.bz2
        fi;;
    MINGW*)
        EXE_SUFFIX=.exe
        HOST_TRIPLE=x86_64-pc-windows-msvc
        ARTIFACT=tos-platform-tools-windows-x86_64.tar.bz2;;
    Linux* | *)
        EXE_SUFFIX=
        if [[ "$(uname -m)" == "arm64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
            HOST_TRIPLE=aarch64-unknown-linux-gnu
            ARTIFACT=tos-platform-tools-linux-aarch64.tar.bz2
        else
            HOST_TRIPLE=x86_64-unknown-linux-gnu
            ARTIFACT=tos-platform-tools-linux-x86_64.tar.bz2
        fi
esac

cd "$(dirname "$0")"
OUT_DIR="$(realpath ./)/${1:-out}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"
pushd "${OUT_DIR}"

git clone --single-branch --branch main --recurse-submodules --shallow-submodules https://github.com/tos-network/rust.git
echo "$( cd rust && git rev-parse HEAD )  https://github.com/tos-network/rust.git" >> version.md

git clone --single-branch --branch main https://github.com/tos-network/cargo.git
echo "$( cd cargo && git rev-parse HEAD )  https://github.com/tos-network/cargo.git" >> version.md

pushd rust
if [[ "${HOST_TRIPLE}" == "x86_64-pc-windows-msvc" ]] ; then
    # Do not build lldb on Windows
    sed -i -e 's#enable-projects = \"clang;lld;lldb\"#enable-projects = \"clang;lld\"#g' bootstrap.toml
fi

if [[ "${HOST_TRIPLE}" == *"apple"* ]]; then
    # Do not build lldb on macOS to avoid codesign certificate issues
    sed -i '' 's#enable-projects = "clang;lld;lldb"#enable-projects = "clang;lld"#g' bootstrap.toml
fi

# Skip bootstrap target sanity check for custom TOS targets
export BOOTSTRAP_SKIP_TARGET_SANITY=1
./build.sh
popd

pushd cargo
if [[ "${HOST_TRIPLE}" == "x86_64-unknown-linux-gnu" ]] ; then
    OPENSSL_STATIC=1 OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu OPENSSL_INCLUDE_DIR=/usr/include/openssl cargo build --release
else
    OPENSSL_STATIC=1 cargo build --release
fi
popd

if [[ "${HOST_TRIPLE}" != "x86_64-pc-windows-msvc" ]] ; then
    git clone --single-branch --branch main https://github.com/tos-network/newlib.git
    echo "$( cd newlib && git rev-parse HEAD )  https://github.com/tos-network/newlib.git" >> version.md

    # Patch config.sub to recognize tbf-tos and tbpf-tos targets
    pushd newlib
    # Add support for custom TOS targets so config.sub recognizes them
    python3 - <<'PY'
from pathlib import Path

path = Path("config.sub")
text = path.read_text()

os_marker = "| cygwin* | msys* | pe* | moss* | proelf* | rtems* \\"
os_replacement = "| cygwin* | msys* | pe* | moss* | proelf* | rtems* | tos* \\"
if "| tos* \\" not in text and os_marker in text:
    text = text.replace(os_marker, os_replacement)

cpu_marker = "| bfin | bpf | bs2000 \\"
cpu_replacement = "| bfin | bpf | tbf | tbpf | tbpfv1 | tbpfv2 | bs2000 \\"
if " | tbf | " not in text and cpu_marker in text:
    text = text.replace(cpu_marker, cpu_replacement)

path.write_text(text)
PY
    popd

    build_newlib "v0"
    build_newlib "v1"
    build_newlib "v2"
fi

# Copy rust build products
mkdir -p deploy/rust
cp version.md deploy/
cp -R "rust/build/${HOST_TRIPLE}/stage1/bin" deploy/rust/
cp -R "cargo/target/release/cargo${EXE_SUFFIX}" deploy/rust/bin/
mkdir -p deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/${HOST_TRIPLE}" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbf-tos-tos" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbpf-tos-tos" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbpfv1-tos-tos" deploy/rust/lib/rustlib/
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/tbpfv2-tos-tos" deploy/rust/lib/rustlib/
find . -maxdepth 6 -type f -path "./rust/build/${HOST_TRIPLE}/stage1/lib/*" -exec cp {} deploy/rust/lib \;
mkdir -p deploy/rust/lib/rustlib/src/rust
cp "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/src/rust/Cargo.lock" deploy/rust/lib/rustlib/src/rust
cp -R "rust/build/${HOST_TRIPLE}/stage1/lib/rustlib/src/rust/library" deploy/rust/lib/rustlib/src/rust

# Copy llvm build products
mkdir -p deploy/llvm/{bin,lib}
while IFS= read -r f
do
    bin_file="rust/build/${HOST_TRIPLE}/llvm/build/bin/${f}${EXE_SUFFIX}"
    if [[ -f "$bin_file" ]] ; then
        cp -R "$bin_file" deploy/llvm/bin/
    fi
done < <(cat <<EOF
clang
clang++
clang-cl
clang-cpp
clang-20
ld.lld
ld64.lld
llc
lld
lld-link
lldb
lldb-vscode
llvm-ar
llvm-objcopy
llvm-objdump
llvm-readelf
llvm-readobj
EOF
         )
cp -R "rust/build/${HOST_TRIPLE}/llvm/build/lib/clang" deploy/llvm/lib/
if [[ "${HOST_TRIPLE}" != "x86_64-pc-windows-msvc" ]] ; then
    cp -R newlib_v0/tbf-tos/lib/lib{c,m}.a deploy/llvm/lib/
    cp -R newlib_v0/tbf-tos/include deploy/llvm/

    copy_newlib "v0"
    copy_newlib "v1"
    copy_newlib "v2"

    # Only copy LLDB files if LLDB was built (not on Windows or macOS)
    if [[ "${HOST_TRIPLE}" != *"apple"* ]] && [[ -d "rust/src/llvm-project/lldb/scripts/tos" ]]; then
        cp -R rust/src/llvm-project/lldb/scripts/tos/* deploy/llvm/bin/
        cp -R rust/build/${HOST_TRIPLE}/llvm/lib/liblldb.* deploy/llvm/lib/
        if [[ "${HOST_TRIPLE}" == "x86_64-unknown-linux-gnu" || "${HOST_TRIPLE}" == "aarch64-unknown-linux-gnu" ]]; then
            cp -R rust/build/${HOST_TRIPLE}/llvm/local/lib/python* deploy/llvm/lib
        else
            cp -R rust/build/${HOST_TRIPLE}/llvm/lib/python* deploy/llvm/lib/
        fi
    fi
fi

# Check the Rust binaries
while IFS= read -r f
do
    "./deploy/rust/bin/${f}${EXE_SUFFIX}" --version
done < <(cat <<EOF
cargo
rustc
rustdoc
EOF
         )
# Check the LLVM binaries
while IFS= read -r f
do
    if [[ -f "./deploy/llvm/bin/${f}${EXE_SUFFIX}" ]] ; then
        "./deploy/llvm/bin/${f}${EXE_SUFFIX}" --version
    fi
done < <(cat <<EOF
clang
clang++
clang-cl
clang-cpp
ld.lld
llc
lld-link
llvm-ar
llvm-objcopy
llvm-objdump
llvm-readelf
llvm-readobj
tos-lldb
EOF
         )

tar -C deploy -jcf ${ARTIFACT} .
rm -rf deploy

popd

mv "${OUT_DIR}/${ARTIFACT}" .

# Build linux binaries on macOS in docker
if [[ "$(uname)" == "Darwin" ]] && [[ $# == 1 ]] && [[ "$1" == "--docker" ]] ; then
    docker system prune -a -f
    docker build -t tosnetwork/platform-tools .
    id=$(docker create tosnetwork/platform-tools /build.sh "${OUT_DIR}")
    docker cp build.sh "${id}:/"
    docker start -a "${id}"
    docker cp "${id}:${OUT_DIR}/tos-tbf-tools-linux-x86_64.tar.bz2" "${OUT_DIR}"
fi

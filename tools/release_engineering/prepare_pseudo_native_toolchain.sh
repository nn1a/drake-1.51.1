#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [jammy|noble|resolute] [arm64]

Prepare an amd64-hosted cross compiler bundle that can be mounted into an
emulated arm64 Docker build. The bundle is intentionally separate from the
arm64 rootfs so the compiler and binutils execute natively on an amd64 host
while still producing arm64 objects.

Environment:
  PSEUDO_NATIVE_CACHE_DIR       Cache root (default: ../.deb-cache)
  PSEUDO_NATIVE_DIR             Output bundle directory override
  PSEUDO_NATIVE_TARBALL
                                 Output tarball override
                                 (default: bundle directory + .tar.gz)
  PSEUDO_NATIVE_FORCE           Rebuild even when cached output exists
                                 (default: 0)
  PSEUDO_NATIVE_IMAGE           Build a Docker image containing the bundle
                                 at /opt/pseudo-native-toolchain
  PSEUDO_NATIVE_PUSH            Push that image after building it
                                 (default: 0)
  PSEUDO_NATIVE_HOST_TOOLS      Add optional amd64 host tools to the bundle.
                                 Values: 0, compression, core-search,
                                 core-text, core, debug, shell, all, 1
                                 (default: all; all includes shell;
                                 1 means compression)
  PSEUDO_NATIVE_HOST_TOOL_LIST  Explicit whitespace/comma separated tool list.
                                 Overrides PSEUDO_NATIVE_HOST_TOOLS groups.

EOF
}

codename="${1:-noble}"
target_arch="${2:-arm64}"

case "${codename}" in
  jammy|noble|resolute)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

case "${target_arch}" in
  arm64)
    target_triple=aarch64-linux-gnu
    ;;
  *)
    echo "Pseudo-native toolchain preparation currently supports arm64 only" >&2
    exit 2
    ;;
esac

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
repo_parent=$(dirname "${repo_root}")
cache_root="${PSEUDO_NATIVE_CACHE_DIR:-${repo_parent}/.deb-cache}"
bundle_dir="${PSEUDO_NATIVE_DIR:-${cache_root}/${codename}-${target_arch}/pseudo-native-toolchain}"
tarball="${PSEUDO_NATIVE_TARBALL:-${bundle_dir}.tar.gz}"
tmp_dir="${bundle_dir}.tmp.$$"
host_uid=$(id -u)
host_gid=$(id -g)
force_rebuild=0
image_tag="${PSEUDO_NATIVE_IMAGE:-}"
push_image=0
force_value="${PSEUDO_NATIVE_FORCE:-0}"
push_value="${PSEUDO_NATIVE_PUSH:-0}"
host_tools_value="${PSEUDO_NATIVE_HOST_TOOLS:-all}"
host_tool_list_value="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}"
bundle_format_version=5

resolve_host_tool_list() {
  local spec="$1"
  local explicit_list="$2"
  local token
  local requested_tools=()

  explicit_list="${explicit_list//,/ }"
  if [[ -n "${explicit_list}" ]]; then
    for token in ${explicit_list}; do
      if [[ ! "${token}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        echo "Invalid PSEUDO_NATIVE_HOST_TOOL_LIST entry: ${token}" >&2
        exit 2
      fi
      if [[ "${token}" == perl ]]; then
        echo "Pseudo-native host perl is not supported" >&2
        exit 2
      fi
      requested_tools+=("${token}")
    done
  else
    spec="${spec//,/ }"
    for token in ${spec}; do
      case "${token}" in
        0|no|false|"")
          ;;
        1|yes|true|compression)
          requested_tools+=(
            tar
            xz xzcat
            gzip gunzip
            zstd zstdcat
            bzip2 bunzip2
            zip unzip
          )
          ;;
        core-search)
          requested_tools+=(
            find xargs
            grep
            sort uniq comm join
            cut tr wc
            head tail
            md5sum sha1sum sha224sum sha256sum sha384sum sha512sum
          )
          ;;
        core-text)
          requested_tools+=(
            cat paste
            expand unexpand fold
            split csplit
            tac nl od
            base32 base64 basenc
            b2sum cksum sum
            tsort
            basename dirname
            readlink realpath pathchk
            seq tee
          )
          ;;
        core)
          requested_tools+=(
            find xargs
            grep
            sort uniq comm join
            cut tr wc
            head tail
            md5sum sha1sum sha224sum sha256sum sha384sum sha512sum
            cat paste
            expand unexpand fold
            split csplit
            tac nl od
            base32 base64 basenc
            b2sum cksum sum
            tsort
            basename dirname
            readlink realpath pathchk
            seq tee
          )
          ;;
        shell)
          requested_tools+=(
            bash dash
          )
          ;;
        debug)
          requested_tools+=(
            dwz
          )
          ;;
        all)
          requested_tools+=(
            tar
            xz xzcat
            gzip gunzip
            zstd zstdcat
            bzip2 bunzip2
            zip unzip
            find xargs
            grep
            sort uniq comm join
            cut tr wc
            head tail
            md5sum sha1sum sha224sum sha256sum sha384sum sha512sum
            cat paste
            expand unexpand fold
            split csplit
            tac nl od
            base32 base64 basenc
            b2sum cksum sum
            tsort
            basename dirname
            readlink realpath pathchk
            seq tee
            dwz
            bash dash
          )
          ;;
        *)
          echo "Unknown PSEUDO_NATIVE_HOST_TOOLS entry: ${token}" >&2
          exit 2
          ;;
      esac
    done
  fi

  if [[ "${#requested_tools[@]}" -eq 0 ]]; then
    return
  fi

  printf '%s\n' "${requested_tools[@]}" | awk '!seen[$0]++' | tr '\n' ' '
}

host_tool_list=$(resolve_host_tool_list "${host_tools_value}" "${host_tool_list_value}")

host_tools_ready() {
  local actual_tools expected_tools
  expected_tools=$(printf '%s\n' ${host_tool_list})
  actual_tools=$(cat "${bundle_dir}/host/tools.txt" 2>/dev/null || true)
  [[ "${actual_tools}" == "${expected_tools}" ]]
}

toolchain_ready() {
  if [[ ! -x "${bundle_dir}/bin/cc" ]]; then
    return 1
  fi
  if [[ "$(cat "${bundle_dir}/.pseudo-native-format" 2>/dev/null || true)" != \
      "${bundle_format_version}" ]]; then
    return 1
  fi
  host_tools_ready
}

case "${force_value}" in
  1|yes|true)
    force_rebuild=1
    ;;
  0|no|false|"")
    force_rebuild=0
    ;;
  *)
    echo "Unknown PSEUDO_NATIVE_FORCE=${force_value}" >&2
    exit 2
    ;;
esac

case "${push_value}" in
  1|yes|true)
    push_image=1
    ;;
  0|no|false|"")
    push_image=0
    ;;
  *)
    echo "Unknown PSEUDO_NATIVE_PUSH=${push_value}" >&2
    exit 2
    ;;
esac

rm -rf "${tmp_dir}"
mkdir -p "$(dirname "${bundle_dir}")" "${tmp_dir}"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "==> Preparing pseudo-native ${target_triple} toolchain for ${codename}"
echo "==> Output bundle: ${bundle_dir}"
echo "==> Output tarball: ${tarball}"
if [[ -n "${host_tool_list}" ]]; then
  echo "==> Optional amd64 host tools: ${host_tool_list}"
fi

create_tarball() {
  local tarball_tmp

  tarball_tmp="${tarball}.tmp.$$"
  rm -f "${tarball_tmp}"
  mkdir -p "$(dirname "${tarball}")"
  tar -C "$(dirname "${bundle_dir}")" \
    -czf "${tarball_tmp}" \
    "$(basename "${bundle_dir}")"
  mv "${tarball_tmp}" "${tarball}"
}

build_image_if_requested() {
  local image_context

  if [[ -z "${image_tag}" ]]; then
    return
  fi

  image_context="${bundle_dir}.image-context.$$"
  rm -rf "${image_context}"
  mkdir -p "${image_context}"
  cp -a "${bundle_dir}" "${image_context}/pseudo-native-toolchain"
cat > "${image_context}/Dockerfile" <<EOF_DOCKERFILE
ARG UBUNTU_CODENAME=${codename}
FROM ubuntu:\${UBUNTU_CODENAME}
COPY pseudo-native-toolchain/ /opt/pseudo-native-toolchain/
EOF_DOCKERFILE

  echo "==> Building pseudo-native image ${image_tag}"
  docker build \
    --platform linux/amd64 \
    --build-arg "UBUNTU_CODENAME=${codename}" \
    --tag "${image_tag}" \
    "${image_context}"

  rm -rf "${image_context}"

  if [[ "${push_image}" -eq 1 ]]; then
    echo "==> Pushing pseudo-native image ${image_tag}"
    docker push "${image_tag}"
  fi
}

if [[ "${force_rebuild}" -eq 0 ]] && toolchain_ready; then
  if [[ ! -f "${tarball}" ]]; then
    echo "==> Reusing existing bundle and creating missing tarball"
    create_tarball
  else
    echo "==> Reusing existing bundle and tarball"
  fi
  build_image_if_requested
  exit 0
fi

if [[ "${force_rebuild}" -eq 0 && -f "${tarball}" ]]; then
  echo "==> Restoring bundle from existing tarball"
  rm -rf "${bundle_dir}"
  mkdir -p "${bundle_dir}"
  tar -xzf "${tarball}" -C "${bundle_dir}" --strip-components=1
  if toolchain_ready; then
    build_image_if_requested
    exit 0
  fi
  echo "Existing tarball did not contain a usable toolchain; rebuilding" >&2
  rm -rf "${bundle_dir}"
fi

docker run --rm --interactive \
  --platform linux/amd64 \
  --env DEBIAN_FRONTEND=noninteractive \
  --env HOST_UID="${host_uid}" \
  --env HOST_GID="${host_gid}" \
  --env PSEUDO_NATIVE_HOST_TOOL_LIST_RESOLVED="${host_tool_list}" \
  --volume "${tmp_dir}:/out" \
  "ubuntu:${codename}" \
  bash -s -- "${target_triple}" <<'EOS'
set -euo pipefail

target_triple="$1"
out=/out/root
host_tool_list="${PSEUDO_NATIVE_HOST_TOOL_LIST_RESOLVED:-}"

apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates \
  "binutils-${target_triple}" \
  "gcc-${target_triple}" \
  "g++-${target_triple}" \
  "gfortran-${target_triple}"
if [[ -n "${host_tool_list}" ]]; then
  host_tool_packages=(
    patchelf \
    tar \
    xz-utils \
    zstd \
    gzip \
    bzip2 \
    zip \
    unzip \
    findutils \
    grep \
    coreutils \
    dwz \
    bash \
    dash
  )
  apt-get install -y -qq --no-install-recommends \
    "${host_tool_packages[@]}"
fi

rm -rf "${out}"
mkdir -p \
  "${out}/bin" \
  "${out}/host/bin" \
  "${out}/host/usr/bin" \
  "${out}/lib" \
  "${out}/lib64" \
  "${out}/usr/bin" \
  "${out}/usr/libexec" \
  "${out}/usr/lib/bfd-plugins" \
  "${out}/usr/lib/gcc-cross" \
  "${out}/usr/lib"

cp -a /usr/bin/"${target_triple}"-* "${out}/usr/bin/"
cp -a "/usr/lib/gcc-cross/${target_triple}" "${out}/usr/lib/gcc-cross/"
if [[ -d /usr/libexec/gcc-cross ]]; then
  cp -a /usr/libexec/gcc-cross "${out}/usr/libexec/"
fi
cp -a "/usr/${target_triple}" "${out}/usr/"
for gcc_version_dir in "${out}/usr/lib/gcc-cross/${target_triple}"/*; do
  if [[ -d "${gcc_version_dir}/include" ]]; then
    mv "${gcc_version_dir}/include" \
      "${gcc_version_dir}/include.pseudo-native-bundle"
  fi
  if [[ -d "${gcc_version_dir}/include-fixed" ]]; then
    mv "${gcc_version_dir}/include-fixed" \
      "${gcc_version_dir}/include-fixed.pseudo-native-bundle"
  fi
done
if [[ -d /usr/lib/bfd-plugins ]]; then
  cp -a /usr/lib/bfd-plugins/. "${out}/usr/lib/bfd-plugins/"
fi
cp -a /lib/x86_64-linux-gnu "${out}/lib/"
cp -a /usr/lib/x86_64-linux-gnu "${out}/usr/lib/"
cp -L /lib64/ld-linux-x86-64.so.2 "${out}/lib64/ld-linux-x86-64.so.2"

cat > "${out}/bin/pseudo-native-tool" <<'EOF_WRAPPER'
#!/usr/bin/env bash

set -euo pipefail

target_triple="@TARGET_TRIPLE@"
tool=$(basename "$0")
short_tool="${tool#${target_triple}-}"

script=$(readlink -f "$0")
root="${PSEUDO_NATIVE_ROOT:-$(cd "$(dirname "${script}")/.." && pwd)}"

gcc_dir=$(find "${root}/usr/lib/gcc-cross/${target_triple}" \
  -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)
if [[ -z "${gcc_dir}" ]]; then
  echo "Unable to locate cross GCC directory under ${root}" >&2
  exit 1
fi
gcc_version=$(basename "${gcc_dir}")
gcc_bundle_include_dir="${gcc_dir}/include.pseudo-native-bundle"
gcc_bundle_include_fixed_dir="${gcc_dir}/include-fixed.pseudo-native-bundle"
lto_plugin="${gcc_dir}/liblto_plugin.so"
if [[ ! -e "${lto_plugin}" ]]; then
  lto_plugin=$(find "${root}/usr/lib/gcc-cross/${target_triple}" \
    -name liblto_plugin.so -print -quit)
fi
if [[ -z "${lto_plugin}" || ! -e "${lto_plugin}" ]]; then
  echo "Unable to locate liblto_plugin.so under ${root}" >&2
  exit 1
fi

ld_library_path="${root}/lib/x86_64-linux-gnu:${root}/usr/lib/x86_64-linux-gnu:${gcc_dir}"
extra_ld_library_path="${PSEUDO_NATIVE_EXTRA_LD_LIBRARY_PATH:-}"
if [[ -n "${extra_ld_library_path}" ]]; then
  ld_library_path="${ld_library_path}:${extra_ld_library_path}"
fi
export LD_LIBRARY_PATH="${ld_library_path}"
export COMPILER_PATH="${gcc_dir}:${root}/usr/${target_triple}/bin${COMPILER_PATH:+:${COMPILER_PATH}}"
export LIBRARY_PATH="${gcc_dir}:${root}/usr/${target_triple}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
export GCC_EXEC_PREFIX="${root}/usr/lib/gcc-cross/"
export GCC_AR="${root}/bin/gcc-ar"
export GCC_NM="${root}/bin/gcc-nm"
export GCC_RANLIB="${root}/bin/gcc-ranlib"

mode=binutils
language=c
case "${short_tool}" in
  cc|gcc)
    program="${target_triple}-gcc"
    mode=compiler
    ;;
  c++|g++)
    program="${target_triple}-g++"
    mode=compiler
    language=cxx
    ;;
  cpp)
    program="${target_triple}-cpp"
    mode=compiler
    ;;
  compiler|gfortran)
    program="${target_triple}-gfortran"
    mode=compiler
    ;;
  ld)
    program="${target_triple}-ld"
    mode=linker_with_lto_plugin
    ;;
  ar|gcc-ar)
    program="${target_triple}-ar"
    mode=binutils_with_lto_plugin
    ;;
  nm|gcc-nm)
    program="${target_triple}-nm"
    mode=binutils_with_lto_plugin
    ;;
  ranlib|gcc-ranlib)
    program="${target_triple}-ranlib"
    mode=binutils_with_lto_plugin
    ;;
  as|objcopy|objdump|readelf|size|strip)
    program="${target_triple}-${short_tool}"
    ;;
  *)
    echo "Unsupported pseudo-native tool name: ${tool}" >&2
    exit 2
    ;;
esac

prev_was_x=0
for arg in "$@"; do
  if [[ "${prev_was_x}" -eq 1 ]]; then
    case "${arg}" in
      c++|c++-*|gnu++*)
        language=cxx
        ;;
    esac
    prev_was_x=0
    continue
  fi
  case "${arg}" in
    -x)
      prev_was_x=1
      ;;
    -xc++|-xc++-*|-xgnu++*)
      language=cxx
      ;;
    *.C|*.cc|*.cp|*.cpp|*.cxx|*.c++|*.CPP|*.CXX)
      language=cxx
      ;;
  esac
done

compiler_include_args=()
add_system_include_dir() {
  local include_dir="$1"
  if [[ -d "${include_dir}" ]]; then
    compiler_include_args+=(-isystem "${include_dir}")
  fi
}
if [[ "${mode}" == compiler ]]; then
  compiler_include_args=(-nostdinc)
  if [[ "${language}" == cxx ]]; then
    add_system_include_dir "/usr/include/c++/${gcc_version}"
    add_system_include_dir "/usr/include/${target_triple}/c++/${gcc_version}"
    add_system_include_dir "/usr/include/c++/${gcc_version}/backward"
  fi
  if [[ -d "/usr/lib/gcc/${target_triple}/${gcc_version}/include" ]]; then
    add_system_include_dir "/usr/lib/gcc/${target_triple}/${gcc_version}/include"
  else
    add_system_include_dir "${gcc_bundle_include_dir}"
  fi
  if [[ -d "/usr/lib/gcc/${target_triple}/${gcc_version}/include-fixed" ]]; then
    add_system_include_dir "/usr/lib/gcc/${target_triple}/${gcc_version}/include-fixed"
  else
    add_system_include_dir "${gcc_bundle_include_fixed_dir}"
  fi
  add_system_include_dir /usr/local/include
  add_system_include_dir "/usr/include/${target_triple}"
  add_system_include_dir /usr/include
fi

binary="${root}/usr/bin/${program}"
loader="${root}/lib64/ld-linux-x86-64.so.2"
if [[ ! -x "${binary}" ]]; then
  echo "Missing pseudo-native binary: ${binary}" >&2
  exit 1
fi
if [[ ! -x "${loader}" ]]; then
  echo "Missing x86_64 dynamic loader: ${loader}" >&2
  exit 1
fi

case "${mode}" in
  compiler)
    exec "${loader}" --library-path "${ld_library_path}" "${binary}" \
      --sysroot=/ \
      "-B${gcc_dir}/" \
      "-B${root}/usr/${target_triple}/bin/" \
      "${compiler_include_args[@]}" \
      "$@"
    ;;
  linker)
    exec "${loader}" --library-path "${ld_library_path}" "${binary}" \
      --sysroot=/ \
      "$@"
    ;;
  linker_with_lto_plugin)
    exec "${loader}" --library-path "${ld_library_path}" "${binary}" \
      --sysroot=/ \
      "--plugin=${lto_plugin}" \
      "$@"
    ;;
  binutils_with_lto_plugin)
    exec "${loader}" --library-path "${ld_library_path}" "${binary}" \
      "--plugin=${lto_plugin}" \
      "$@"
    ;;
  *)
    exec "${loader}" --library-path "${ld_library_path}" "${binary}" "$@"
    ;;
esac
EOF_WRAPPER

sed -i "s/@TARGET_TRIPLE@/${target_triple}/g" "${out}/bin/pseudo-native-tool"
chmod 0755 "${out}/bin/pseudo-native-tool"

for tool in cc c++ gcc g++ cpp gfortran gcc-ar gcc-nm gcc-ranlib ar as ld nm objcopy objdump ranlib readelf size strip; do
  ln -s pseudo-native-tool "${out}/bin/${tool}"
  ln -s pseudo-native-tool "${out}/bin/${target_triple}-${tool}"
done

if [[ -n "${host_tool_list}" ]]; then
  cat > "${out}/host/bin/pseudo-native-host-tool" <<'EOF_HOST_WRAPPER'
#!/usr/bin/env bash

set -euo pipefail

tool=$(basename "$0")
script=$(readlink -f "$0")
root="${PSEUDO_NATIVE_ROOT:-$(cd "$(dirname "${script}")/../.." && pwd)}"

binary="${root}/host/usr/bin/${tool}"
loader="${root}/lib64/ld-linux-x86-64.so.2"
ld_library_path="${root}/lib/x86_64-linux-gnu:${root}/usr/lib/x86_64-linux-gnu"
extra_ld_library_path="${PSEUDO_NATIVE_EXTRA_LD_LIBRARY_PATH:-}"
if [[ -n "${extra_ld_library_path}" ]]; then
  ld_library_path="${ld_library_path}:${extra_ld_library_path}"
fi

if [[ ! -x "${binary}" ]]; then
  echo "Missing pseudo-native host binary: ${binary}" >&2
  exit 1
fi
if [[ ! -x "${loader}" ]]; then
  echo "Missing x86_64 dynamic loader: ${loader}" >&2
  exit 1
fi

exec "${loader}" --library-path "${ld_library_path}" "${binary}" "$@"
EOF_HOST_WRAPPER
  chmod 0755 "${out}/host/bin/pseudo-native-host-tool"

  : > "${out}/host/tools.txt"
  for tool in ${host_tool_list}; do
    tool_path=$(type -P "${tool}" || true)
    if [[ -z "${tool_path}" || ! -x "${tool_path}" ]]; then
      echo "Unable to locate requested host tool: ${tool}" >&2
      exit 1
    fi
    cp -aL "${tool_path}" "${out}/host/usr/bin/${tool}"
    if patchelf --print-interpreter "${out}/host/usr/bin/${tool}" \
      >/dev/null 2>&1
    then
      patchelf \
        --set-interpreter /lib64/ld-linux-x86-64.so.2 \
        --set-rpath \
        '$ORIGIN/../../../lib/x86_64-linux-gnu:$ORIGIN/../../../usr/lib/x86_64-linux-gnu' \
        "${out}/host/usr/bin/${tool}"
    fi
    case "${tool}" in
      bash|dash)
        ln -s "../usr/bin/${tool}" "${out}/host/bin/${tool}"
        ;;
      *)
        ln -s pseudo-native-host-tool "${out}/host/bin/${tool}"
        ;;
    esac
    printf '%s\n' "${tool}" >> "${out}/host/tools.txt"
  done
fi

cat > "${out}/README.txt" <<EOF_README
Pseudo-native ${target_triple} toolchain extracted from ubuntu:${VERSION_CODENAME:-unknown}

Mount this directory at /opt/pseudo-native-toolchain and set:
  PSEUDO_NATIVE_ROOT=/opt/pseudo-native-toolchain

The wrappers run amd64 cross compiler binaries through the bundled x86_64
loader and force --sysroot=/ so target headers and libraries still come from
the arm64 container rootfs.

Bundled GCC internal headers are kept under include.pseudo-native-bundle
instead of the canonical include directory, so GCC does not leak
/opt/pseudo-native-toolchain/... include paths into dependency output. When the
target rootfs has matching native GCC headers, the wrapper uses those paths.

The wrapper also routes ar/nm/ranlib through gcc-ar/gcc-nm/gcc-ranlib when
available and otherwise passes liblto_plugin.so explicitly to binutils, so LTO
objects remain usable inside static archives.

Optional host tools, when present, live under host/bin. They are amd64 tools
for host-side build work such as compression or file scanning, not target
toolchain commands. Copied host tool binaries are also patched with
/lib64/ld-linux-x86-64.so.2 and private x86_64 library RPATHs so their shared
libraries do not resolve from the arm64 rootfs.
EOF_README

chown -R "${HOST_UID}:${HOST_GID}" "${out}"
EOS

rm -rf "${bundle_dir}"
mv "${tmp_dir}/root" "${bundle_dir}"
printf '%s\n' "${bundle_format_version}" > "${bundle_dir}/.pseudo-native-format"
create_tarball
build_image_if_requested
trap - EXIT
rm -rf "${tmp_dir}"

echo "==> Pseudo-native toolchain is ready: ${bundle_dir}"
echo "==> Pseudo-native tarball is ready: ${tarball}"

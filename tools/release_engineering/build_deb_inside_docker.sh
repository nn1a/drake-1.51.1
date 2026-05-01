#!/usr/bin/env bash

set -euo pipefail

: "${HOST_UID:?HOST_UID is required}"
: "${HOST_GID:?HOST_GID is required}"
: "${DRAKE_DEB_CODENAME:?DRAKE_DEB_CODENAME is required}"
: "${DRAKE_DEB_ARCH:=}"
: "${DRAKE_DEB_HOST_ARCH:=}"
: "${DRAKE_DEB_DISABLE_PYCOMPILE:=auto}"
: "${DRAKE_DEB_REUSE_BUILD_TREE:=1}"
: "${DRAKE_DEB_BAZEL_OUTPUT_BASE:=/home/builder/.cache/bazel/output-base}"
: "${DRAKE_DEB_BAZEL_REPOSITORY_CACHE:=/home/builder/.cache/bazel/repository-cache}"
: "${DRAKE_DEB_BAZEL_DISK_CACHE:=/home/builder/.cache/bazel/disk-cache}"
: "${DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS:=auto}"
: "${DRAKE_DEB_BAZEL_BATCH:=auto}"
: "${PSEUDO_NATIVE_TOOLCHAIN:=0}"
: "${PSEUDO_NATIVE_ROOT:=/opt/pseudo-native-toolchain}"
: "${PSEUDO_NATIVE_HOST_TOOLS:=all}"
: "${PSEUDO_NATIVE_HOST_TOOL_LIST:=}"

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

actual_codename=$(
  . /etc/os-release
  echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
)
if [[ "${actual_codename}" != "${DRAKE_DEB_CODENAME}" ]]; then
  echo "Expected ${DRAKE_DEB_CODENAME}, but container is ${actual_codename}" >&2
  exit 2
fi

actual_arch=$(dpkg --print-architecture)
if [[ -n "${DRAKE_DEB_ARCH}" && "${actual_arch}" != "${DRAKE_DEB_ARCH}" ]]; then
  echo "Expected ${DRAKE_DEB_ARCH}, but container architecture is ${actual_arch}" >&2
  exit 2
fi

bazel_qemu_workarounds=0
case "${DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS}" in
  auto|"")
    if [[ -n "${DRAKE_DEB_HOST_ARCH}" && "${actual_arch}" != "${DRAKE_DEB_HOST_ARCH}" ]]; then
      bazel_qemu_workarounds=1
    fi
    ;;
  1|yes|true)
    bazel_qemu_workarounds=1
    ;;
  0|no|false)
    bazel_qemu_workarounds=0
    ;;
  *)
    echo "Unknown DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS=${DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS}" >&2
    exit 2
    ;;
esac
DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS="${bazel_qemu_workarounds}"

command -v mk-build-deps >/dev/null
command -v dpkg-buildpackage >/dev/null

restore_py3compile() {
  if [[ -e /usr/bin/py3compile.real ]]; then
    mv /usr/bin/py3compile.real /usr/bin/py3compile
  fi
}

disable_pycompile=0
case "${DRAKE_DEB_DISABLE_PYCOMPILE}" in
  auto|"")
    if [[ -n "${DRAKE_DEB_HOST_ARCH}" && "${actual_arch}" != "${DRAKE_DEB_HOST_ARCH}" ]]; then
      disable_pycompile=1
    fi
    ;;
  1|yes|true)
    disable_pycompile=1
    ;;
  0|no|false)
    disable_pycompile=0
    ;;
  *)
    echo "Unknown DRAKE_DEB_DISABLE_PYCOMPILE=${DRAKE_DEB_DISABLE_PYCOMPILE}" >&2
    exit 2
    ;;
esac

case "${DRAKE_DEB_REUSE_BUILD_TREE}" in
  1|yes|true)
    reuse_build_tree=1
    ;;
  0|no|false)
    reuse_build_tree=0
    ;;
  *)
    echo "Unknown DRAKE_DEB_REUSE_BUILD_TREE=${DRAKE_DEB_REUSE_BUILD_TREE}" >&2
    exit 2
    ;;
esac

case "${PSEUDO_NATIVE_TOOLCHAIN}" in
  1|yes|true)
    pseudo_native_toolchain=1
    ;;
  0|no|false|"")
    pseudo_native_toolchain=0
    ;;
  *)
    echo "Unknown PSEUDO_NATIVE_TOOLCHAIN=${PSEUDO_NATIVE_TOOLCHAIN}" >&2
    exit 2
    ;;
esac

pseudo_native_host_tools=0
case "${PSEUDO_NATIVE_HOST_TOOLS}" in
  0|no|false|"")
    if [[ -n "${PSEUDO_NATIVE_HOST_TOOL_LIST}" ]]; then
      pseudo_native_host_tools=1
    fi
    ;;
  *)
    pseudo_native_host_tools=1
    ;;
esac

activate_pseudo_native_host_tools() {
  local tool
  if [[ "${pseudo_native_toolchain}" -ne 1 || "${pseudo_native_host_tools}" -ne 1 ]]; then
    return
  fi
  if [[ ! -s "${PSEUDO_NATIVE_ROOT}/host/tools.txt" ]]; then
    echo "Pseudo-native host tools were requested, but none are bundled" >&2
    exit 1
  fi
  if [[ ! -x "${PSEUDO_NATIVE_ROOT}/lib64/ld-linux-x86-64.so.2" ]]; then
    echo "Missing bundled x86_64 loader in ${PSEUDO_NATIVE_ROOT}" >&2
    exit 1
  fi
  mkdir -p /lib64 /usr/local/bin
  if [[ ! -x /lib64/ld-linux-x86-64.so.2 ]]; then
    ln -sfn \
      "${PSEUDO_NATIVE_ROOT}/lib64/ld-linux-x86-64.so.2" \
      /lib64/ld-linux-x86-64.so.2
  fi

  echo "Activating optional pseudo-native amd64 host tools"
  export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
  link_pseudo_native_host_tool() {
    local source="$1"
    local dest="$2"
    local source_id dest_id
    if [[ -e "${dest}" || -L "${dest}" ]]; then
      source_id=$(stat -Lc '%d:%i' "${source}" 2>/dev/null || true)
      dest_id=$(stat -Lc '%d:%i' "${dest}" 2>/dev/null || true)
      if [[ -n "${source_id}" && "${source_id}" == "${dest_id}" ]]; then
        return
      fi
    fi
    ln -sfn "${source}" "${dest}"
  }

  while IFS= read -r tool; do
    if [[ -z "${tool}" ]]; then
      continue
    fi
    if [[ "${tool}" == perl ]]; then
      echo "Pseudo-native host perl is no longer supported; rebuild the bundle" >&2
      exit 1
    fi
    if [[ ! -x "${PSEUDO_NATIVE_ROOT}/host/usr/bin/${tool}" ]]; then
      echo "Missing pseudo-native host tool: ${tool}" >&2
      exit 1
    fi
    if ! link_pseudo_native_host_tool \
      "${PSEUDO_NATIVE_ROOT}/host/usr/bin/${tool}" \
      "/usr/local/bin/${tool}" 2>/dev/null
    then
      if [[ ! -x "/usr/local/bin/${tool}" ]]; then
        echo "Unable to activate pseudo-native host tool: ${tool}" >&2
        exit 1
      fi
    fi
    if [[ -e "/usr/bin/${tool}" || -L "/usr/bin/${tool}" ]]; then
      if ! link_pseudo_native_host_tool \
        "${PSEUDO_NATIVE_ROOT}/host/usr/bin/${tool}" \
        "/usr/bin/${tool}" 2>/dev/null
      then
        if [[ ! -x "/usr/bin/${tool}" ]]; then
          echo "Unable to activate pseudo-native host /usr/bin/${tool}" >&2
          exit 1
        fi
      fi
    fi
    if [[ -d /bin && ! -L /bin && -e "/bin/${tool}" ]]; then
      if ! link_pseudo_native_host_tool \
        "${PSEUDO_NATIVE_ROOT}/host/usr/bin/${tool}" \
        "/bin/${tool}" 2>/dev/null
      then
        if [[ ! -x "/bin/${tool}" ]]; then
          echo "Unable to activate pseudo-native host /bin/${tool}" >&2
          exit 1
        fi
      fi
    fi
  done < "${PSEUDO_NATIVE_ROOT}/host/tools.txt"
}

activate_pseudo_native_host_tools

if [[ "${disable_pycompile}" -eq 1 && -x /usr/bin/py3compile ]]; then
  echo "Temporarily disabling py3compile while installing build dependencies"
  mv /usr/bin/py3compile /usr/bin/py3compile.real
  printf '#!/bin/sh\nexit 0\n' >/usr/bin/py3compile
  chmod 0755 /usr/bin/py3compile
  trap restore_py3compile EXIT
fi

apt-get update
mk-build-deps \
  --install \
  --remove \
  --tool "apt-get -y --no-install-recommends" \
  debian/control
restore_py3compile
trap - EXIT

if [[ "${pseudo_native_toolchain}" -eq 1 ]]; then
  if [[ "${actual_arch}" != arm64 ]]; then
    echo "Pseudo-native toolchain mode currently supports arm64 containers only" >&2
    exit 2
  fi
  if [[ "${DRAKE_DEB_HOST_ARCH}" != amd64 ]]; then
    echo "Pseudo-native toolchain mode requires an amd64 Docker host" >&2
    exit 2
  fi
  if [[ ! -x "${PSEUDO_NATIVE_ROOT}/bin/cc" ]]; then
    echo "Missing pseudo-native toolchain at ${PSEUDO_NATIVE_ROOT}" >&2
    exit 1
  fi
  if [[ ! -x "${PSEUDO_NATIVE_ROOT}/lib64/ld-linux-x86-64.so.2" ]]; then
    echo "Missing bundled x86_64 loader in ${PSEUDO_NATIVE_ROOT}" >&2
    exit 1
  fi

  echo "Activating pseudo-native amd64->arm64 toolchain from ${PSEUDO_NATIVE_ROOT}"
  mkdir -p /lib64
  if [[ ! -x /lib64/ld-linux-x86-64.so.2 ]]; then
    ln -sfn \
      "${PSEUDO_NATIVE_ROOT}/lib64/ld-linux-x86-64.so.2" \
      /lib64/ld-linux-x86-64.so.2
  fi

  # Ubuntu's amd64-hosted aarch64 cross packages use linker scripts that
  # refer to /usr/aarch64-linux-gnu/lib, while the native arm64 container keeps
  # those libraries under the normal multiarch path.
  mkdir -p /usr/aarch64-linux-gnu
  if [[ ! -e /usr/aarch64-linux-gnu/lib && ! -L /usr/aarch64-linux-gnu/lib ]]; then
    ln -s /usr/lib/aarch64-linux-gnu /usr/aarch64-linux-gnu/lib
  fi

  for tool in \
    cc c++ gcc g++ cpp gfortran \
    ar as ld nm objcopy objdump ranlib readelf size strip \
    aarch64-linux-gnu-cc aarch64-linux-gnu-c++ \
    aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ aarch64-linux-gnu-cpp \
    aarch64-linux-gnu-gfortran aarch64-linux-gnu-ar aarch64-linux-gnu-as \
    aarch64-linux-gnu-ld aarch64-linux-gnu-nm aarch64-linux-gnu-objcopy \
    aarch64-linux-gnu-objdump aarch64-linux-gnu-ranlib \
    aarch64-linux-gnu-readelf aarch64-linux-gnu-size aarch64-linux-gnu-strip
  do
    if [[ -x "${PSEUDO_NATIVE_ROOT}/bin/${tool}" ]]; then
      ln -sfn "${PSEUDO_NATIVE_ROOT}/bin/${tool}" "/usr/bin/${tool}"
    fi
  done
  for tool_path in "${PSEUDO_NATIVE_ROOT}"/bin/*; do
    tool=$(basename "${tool_path}")
    if [[ "${tool}" != pseudo-native-tool && -x "${tool_path}" ]]; then
      ln -sfn "${tool_path}" "/usr/bin/${tool}"
    fi
  done

  cc_machine=$(/usr/bin/cc -dumpmachine)
  cxx_machine=$(/usr/bin/c++ -dumpmachine)
  echo "Pseudo-native cc target: ${cc_machine}"
  echo "Pseudo-native c++ target: ${cxx_machine}"
  case "${cc_machine}:${cxx_machine}" in
    aarch64-linux-gnu*:aarch64-linux-gnu*)
      ;;
    *)
      echo "Pseudo-native toolchain did not report an arm64 target" >&2
      exit 1
      ;;
  esac
fi

if ! getent group "${HOST_GID}" >/dev/null; then
  groupadd --gid "${HOST_GID}" builder
fi

build_user=builder
if getent passwd "${HOST_UID}" >/dev/null; then
  build_user=$(getent passwd "${HOST_UID}" | cut -d: -f1)
else
  useradd --uid "${HOST_UID}" --gid "${HOST_GID}" \
    --create-home --shell /bin/bash "${build_user}"
fi

mkdir -p \
  /home/builder/.cache/bazel \
  /home/builder/.cache/bazelisk \
  "${DRAKE_DEB_BAZEL_OUTPUT_BASE}" \
  "${DRAKE_DEB_BAZEL_REPOSITORY_CACHE}" \
  "${DRAKE_DEB_BAZEL_DISK_CACHE}" \
  /work/out
chown -R "${HOST_UID}:${HOST_GID}" /home/builder /work/out
chmod 1777 /work
rm -rf \
  debian/.debhelper \
  debian/*.debhelper.log \
  debian/*.substvars \
  debian/debhelper-build-stamp \
  debian/files \
  debian/tmp \
  debian/drake-build-deps \
  debian/drake-dev

if [[ "${reuse_build_tree}" -eq 0 ]]; then
  rm -rf obj-*
else
  echo "Reusing existing obj-* build tree and Bazel caches when present"

  # A migrated Bazel output_base can contain absolute symlinks to the old
  # debhelper HOME. Keep those links valid while the persistent cache warms up.
  legacy_bazel_root="debian/.debhelper/generated/_source/home/.cache/bazel/_bazel_ubuntu"
  mkdir -p "${legacy_bazel_root}"
  ln -sfn "${DRAKE_DEB_BAZEL_REPOSITORY_CACHE}" "${legacy_bazel_root}/cache"
  if [[ -d /home/builder/.cache/bazel/_bazel_ubuntu/install ]]; then
    ln -sfn /home/builder/.cache/bazel/_bazel_ubuntu/install \
      "${legacy_bazel_root}/install"
  fi
  build_dir="obj-$(dpkg-architecture -qDEB_HOST_GNU_TYPE)"
  if [[ ! -d "${build_dir}" ]]; then
    build_dir=
    for candidate in obj-*; do
      if [[ -d "${candidate}" ]]; then
        build_dir="${candidate}"
        break
      fi
    done
  fi
  if [[ -n "${build_dir}" ]]; then
    build_hash=$(printf '%s' "/work/drake/${build_dir}" | md5sum | awk '{print $1}')
    ln -sfn "${DRAKE_DEB_BAZEL_OUTPUT_BASE}" "${legacy_bazel_root}/${build_hash}"
  fi
  chown -hR "${HOST_UID}:${HOST_GID}" debian/.debhelper
fi

DRAKE_DEB_REUSE_BUILD_TREE="${reuse_build_tree}"
export \
  DRAKE_DEB_BAZEL_OUTPUT_BASE \
  DRAKE_DEB_BAZEL_REPOSITORY_CACHE \
  DRAKE_DEB_BAZEL_DISK_CACHE \
  DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS \
  DRAKE_DEB_BAZEL_BATCH \
  DRAKE_DEB_REUSE_BUILD_TREE

su --preserve-environment --shell /bin/bash "${build_user}" -c '
  set -euo pipefail
  cd /work/drake
  export HOME=/home/builder
  export DRAKE_DEB_BUILD_HOME=/home/builder
  export XDG_CACHE_HOME=/home/builder/.cache
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  if [[ "${DRAKE_DEB_REUSE_BUILD_TREE}" == 1 ]]; then
    dpkg-buildpackage -us -uc -b -nc
  else
    dpkg-buildpackage -us -uc -b
  fi
  shopt -s nullglob
  cp -av ../*.deb ../*.buildinfo ../*.changes /work/out/
'

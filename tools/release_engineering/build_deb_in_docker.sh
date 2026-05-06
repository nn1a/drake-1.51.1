#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--arch amd64|arm64|all] [all|jammy|noble|resolute|amd64|arm64 ...]

Without arguments, builds jammy, noble, and resolute.
Each target first builds a small Ubuntu development base image. The actual
Drake build dependencies are installed later from debian/control inside
the running container.

Environment:
  DRAKE_DEB_OUTPUT_DIR          Output root directory (default: ../deb-output)
  DRAKE_DEB_CACHE_DIR           Docker cache root (default: ../.deb-cache)
  DRAKE_DEB_ARCHS               Architectures to build (default: amd64)
  DRAKE_DEB_BASE_IMAGE_PREFIX   Base image prefix (default: drake-deb-build)
  DRAKE_DEB_DOCKER_IMAGE        Prebuilt image override for all builds
  DRAKE_DEB_DOCKER_IMAGE_AMD64  Prebuilt image override for amd64
  DRAKE_DEB_DOCKER_IMAGE_ARM64  Prebuilt image override for arm64
  DRAKE_DEB_DOCKER_IMAGE_JAMMY  Prebuilt image override for jammy
  DRAKE_DEB_DOCKER_IMAGE_NOBLE  Prebuilt image override for noble
  DRAKE_DEB_DOCKER_IMAGE_RESOLUTE
                                 Prebuilt image override for resolute
  DRAKE_DEB_DOCKER_IMAGE_JAMMY_AMD64
  DRAKE_DEB_DOCKER_IMAGE_JAMMY_ARM64
  DRAKE_DEB_DOCKER_IMAGE_NOBLE_AMD64
  DRAKE_DEB_DOCKER_IMAGE_NOBLE_ARM64
  DRAKE_DEB_DOCKER_IMAGE_RESOLUTE_AMD64
  DRAKE_DEB_DOCKER_IMAGE_RESOLUTE_ARM64
  DRAKE_DEB_DISABLE_PYCOMPILE
                                 Skip py3compile while installing build deps
                                 (default: auto for emulated builds)
  DRAKE_DEB_REUSE_BUILD_TREE     Keep obj-* and pass -nc to dpkg-buildpackage
                                 for iterative testing (default: 1)
  DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS
                                 Add Bazel flags for qemu-user builds
                                 (default: auto)
  DRAKE_DEB_BAZEL_BATCH          Add startup --batch to generated .bazelrc
                                 (default: auto; follows qemu workarounds)
  DRAKE_DEB_BAZEL_JOBS           Optional Bazel --jobs value for memory-bound
                                 builds
  PSEUDO_NATIVE_TOOLCHAIN
                                 Use an amd64-hosted cross compiler bundle for
                                 emulated arm64 builds (default: 0; use auto to
                                 enable for amd64-host/arm64-target builds)
  PSEUDO_NATIVE_DIR              Existing/prepared pseudo-native bundle path
                                 (default: target cache/pseudo-native-toolchain)
  PSEUDO_NATIVE_STORAGE
                                 Mount pseudo-native toolchain from dir or
                                 Docker volume, or experimental Docker image
                                 mount (dir|volume|image; default: dir)
  PSEUDO_NATIVE_IMAGE            Image to pull/use when populating the volume
  PSEUDO_NATIVE_VOLUME           Docker volume name override
                                 (default: pseudo-native-toolchain-<target>)
  PSEUDO_NATIVE_PULL             Pull the pseudo-native image before populating
                                 the volume (default: 1 when image is set)
  PSEUDO_NATIVE_HOST_TOOLS       Activate optional amd64 host tools from the
                                 pseudo-native bundle. Values: 0, compression,
                                 core-search, core-text, core, debug,
                                 packaging, shell, all, 1
                                 (default: all; all includes shell;
                                 1 means compression)
  PSEUDO_NATIVE_HOST_TOOL_LIST   Explicit whitespace/comma separated host tool
                                 list to bundle and activate.
  PSEUDO_NATIVE_BAZEL            Download and run the amd64 Bazel binary via
                                 Bazelisk in pseudo-native arm64 builds.
                                 Values: 0, 1, auto (default: 0)
EOF
}

codename_targets=()
arch_targets=()

append_arch_targets() {
  local value arch
  value="${1//,/ }"
  for arch in ${value}; do
    case "${arch}" in
      all)
        arch_targets+=(amd64 arm64)
        ;;
      amd64|arm64)
        arch_targets+=("${arch}")
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    all)
      codename_targets=(jammy noble resolute)
      ;;
    jammy|noble|resolute)
      codename_targets+=("$1")
      ;;
    amd64|arm64)
      arch_targets+=("$1")
      ;;
    --arch)
      shift
      if [[ "$#" -eq 0 ]]; then
        usage >&2
        exit 2
      fi
      append_arch_targets "$1"
      ;;
    --arch=*)
      append_arch_targets "${1#--arch=}"
      ;;
    --all-arches)
      arch_targets=(amd64 arm64)
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
  shift
done

if [[ "${#codename_targets[@]}" -eq 0 ]]; then
  codename_targets=(jammy noble resolute)
fi

if [[ "${#arch_targets[@]}" -eq 0 ]]; then
  append_arch_targets "${DRAKE_DEB_ARCHS:-amd64}"
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
repo_parent=$(dirname "${repo_root}")
output_root="${DRAKE_DEB_OUTPUT_DIR:-${repo_parent}/deb-output}"
cache_root="${DRAKE_DEB_CACHE_DIR:-${repo_parent}/.deb-cache}"
base_image_prefix="${DRAKE_DEB_BASE_IMAGE_PREFIX:-drake-deb-build}"
dockerfile="${repo_root}/tools/release_engineering/debian/Dockerfile"
docker_context="${repo_root}/tools/release_engineering/debian"
pseudo_native_format_version=7
host_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "${host_arch}" in
  x86_64)
    host_arch=amd64
    ;;
  aarch64)
    host_arch=arm64
    ;;
esac

tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args=(-it)
fi

target_suffix() {
  local codename="$1"
  local arch="$2"
  if [[ "${arch}" == amd64 ]]; then
    echo "${codename}"
  else
    echo "${codename}-${arch}"
  fi
}

pseudo_native_host_tools_requested() {
  case "${PSEUDO_NATIVE_HOST_TOOLS:-all}" in
    0|no|false|"")
      [[ -n "${PSEUDO_NATIVE_HOST_TOOL_LIST:-}" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

pseudo_native_shell_host_tools_requested() {
  local host_tool_list="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}"
  local host_tools="${PSEUDO_NATIVE_HOST_TOOLS:-all}"
  local token
  if [[ -n "${host_tool_list}" ]]; then
    for token in ${host_tool_list//,/ }; do
      if [[ "${token}" == bash ]]; then
        return 0
      fi
    done
    return 1
  fi
  for token in ${host_tools//,/ }; do
    if [[ "${token}" == shell || "${token}" == all ]]; then
      return 0
    fi
  done
  return 1
}

pseudo_native_bundle_ready() {
  local bundle_dir="$1"
  [[ -x "${bundle_dir}/bin/cc" ]] || return 1
  [[ "$(cat "${bundle_dir}/.pseudo-native-format" 2>/dev/null || true)" == \
    "${pseudo_native_format_version}" ]]
}

run_build() {
  local codename="$1"
  local arch="$2"
  local platform="linux/${arch}"
  local suffix image image_var arch_image_var codename_image_var
  local output_dir cache_dir
  local pseudo_native pseudo_native_dir pseudo_native_storage
  local pseudo_native_image pseudo_native_volume pseudo_native_pull
  local pseudo_native_root_in_container=/opt/pseudo-native-toolchain
  local pseudo_native_host_tools=0
  local pseudo_native_bazel=0
  local pseudo_native_volume_probe
  local pseudo_native_args=()
  local pseudo_native_host_tool_mount_args=()
  local pseudo_native_shell_mount_args=()
  local build_command=(
    /work/drake/tools/release_engineering/build_deb_inside_docker.sh
  )

  suffix=$(target_suffix "${codename}" "${arch}")
  image_var="DRAKE_DEB_DOCKER_IMAGE_${codename^^}_${arch^^}"
  codename_image_var="DRAKE_DEB_DOCKER_IMAGE_${codename^^}"
  arch_image_var="DRAKE_DEB_DOCKER_IMAGE_${arch^^}"
  image="${!image_var:-${!arch_image_var:-${!codename_image_var:-${DRAKE_DEB_DOCKER_IMAGE:-${base_image_prefix}:${suffix}}}}}"
  output_dir="${output_root}/${suffix}"
  cache_dir="${cache_root}/${suffix}"

  mkdir -p \
    "${output_dir}" \
    "${cache_dir}/apt" \
    "${cache_dir}/bazel" \
    "${cache_dir}/bazelisk"

  pseudo_native=0
  case "${PSEUDO_NATIVE_TOOLCHAIN:-0}" in
    auto)
      if [[ "${host_arch}" == amd64 && "${arch}" == arm64 ]]; then
        pseudo_native=1
      fi
      ;;
    1|yes|true)
      pseudo_native=1
      ;;
    0|no|false|"")
      pseudo_native=0
      ;;
    *)
      echo "Unknown PSEUDO_NATIVE_TOOLCHAIN=${PSEUDO_NATIVE_TOOLCHAIN}" >&2
      exit 2
      ;;
  esac

  case "${PSEUDO_NATIVE_BAZEL:-0}" in
    auto)
      if [[ "${pseudo_native}" -eq 1 ]]; then
        pseudo_native_bazel=1
      fi
      ;;
    1|yes|true)
      pseudo_native_bazel=1
      ;;
    0|no|false|"")
      pseudo_native_bazel=0
      ;;
    *)
      echo "Unknown PSEUDO_NATIVE_BAZEL=${PSEUDO_NATIVE_BAZEL}" >&2
      exit 2
      ;;
  esac

  if [[ "${pseudo_native_bazel}" -eq 1 && "${pseudo_native}" -ne 1 ]]; then
    echo "PSEUDO_NATIVE_BAZEL requires PSEUDO_NATIVE_TOOLCHAIN" >&2
    exit 2
  fi

  if [[ "${pseudo_native}" -eq 1 ]]; then
    if pseudo_native_host_tools_requested; then
      pseudo_native_host_tools=1
    fi
    if [[ "${arch}" != arm64 ]]; then
      echo "Pseudo-native toolchain mode currently supports arm64 targets only" >&2
      exit 2
    fi
    if [[ "${host_arch}" != amd64 ]]; then
      echo "Pseudo-native toolchain mode requires an amd64 Docker host" >&2
      exit 2
    fi
    pseudo_native_storage="${PSEUDO_NATIVE_STORAGE:-dir}"
    pseudo_native_dir="${PSEUDO_NATIVE_DIR:-${cache_dir}/pseudo-native-toolchain}"
    pseudo_native_image="${PSEUDO_NATIVE_IMAGE:-}"
    pseudo_native_volume="${PSEUDO_NATIVE_VOLUME:-pseudo-native-toolchain-${suffix}}"
    pseudo_native_pull="${PSEUDO_NATIVE_PULL:-}"

    case "${pseudo_native_storage}" in
      dir)
        if ! pseudo_native_bundle_ready "${pseudo_native_dir}" || \
          [[ "${pseudo_native_host_tools}" -eq 1 ]]
        then
          PSEUDO_NATIVE_CACHE_DIR="${cache_root}" \
          PSEUDO_NATIVE_DIR="${pseudo_native_dir}" \
          PSEUDO_NATIVE_IMAGE="${pseudo_native_image}" \
          PSEUDO_NATIVE_HOST_TOOLS="${PSEUDO_NATIVE_HOST_TOOLS:-all}" \
          PSEUDO_NATIVE_HOST_TOOL_LIST="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}" \
            "${repo_root}/tools/release_engineering/prepare_pseudo_native_toolchain.sh" \
            "${codename}" "${arch}"
        fi
        pseudo_native_args=(
          --env PSEUDO_NATIVE_TOOLCHAIN=1
          --env PSEUDO_NATIVE_ROOT="${pseudo_native_root_in_container}"
          --env PSEUDO_NATIVE_HOST_TOOLS="${PSEUDO_NATIVE_HOST_TOOLS:-all}"
          --env PSEUDO_NATIVE_HOST_TOOL_LIST="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}"
          --volume "${pseudo_native_dir}:${pseudo_native_root_in_container}:ro"
        )
        if [[ "${pseudo_native_host_tools}" -eq 1 ]]; then
          pseudo_native_host_tool_mount_args=(
            --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
            --volume "${pseudo_native_dir}/host/usr/bin:/usr/local/bin:ro"
            --volume "${pseudo_native_dir}/lib64:/lib64:ro"
            --volume "${pseudo_native_dir}/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro"
            --volume "${pseudo_native_dir}/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:ro"
          )
        fi
        if pseudo_native_shell_host_tools_requested; then
          pseudo_native_shell_mount_args=(
            --volume "${pseudo_native_dir}/host/usr/bin/bash:/usr/bin/bash:ro"
            --volume "${pseudo_native_dir}/host/usr/bin/dash:/usr/bin/dash:ro"
          )
        fi
        ;;
      volume)
        if [[ -z "${pseudo_native_pull}" ]]; then
          if [[ -n "${pseudo_native_image}" ]]; then
            pseudo_native_pull=1
          else
            pseudo_native_pull=0
          fi
        fi
        if [[ -n "${pseudo_native_image}" ]]; then
          case "${pseudo_native_pull}" in
            1|yes|true)
              docker pull --platform linux/amd64 "${pseudo_native_image}"
              ;;
            0|no|false)
              if ! docker image inspect "${pseudo_native_image}" >/dev/null 2>&1; then
                docker pull --platform linux/amd64 "${pseudo_native_image}"
              fi
              ;;
            *)
              echo "Unknown PSEUDO_NATIVE_PULL=${pseudo_native_pull}" >&2
              exit 2
              ;;
          esac
        elif ! pseudo_native_bundle_ready "${pseudo_native_dir}" || \
          [[ "${pseudo_native_host_tools}" -eq 1 ]]
        then
          PSEUDO_NATIVE_CACHE_DIR="${cache_root}" \
          PSEUDO_NATIVE_DIR="${pseudo_native_dir}" \
          PSEUDO_NATIVE_HOST_TOOLS="${PSEUDO_NATIVE_HOST_TOOLS:-all}" \
          PSEUDO_NATIVE_HOST_TOOL_LIST="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}" \
            "${repo_root}/tools/release_engineering/prepare_pseudo_native_toolchain.sh" \
            "${codename}" "${arch}"
        fi

        docker volume create "${pseudo_native_volume}" >/dev/null
        pseudo_native_volume_probe="test -x /mnt/bin/cc && "
        pseudo_native_volume_probe+="test \"\$(cat /mnt/.pseudo-native-format 2>/dev/null || true)\" = \"${pseudo_native_format_version}\""
        if [[ "${pseudo_native_host_tools}" -eq 1 ]]; then
          # Host tool requests can change between runs. Refresh the volume
          # conservatively so an older compiler-only bundle is not reused.
          pseudo_native_volume_probe=false
        fi
        if ! docker run --rm \
          --platform linux/amd64 \
          --volume "${pseudo_native_volume}:/mnt:ro" \
          "ubuntu:${codename}" \
          bash -lc "${pseudo_native_volume_probe}"
        then
          echo "==> Populating pseudo-native volume ${pseudo_native_volume}"
          if [[ -n "${pseudo_native_image}" ]]; then
            docker run --rm \
              --platform linux/amd64 \
              --volume "${pseudo_native_volume}:/out" \
              "${pseudo_native_image}" \
              bash -lc 'find /out -mindepth 1 -maxdepth 1 -exec rm -rf {} +; cp -a /opt/pseudo-native-toolchain/. /out/'
          else
            docker run --rm \
              --platform linux/amd64 \
              --volume "${pseudo_native_dir}:/src:ro" \
              --volume "${pseudo_native_volume}:/out" \
              "ubuntu:${codename}" \
              bash -lc 'find /out -mindepth 1 -maxdepth 1 -exec rm -rf {} +; cp -a /src/. /out/'
          fi
        fi

        pseudo_native_args=(
          --env PSEUDO_NATIVE_TOOLCHAIN=1
          --env PSEUDO_NATIVE_ROOT="${pseudo_native_root_in_container}"
          --env PSEUDO_NATIVE_HOST_TOOLS="${PSEUDO_NATIVE_HOST_TOOLS:-all}"
          --env PSEUDO_NATIVE_HOST_TOOL_LIST="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}"
          --volume "${pseudo_native_volume}:${pseudo_native_root_in_container}:ro"
        )
        ;;
      image)
        if [[ -z "${pseudo_native_image}" ]]; then
          echo "PSEUDO_NATIVE_IMAGE is required when storage=image" >&2
          exit 2
        fi
        if [[ -z "${pseudo_native_pull}" ]]; then
          pseudo_native_pull=1
        fi
        case "${pseudo_native_pull}" in
          1|yes|true)
            docker pull --platform linux/amd64 "${pseudo_native_image}"
            ;;
          0|no|false)
            if ! docker image inspect "${pseudo_native_image}" >/dev/null 2>&1; then
              docker pull --platform linux/amd64 "${pseudo_native_image}"
            fi
            ;;
          *)
            echo "Unknown PSEUDO_NATIVE_PULL=${pseudo_native_pull}" >&2
            exit 2
            ;;
        esac
        pseudo_native_root_in_container=/opt/pseudo-native-image/opt/pseudo-native-toolchain
        pseudo_native_args=(
          --env PSEUDO_NATIVE_TOOLCHAIN=1
          --env PSEUDO_NATIVE_ROOT="${pseudo_native_root_in_container}"
          --env PSEUDO_NATIVE_HOST_TOOLS="${PSEUDO_NATIVE_HOST_TOOLS:-all}"
          --env PSEUDO_NATIVE_HOST_TOOL_LIST="${PSEUDO_NATIVE_HOST_TOOL_LIST:-}"
          --mount "type=image,source=${pseudo_native_image},target=/opt/pseudo-native-image,readonly"
        )
        ;;
      *)
        echo "Unknown PSEUDO_NATIVE_STORAGE=${pseudo_native_storage}" >&2
        exit 2
        ;;
    esac
    pseudo_native_args+=(--env PSEUDO_NATIVE_BAZEL="${pseudo_native_bazel}")
  else
    pseudo_native_args=(
      --env PSEUDO_NATIVE_TOOLCHAIN=0
      --env PSEUDO_NATIVE_BAZEL=0
    )
  fi

  if [[ "${pseudo_native}" -eq 1 ]] && pseudo_native_shell_host_tools_requested; then
    if [[ "${#pseudo_native_shell_mount_args[@]}" -gt 0 ]]; then
      build_command=(
        /usr/bin/bash
        /work/drake/tools/release_engineering/build_deb_inside_docker.sh
      )
    else
      build_command=(
        "${pseudo_native_root_in_container}/lib64/ld-linux-x86-64.so.2"
        --library-path
        "${pseudo_native_root_in_container}/lib/x86_64-linux-gnu:${pseudo_native_root_in_container}/usr/lib/x86_64-linux-gnu"
        "${pseudo_native_root_in_container}/host/usr/bin/bash"
        /work/drake/tools/release_engineering/build_deb_inside_docker.sh
      )
    fi
  fi

  if [[ -z "${DRAKE_DEB_DOCKER_IMAGE:-}" && -z "${!image_var:-}" && -z "${!arch_image_var:-}" && -z "${!codename_image_var:-}" ]]; then
    echo "==> Building Docker base image ${image} for ${platform}"
    docker build \
      --platform "${platform}" \
      --build-arg "UBUNTU_CODENAME=${codename}" \
      --tag "${image}" \
      --file "${dockerfile}" \
      "${docker_context}"
  else
    echo "==> Using prebuilt Docker image ${image} for ${platform}"
  fi

  echo "==> Building Drake deb for ${codename}/${arch} using ${image}"

  docker run --rm "${tty_args[@]}" \
    --platform "${platform}" \
    --env DEBIAN_FRONTEND=noninteractive \
    --env DRAKE_DEB_CODENAME="${codename}" \
    --env DRAKE_DEB_ARCH="${arch}" \
    --env DRAKE_DEB_HOST_ARCH="${host_arch}" \
    --env DRAKE_DEB_DISABLE_PYCOMPILE="${DRAKE_DEB_DISABLE_PYCOMPILE:-auto}" \
    --env DRAKE_DEB_REUSE_BUILD_TREE="${DRAKE_DEB_REUSE_BUILD_TREE:-1}" \
    --env DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS="${DRAKE_DEB_BAZEL_QEMU_WORKAROUNDS:-auto}" \
    --env DRAKE_DEB_BAZEL_BATCH="${DRAKE_DEB_BAZEL_BATCH:-auto}" \
    --env DRAKE_DEB_BAZEL_JOBS="${DRAKE_DEB_BAZEL_JOBS:-}" \
    --env DRAKE_DEB_BAZEL_OUTPUT_BASE="/home/builder/.cache/bazel/output-base" \
    --env DRAKE_DEB_BAZEL_REPOSITORY_CACHE="/home/builder/.cache/bazel/repository-cache" \
    --env DRAKE_DEB_BAZEL_DISK_CACHE="/home/builder/.cache/bazel/disk-cache" \
    --env HOST_UID="$(id -u)" \
    --env HOST_GID="$(id -g)" \
    --volume "${repo_root}:/work/drake" \
    "${pseudo_native_args[@]}" \
    "${pseudo_native_host_tool_mount_args[@]}" \
    "${pseudo_native_shell_mount_args[@]}" \
    --volume "${output_dir}:/work/out" \
    --volume "${cache_dir}/apt:/var/cache/apt" \
    --volume "${cache_dir}/bazel:/home/builder/.cache/bazel" \
    --volume "${cache_dir}/bazelisk:/home/builder/.cache/bazelisk" \
    --workdir /work/drake \
    "${image}" \
    "${build_command[@]}"

  echo "==> ${codename}/${arch} artifacts are in ${output_dir}"
}

seen_codenames=" "
seen_arches=" "
unique_codenames=()
unique_arches=()
for target in "${codename_targets[@]}"; do
  if [[ "${seen_codenames}" == *" ${target} "* ]]; then
    continue
  fi
  seen_codenames+="${target} "
  unique_codenames+=("${target}")
done
for arch in "${arch_targets[@]}"; do
  if [[ "${seen_arches}" == *" ${arch} "* ]]; then
    continue
  fi
  seen_arches+="${arch} "
  unique_arches+=("${arch}")
done

for target in "${unique_codenames[@]}"; do
  for arch in "${unique_arches[@]}"; do
    run_build "${target}" "${arch}"
  done
done

echo "Debian package artifacts are under ${output_root}"

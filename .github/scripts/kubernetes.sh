#!/bin/bash

set -eux

readonly ARCH=${arch?}
readonly CRI_TYPE=${criType?}
readonly KUBE=${kubeVersion?}
readonly SEALOS=${sealoslatest?}

readonly IMAGE_HUB_REGISTRY=${registry?}
readonly IMAGE_HUB_REPO=${repo?}
readonly IMAGE_HUB_USERNAME=${username?}
readonly IMAGE_HUB_PASSWORD=${password?}
readonly IMAGE_CACHE_NAME="ghcr.io/labring-actions/cache"

ROOT="/tmp/$(whoami)/build"
PATCH="/tmp/$(whoami)/patch"
mkdir -p "$ROOT" "$PATCH"
downloadDIR="/tmp/$(whoami)/download"
binDIR="/tmp/$(whoami)/bin"

{
  BUILD_KUBE=$(sudo buildah from "$IMAGE_CACHE_NAME:kubernetes-v$KUBE-amd64")
  sudo cp -a "$(sudo buildah mount "$BUILD_KUBE")"/bin/kubeadm "/usr/bin/kubeadm"
  sudo buildah umount "$BUILD_KUBE"
  FROM_SEALOS=$(sudo buildah from "$IMAGE_CACHE_NAME:sealos-v$SEALOS-$ARCH")
  MOUNT_SEALOS=$(sudo buildah mount "$FROM_SEALOS")
  sudo chown -R "$(whoami)" "$MOUNT_SEALOS"
  FROM_KUBE=$(sudo buildah from "$IMAGE_CACHE_NAME:kubernetes-v$KUBE-$ARCH")
  MOUNT_KUBE=$(sudo buildah mount "$FROM_KUBE")
  sudo chown -R "$(whoami)" "$MOUNT_KUBE"
  FROM_CRIO=$(sudo buildah from "$IMAGE_CACHE_NAME:cri-v${KUBE%.*}-$ARCH")
  MOUNT_CRIO=$(sudo buildah mount "$FROM_CRIO")
  sudo chown -R "$(whoami)" "$MOUNT_CRIO"
  FROM_CRI=$(sudo buildah from "$IMAGE_CACHE_NAME:cri-$ARCH")
  MOUNT_CRI=$(sudo buildah mount "$FROM_CRI")
  sudo chown -R "$(whoami)" "$MOUNT_CRI"
}

if [[ -n "$sealosPatch" ]]; then
  BUILD_PATCH=$(sudo buildah from "$sealosPatch-$ARCH")
  rmdir "$PATCH"
  sudo cp -a "$(sudo buildah mount "$BUILD_PATCH")" "$PATCH"
  sudo chown -R "$USER:$USER" "$PATCH"
  sudo buildah umount "$BUILD_PATCH"
fi

cp -a rootfs/* "$ROOT"
cp -a "$CRI_TYPE"/* "$ROOT"
cp -a registry/* "$ROOT"

cd "$ROOT" && {
  mkdir -p bin
  mkdir -p opt
  mkdir -p registry
  mkdir -p images/shim
  mkdir -p cri/lib64

  # ImageList
  kubeadm config images list --kubernetes-version "$KUBE" 2>/dev/null >images/shim/DefaultImageList

  # library
  TARGZ="$MOUNT_CRI"/cri/library.tar.gz
  {
    cd bin && {
      tar -zxf "$TARGZ" library/bin --strip-components=2
      cd -
    }
    case $CRI_TYPE in
    containerd)
      cd cri/lib64 && {
        tar -zxf "$TARGZ" library/lib64 --strip-components=2
        mkdir -p lib
        mv libseccomp.* lib
        tar -czf containerd-lib.tar.gz lib
        rm -rf lib
        cd -
      }
      ;;
    esac
  }

  # cri
  case $CRI_TYPE in
  containerd)
    cp -a "$MOUNT_CRI"/cri/cri-containerd.tar.gz cri/
    ;;
  cri-o)
    cp -a "$MOUNT_CRIO"/cri/cri-o.tar.gz cri/
    ;;
  docker)
    case $KUBE in
    1.*.*)
      cp -a "$MOUNT_CRI"/cri/cri-dockerd.tgz cri/
      cp -a "$MOUNT_CRI"/cri/docker.tgz cri/
      cp -a "$MOUNT_CRIO"/cri/crictl.tar.gz cri/
      ;;
    esac
    ;;
  esac

  cp -a "$MOUNT_KUBE"/bin/kubeadm bin/
  cp -a "$MOUNT_KUBE"/bin/kubectl bin/
  cp -a "$MOUNT_KUBE"/bin/kubelet bin/
  cp -a "$MOUNT_CRI"/cri/registry cri/
  cp -a "$MOUNT_CRI"/cri/lsof opt/
  cp -a "$MOUNT_SEALOS"/sealos/image-cri-shim cri/
  cp -a "$MOUNT_SEALOS"/sealos/sealctl opt/
  if ! rmdir "$PATCH"; then
    cp -a "$PATCH"/* .
    ipvsImage="localhost:5000/labring/lvscare:$(find "registry" -type d | grep -E "tags/.+-$ARCH$" | awk -F/ '{print $NF}')"
    echo >images/shim/lvscareImage
  else
    ipvsImage="ghcr.io/labring/lvscare:v$SEALOS"
    echo "$ipvsImage" >images/shim/LvscareImageList
  fi

  # replace
  kube_major="${KUBE%.*}"
  if [[ "${kube_major//./}" -ge 126 ]]; then
    cri_shim_apiversion=v1
  else
    cri_shim_apiversion=v1alpha2
  fi
  cri_shim_tmpl="etc/image-cri-shim.yaml.tmpl"
  if [[ -s "$cri_shim_tmpl" ]]; then
    sed -i -E "s#^version: .+#version: $cri_shim_apiversion#g" "$cri_shim_tmpl"
  fi
  sed -i "s#__lvscare__#$ipvsImage#g;s/v0.0.0/v$KUBE/g" "Kubefile"
  pauseImage=$(grep /pause: images/shim/DefaultImageList)
  pauseImageName=${pauseImage#*/}
  sed -i "s#__pause__#${pauseImageName}#g" Kubefile
  # build
  case $CRI_TYPE in
  containerd)
    IMAGE_KUBE=kubernetes
    ;;
  cri-o)
    IMAGE_KUBE=kubernetes-crio
    ;;
  docker)
    IMAGE_KUBE=kubernetes-docker
    ;;
  esac

  if ! [[ "$SEALOS" =~ ^[0-9\.]+[0-9]$ ]] || [[ -n "$sealosPatch" ]]; then
    IMAGE_PUSH_NAME=(
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%.*}-$ARCH"
    )
  else
    if [[ "$SEALOS" == "$(
      until curl -sL "https://api.github.com/repos/labring/sealos/releases/latest"; do sleep 3; done | grep tarball_url | awk -F\" '{print $(NF-1)}' | awk -F/ '{print $NF}' | cut -dv -f2
    )" ]]; then
      IMAGE_PUSH_NAME=(
        "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v$KUBE-$ARCH"
        "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v$KUBE-$SEALOS-$ARCH"
      )
    else
      IMAGE_PUSH_NAME=(
        "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v$KUBE-$SEALOS-$ARCH"
      )
    fi
  fi

  chmod a+x bin/* opt/*

  echo -n >"$IMAGE_HUB_REGISTRY.images"
  for IMAGE_NAME in "${IMAGE_PUSH_NAME[@]}"; do
    if [[ "$allBuild" != true ]]; then
      case $IMAGE_HUB_REGISTRY in
      docker.io)
        if until curl -sL "https://hub.docker.com/v2/repositories/$IMAGE_HUB_REPO/$IMAGE_KUBE/tags/${IMAGE_NAME##*:}"; do sleep 3; done |
          grep digest >/dev/null; then
          echo "$IMAGE_NAME already existed"
        else
          echo "$IMAGE_NAME" >>"$IMAGE_HUB_REGISTRY.images"
        fi
        ;;
      *)
        echo "$IMAGE_NAME" >>"$IMAGE_HUB_REGISTRY.images"
        ;;
      esac
    else
      echo "$IMAGE_NAME" >>"$IMAGE_HUB_REGISTRY.images"
    fi
  done

  IMAGE_BUILD="$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:build-$(date +%s)"
  if [[ -s "$IMAGE_HUB_REGISTRY.images" ]]; then
    sudo cp -a "$MOUNT_KUBE"/registry .
    sudo sealos build -t "$IMAGE_BUILD" --platform "linux/$ARCH" -f Kubefile .
    while read -r IMAGE_NAME; do
      sudo sealos tag "$IMAGE_BUILD" "$IMAGE_NAME"
      sudo sealos login -u "$IMAGE_HUB_USERNAME" -p "$IMAGE_HUB_PASSWORD" "$IMAGE_HUB_REGISTRY" &&
        sudo sealos push "$IMAGE_NAME" && echo "$IMAGE_NAME push success"
    done <"$IMAGE_HUB_REGISTRY.images"
    sudo sealos images
  fi
}

for obj in $(env | grep ^FROM_); do
  sudo buildah umount "$obj" || true
done

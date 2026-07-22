#!/usr/bin/env -S bash -x
set -euo pipefail
cd "$(dirname -- "$BASH_SOURCE")"

cd ..

BASH_TAB_ROOT=$PWD
IMAGES_DIR=$BASH_TAB_ROOT/images
IMAGE_NAME=bashtab-v86
CONTAINER_NAME=bashtab-v86-temp

rm -r images

sudo env HTTP_PROXY="$HTTP_PROXY" HTTPS_PROXY="$HTTPS_PROXY" \
    docker build \
    --build-arg "HTTP_PROXY=$HTTP_PROXY" \
    --build-arg "HTTPS_PROXY=$HTTPS_PROXY" \
    --platform linux/386 \
    --rm \
    --tag "$IMAGE_NAME" \
    --file docker/Dockerfile \
    .

sudo docker rm "$CONTAINER_NAME" || true
mkdir -p "$IMAGES_DIR"
sudo docker create --platform linux/386 -t -i --name "$CONTAINER_NAME" "$IMAGE_NAME"
sudo docker export "$CONTAINER_NAME" -o "$IMAGES_DIR"/alpine-bashtab-rootfs.tar
sudo chown "$USER":"$USER" "$IMAGES_DIR"/alpine-bashtab-rootfs.tar
sudo docker rm "$CONTAINER_NAME"

tar -f "$IMAGES_DIR"/alpine-bashtab-rootfs.tar --delete .dockerenv || true

mkdir "$IMAGES_DIR"/alpine-bashtab-rootfs-flat

python3 v86/tools/fs2json.py --zstd --out "$IMAGES_DIR"/alpine-bashtab-fs.json "$IMAGES_DIR"/alpine-bashtab-rootfs.tar
python3 v86/tools/copy-to-sha256.py --zstd "$IMAGES_DIR"/alpine-bashtab-rootfs.tar "$IMAGES_DIR"/alpine-bashtab-rootfs-flat

rm "$IMAGES_DIR"/alpine-bashtab-rootfs.tar

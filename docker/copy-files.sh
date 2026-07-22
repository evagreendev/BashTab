#!/usr/bin/env bash
set -euo pipefail

BASH_TAB_DEMO_DIR=$(realpath -- "$1")

cd "$(dirname -- "$BASH_SOURCE")"

cd ..

BASH_TAB_DIR=$PWD

if [[ -z "$BASH_TAB_DEMO_DIR" ]]
then
    echo "\$1: demo dir required"
    exit 1
fi

if [[ "$BASH_TAB_DEMO_DIR" != *BashTabDemo* ]]
then
    echo "$BASH_TAB_DEMO_DIR doesn't look like the demo dir"
    exit 1
fi

if [[ ! -f images/alpine-bashtab-fs.json ]]
then
    echo "Index missing, please build images"
    exit 1
fi

if [[ ! -d images/alpine-bashtab-rootfs-flat ]]
then
    echo "Rootfs missing, please build images"
    exit 1
fi

if [[ -e "$BASH_TAB_DEMO_DIR"/images ]]
then
    rm -r "$BASH_TAB_DEMO_DIR"/images
fi

cp -r images/ "$BASH_TAB_DEMO_DIR"

if [[ ! -e "$BASH_TAB_DEMO_DIR"/bios && -e v86/bios ]]
then
    mkdir "$BASH_TAB_DEMO_DIR"/bios
    cp v86/bios/seabios.bin v86/bios/vgabios.bin "$BASH_TAB_DEMO_DIR"/bios
fi


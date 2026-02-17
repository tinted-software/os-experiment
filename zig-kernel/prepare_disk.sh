#!/usr/bin/env sh
set -e

CACHE_DIR="/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"
IMG_NAME="shared_cache.img"

echo "Creating disk root..."
mkdir -p disk_root/System/Library/dyld
mkdir -p disk_root/bin

echo "Copying shared cache files..."
cp $CACHE_DIR/dyld_shared_cache_x86_64* disk_root/System/Library/dyld/
cp /bin/zsh disk_root/bin/

echo "Creating CPIO archive..."
cd disk_root && find . | cpio -o -H newc > ../$IMG_NAME
cd ..

echo "Disk image $IMG_NAME created."
ls -lh $IMG_NAME

#!/bin/env sh

remounter() {
	{ umount -d "$TEMP" || umount -d -l "$TEMP"; } 2> /dev/null
	mv ${1%.img}_ext4.img $1
	resize2fs -f -M $1
	loop=$(losetup -f || losetup -f)
	losetup $loop $1
	mount $loop "$TEMP"
}

erofs_converter_by_extract() {
	part_name=${1%.img}
	extract.erofs -T ${CPU:-1} -i $1 -x -o "$TEMP"
	make_ext4fs -S "$TEMP"/config/${part_name}_file_contexts -C "$TEMP"/config/${part_name}_fs_config -l 8912896000 -L $part_name -a $part_name ${part_name}_ext4.img "$TEMP"/$part_name || { rm -rf "$TEMP"/*; exit 1; }
	remounter $1
}

fs_converter() {
	part_name=${1%.img}
	fallocate -l 7000M ${part_name}_ext4.img
	mke2fs -F -d "$TEMP" ${part_name}_ext4.img
	remounter $1
}

set -x

case $1 in
	erofs)
		if [ $LINUX -eq 1 ]; then
		    fuse.erofs $2 "$TEMP"
		    fs_converter $2
		else
		    erofs_converter_by_extract $2
		fi
		;;
	other) fs_converter $2;;
esac

#!/bin/env sh

trap "{ umount $TEMP $TEMP2 || umount -l $TEMP $TEMP2; losetup -D; } 2>/dev/null" EXIT

calc(){ awk 'BEGIN{ print int('"$1"') }'; }

erofs_converter_by_extract() {
	part_name=${1%.img}
	extract.erofs -T ${CPU:-1} -i $1 -x -o "$TEMP"
	make_ext4fs -S "$TEMP"/config/${part_name}_file_contexts -C "$TEMP"/config/${part_name}_fs_config -l 8912896000 -L $part_name -a $part_name $1 "$TEMP"/$part_name || exit 1
	resize2fs -f -M $1
}

erofs_converter_by_mount() {
	part_name=${1%.img}
	erofsfuse $1 "$TEMP"
	root_context=$(ls -d -Z "${TEMP}" | sed "s|$TEMP|$TEMP2|")
	fallocate -l 8000M ${part_name}_ext4.img
	mkfs.ext4 ${part_name}_ext4.img
	mount ${part_name}_ext4.img "$TEMP2"
	chcon -h $(echo ${root_context})
	cp -ra "$TEMP"/* "$TEMP2"
	total_size=$(df -B1 --output=size "$TEMP2" | grep -o "^[0-9]*")
	space_size=$(df -B1 --output=avail "$TEMP2" | grep -o "[0-9]*")
	mv ${part_name}_ext4.img $1
	umount "$TEMP" "$TEMP2"
	sh $HOME/pay2sup_helper.sh shrink $1 || true
}

case $1 in
	convert)
		if [[ $LINUX == 1 ]]; then
		    erofs_converter_by_mount $2
		else
		    erofs_converter_by_extract $2
		fi
		;;
esac

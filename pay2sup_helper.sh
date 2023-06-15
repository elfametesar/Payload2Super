#!/bin/env sh

trap "{ umount $TEMP || umount -l $TEMP; losetup -D; rm -rf $HOME/kernel_patching; } 2> /dev/null" EXIT

failure() {
  local lineno=$1
  local msg=$2
  echo "Failed at $lineno: $0: $msg" >> $LOG_FILE
}

trap 'failure ${LINENO} "$BASH_COMMAND"' ERR

calc(){ awk 'BEGIN{ printf "%.0f\n", '"$1"' }'; }

shrink() {
	for img in "$@"; do
		total_size=$(tune2fs -l "$img" | awk -F: '/Block count/{count=$2} /Block size/{size=$2} END{print count*size}')
        	used_size=$(tune2fs -l "$img" | awk -F: '/Free blocks/{count=$2} /Block size/{size=$2} END{print '$total_size'-count*size}')
		used_size=$(( used_size/1024/1024))M
		resize2fs -f "$img" $used_size 2> /dev/null 
		resize2fs -f -M "$img" 2> /dev/null 
		e2fsck -fy "$img"
	done
}

get_sizes() {
	super_size=$( calc $1/1024/1024 )
	for img in $PARTS; do
		size=$(tune2fs -l $img | awk -F: '/Block count/{count=$2} /Block size/{size=$2} END{print count*size}')
		size=$( calc $size/1024/1024 )
		echo -e "${img%.img}\t${size}M"
		sum=$( calc $sum+$size )
	done
	echo -e "\nSuper block size is ${super_size}M.\n"
	if (( super_size-sum < 0 )); then
		echo -e "\nPartition sizes exceed the super block size. Program cannot continue. You need to debloat the images you can find in $PWD or convert back to EROFS in order to continue.\n" 1>&2
		exit 1
	fi
	echo "Free space you can distribute is $( calc $super_size-$sum )Mb"
	echo
	echo $( calc $super_size-$sum ) > empty_space
}

add_space() {
	if [[ $PARTS == *$1* ]]; then
		bytes=$(stat -c%s $1)
		megabytes=$( calc $bytes/1024/1024 )
		total=$( calc $megabytes+$2 )
		echo "Size of the $1 was ${megabytes}Mb"
		fallocate -l "${total}M" $1 && echo -e "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb\n" || echo "Something went wrong"
		resize2fs -f $1 1> /dev/null
	fi
}

remove_overlay() {
	magiskboot hexpatch "HOME"/extracted/vendor.img "0A6F7665726C6179" "0A2320202020206f7665726c6179"
}

disable_encryption() {
	echo -e "Disabling Android file encryption system...\n"
	encryption_hexes="2C66696C65656E6372797074696F6E3D6165732D3235362D7874733A6165732D3235362D6374733A76322B696E6C696E6563727970745F6F7074696D697A65642B777261707065646B65795F7630\
		2c66696c65656e6372797074696f6e3d6165732d3235362d7874733a6165732d3235362d6374733a76322b656d6d635f6f7074696d697a65642b777261707065646b65795f7630\
	       	2c6d657461646174615f656e6372797074696f6e3d6165732d3235362d7874733a777261707065646b65795f7630\
	       	2c6b65796469726563746f72793d2f6d657461646174612f766f6c642f6d657461646174615f656e6372797074696f6e\
	       	2c66696c65656e6372797074696f6e3d6165732d3235362d7874733a6165732d3235362d6374733a76322b696e6c696e6563727970745f6f7074696d697a6564\
	       	2c656e637279707461626c653d6165732d3235362d7874733a6165732d3235362d6374733a76322b5f6f7074696d697a6564\
	       	2c656e637279707461626c653d6165732d3235362d7874733a6165732d3235362d6374733a76322b696e6c696e6563727970745f6f7074696d697a65642b777261707065646b65795f7630\
	       	696e6c696e656372797074\
	       	2c777261707065646b6579\
	       	2c656e637279707461626c653d666f6f746572"
	for hex in $encryption_hexes; do
		magiskboot hexpatch "HOME"/extracted/vendor.img $hex ""
	done
	echo -e "Android file encryption system has been disabled succesfully\n"
	sleep 2
}

kernel_patch() {
	mkdir "$HOME"/kernel_patching
	cd "$HOME"/kernel_patching
	image="$1"
	magiskboot unpack $image || exit 1
	magiskboot hexpatch ramdisk.cpio "20202065726F6673" "20202065787434"
	magiskboot repack "$image" "${image##*/}"
	mv "${image##*/}" "$image"
	rm -rf "$HOME"/kernel_patching
}

restore_secontext() {
	for img in $PARTS; do
		[[ -f $HOME/${img%.img}_context && -s $HOME/${img%.img}_context ]] || continue
		loop=$(losetup -f)
		losetup $loop "$img"
		mount -o rw $loop "$TEMP" || continue
		while read line; do
			[[ -z $line ]] && break
			context="$(grep $line$ $HOME/${img%.img}_context)"
			[[ $context == "" ]] && continue
			chcon -h $context
		done <<< "$(find $TEMP -exec $BUSYBOX ls -dZ {} + | awk '/(unlabeled|\?)/ {print $2}')"
		{ umount "$TEMP" || umount -l "$TEMP"; } 2> /dev/null
		losetup -D
	done
}

preserve_secontext() {
	for img in $PARTS; do
		[[ -f $HOME/${img%.img}_context && -s $HOME/${img%.img}_context ]] && continue 
		loop=$(losetup -f)
		losetup $loop $img
		mount -o ro $loop "$TEMP" || continue
		find "$TEMP" -exec $BUSYBOX ls -d -Z {} + > "$HOME"/${img%.img}_context
		{ umount "$TEMP" || umount -l "$TEMP"; } 2> /dev/null
		losetup -D
	done
}

case $1 in
	"shrink") shift; shrink "$@";;
	"get") get_sizes $2;;
	"expand") add_space $2 $3;;
	"dfe") disable_encryption;;
	"remove_overlay") remove_overlay;;
	"preserve_secontext") preserve_secontext;;
	"restore_secontext") restore_secontext;;
	"patch_kernel") kernel_patch $2;;
esac

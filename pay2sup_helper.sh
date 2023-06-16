#!/bin/env sh

trap "{ umount $TEMP || umount -l $TEMP; losetup -D; rm -rf $HOME/kernel_patching; } 2> /dev/null" EXIT

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
		printf "%s\t%s\n" "${img%.img}" "${size}M"
		sum=$( calc $sum+$size )
	done
	echo
	echo "Super block size is ${super_size}M."
	echo
	if [ $((super_size-sum)) -lt 0 ]; then
		echo
		echo "Partition sizes exceed the super block size."
		exit 1
	fi
	echo "Free space you can distribute is $( calc $super_size-$sum )Mb"
	echo
	echo $( calc $super_size-$sum ) > empty_space
}

add_space() {
	case $PARTS in *$1*)
		bytes=$(stat -c%s $1)
		megabytes=$( calc $bytes/1024/1024 )
		total=$( calc $megabytes+$2 )
		echo "Size of the $1 was ${megabytes}Mb"
		fallocate -l "${total}M" $1 && echo "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb" && echo || echo "Something went wrong"
		resize2fs -f $1 1> /dev/null;;
	esac
}

mount_vendor() {
	vendor="$HOME"/extracted/vendor.img
	fallocate -l $( calc $(stat -c%s "$vendor")+52428800) "$vendor"
	resize2fs -f "$vendor" &> /dev/null
	loop=$(losetup -f)
	losetup $loop "$vendor"
	mount $loop "$TEMP" || \
		{ echo "Program cannot mount vendor, therefore cannot disable file encryption."; echo; return 1; }
	fstab_contexts="$($TOYBOX ls -Z $TEMP/etc/fstab*)"
}

unmount_vendor() {
	umount "$TEMP" || umount -l "$TEMP"
	losetup -D
}

remove_overlay() {
	mount_vendor
	sed -i 's/^overlay/# overlay/' "$TEMP"/etc/fstab*
	echo "$fstab_contexts" | while read context file; do
		chcon $context $file
	done
	unmount_vendor
	shrink "$vendor" 1> /dev/null
}

disable_encryption() {
	mount_vendor
	echo "Disabling Android file encryption system..."
	echo
	sed -i 's|,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0||;
		s|,fileencryption=aes-256-xts:aes-256-cts:v2+emmc_optimized+wrappedkey_v0||;
               	s|,metadata_encryption=aes-256-xts:wrappedkey_v0||;
               	s|,keydirectory=/metadata/vold/metadata_encryption||;
               	s|,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized||;
               	s|,encryptable=aes-256-xts:aes-256-cts:v2+_optimized||;
               	s|,encryptable=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0||;
               	s|,quota||;s|inlinecrypt||;s|,wrappedkey||;s|,encryptable=footer||' "$TEMP"/etc/fstab*
	echo "$fstab_contexts" | while read context file; do
		chcon $context $file
	done
	unmount_vendor
	echo "Android file encryption system has been disabled succesfully"
	echo
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
		[ -f "$HOME/${img%.img}_context" ] && [ -s "$HOME/${img%.img}_context" ] || continue
		loop=$(losetup -f)
		losetup $loop "$img"
		mount -o rw $loop "$TEMP" || continue
		find $TEMP -exec $TOYBOX ls -dZ {} + | awk '/(unlabeled|\?)/ {print $2}' | while read line; do
			[ -z "$line" ] && break
			case "$line" in *\[) line="${line%[}\[";; esac
			context="$(grep $line$ $HOME/${img%.img}_context)"
			[ -z "$context" ] && continue
			chcon -h $context
		done 
		{ umount "$TEMP" || umount -l "$TEMP"; } 2> /dev/null
		losetup -D
	done
}

preserve_secontext() {
	for img in $PARTS; do
		[ -f "$HOME/${img%.img}_context" ] && [ -s "$HOME/${img%.img}_context" ] && continue 
		loop=$(losetup -f)
		losetup $loop $img
		mount -o ro $loop "$TEMP" || continue
		find "$TEMP" -exec $TOYBOX ls -d -Z {} + > "$HOME"/${img%.img}_context
		{ umount "$TEMP" || umount -l "$TEMP"; } 2> /dev/null
		losetup -D
	done
}

debloat() {
	debloat_list="$1"
	debloated_folder="$HOME/debloated_packages"
	[ -f "$debloat_list" ] || return
	[ -d "$debloated_folder" ] || mkdir "$debloated_folder"
	for img in $PARTS; do
		echo "Debloating the partition ${img%.img}"
		echo
		loop=$(losetup -f)
		losetup $loop $img
		mount $loop "$TEMP"
		find "$TEMP" -name "*.apk" | while read line; do
	        	 app="${line##*/}"
			 app="${app%.apk}"
			 grep -i -E -q "$app(.apk|$)" "$debloat_list" && mv "$line" "$debloated_folder"
		done
		{ umount "$TEMP" || umount -l "$TEMP"; losetup -D; } 2> /dev/null
	done
}

set -x

case $1 in
	"shrink") shift; shrink "$@";;
	"get") get_sizes $2;;
	"expand") add_space $2 $3;;
	"dfe") disable_encryption;;
	"remove_overlay") remove_overlay;;
	"preserve_secontext") preserve_secontext;;
	"restore_secontext") restore_secontext;;
	"patch_kernel") kernel_patch $2;;
	"debloat") debloat "$2";;
esac

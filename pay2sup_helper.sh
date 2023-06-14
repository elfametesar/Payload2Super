#!/bin/env sh

trap "{ umount $TEMP || umount -l $TEMP; losetup -D; } 2> /dev/null" EXIT
calc(){ awk 'BEGIN{ print int('"$1"') }'; }

shrink() {
	for img in "$@"; do
		total_size=$(dumpe2fs -h "$img" | awk -F: '/Block count/{count=$2} /Block size/{size=$2} END{print count*size}')
        	used_size=$(dumpe2fs -h "$img" | awk -F: '/Free blocks/{count=$2} /Block size/{size=$2} END{print '$total_size'-count*size}')
		used_size=$(( used_size/1024/1024))M
		resize2fs -f "$img" $used_size 2> /dev/null 
		resize2fs -f -M "$img" 2> /dev/null 
		e2fsck -fy "$img"
	done
}

get_sizes() {
	super_size=$( calc $1/1024/1024 )
	for img in $PARTS; do
		size=$(dumpe2fs -h $img | awk -F: '/Block count/{count=$2} /Block size/{size=$2} END{print count*size}')
		size=$( calc $size/1024/1024 )
		echo -e "${img%.img}\t${size}M"
		sum=$( calc $sum+$size )
	done
	echo -e "\nSuper block size is ${super_size}M.\n"
	echo -e "Free space: $( calc $super_size-$sum )\n"
	if (( super_size-sum < 0 )); then
		echo -e "\nPartition sizes exceed the super block size. Program cannot continue. You need to debloat the images you can find in $PWD or convert back to EROFS in order to continue.\n" 1>&2
		exit 1
	fi
	echo
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

mount_vendor() {
	vendor=$HOME/extracted/vendor.img
	fallocate -l $( calc $(stat -c%s $vendor)+52428800) $vendor
	resize2fs -f $vendor &> /dev/null
	loop=$(losetup -f)
	losetup $loop $vendor
	mount $loop $TEMP || \
		{ echo -e "Program cannot mount vendor, therefore cannot disable file encryption.\n"; return 1; }
}

unmount_vendor() {
	umount "$TEMP" || umount -l "$TEMP"
	losetup -D
}

remove_overlay() {
	mount_vendor
	sed -i 's/^overlay/# overlay/' $TEMP/etc/fstab*
	unmount_vendor
	shrink $vendor 1> /dev/null
}

disable_encryption() {
	mount_vendor
	echo -e "Disabling Android file encryption system...\n"
	sed -i 's|,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0||;
		s|,fileencryption=aes-256-xts:aes-256-cts:v2+emmc_optimized+wrappedkey_v0||;
               	s|,metadata_encryption=aes-256-xts:wrappedkey_v0||;
               	s|,keydirectory=/metadata/vold/metadata_encryption||;
               	s|,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized||;
               	s|,encryptable=aes-256-xts:aes-256-cts:v2+_optimized||;
               	s|,encryptable=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0||;
               	s|,quota||;s|inlinecrypt||;s|,wrappedkey||;s|,encryptable=footer||' $TEMP/etc/fstab*
	unmount_vendor
	echo -e "Android file encryption system has been disabled succesfully\n"
	sleep 2
}

restore_secontext() {
	for img in $PARTS; do
		[[ -f "$HOME/${img%.img}_context" && -s "$HOME/${img%.img}_context" ]] || continue
		loop=$(losetup -f)
		losetup $loop $img
		mount -o rw $loop $TEMP || continue
		
		while read line; do
			[[ -z $line ]] && break
			context=$(grep "$line" $HOME/${img%.img}_context)
			chcon -h $(echo "$context") 2> /dev/null
		done <<< "$(find "$TEMP" -exec ls -dZ {} + | awk '/(unlabeled|\?)/ {print $2}')"
		{ umount "$TEMP" || umount -l "$TEMP"; } 2> /dev/null
		losetup -D
	done
}

preserve_secontext() {
	for img in $PARTS; do
		[[ -f "$HOME/${img%.img}_context" && -s "$HOME/${img%.img}_context" ]] && continue 
		loop=$(losetup -f)
		losetup $loop $img
		mount -o ro $loop $TEMP || continue
		find $TEMP -exec ls -d -Z {} + > $HOME/${img%.img}_context
		{ umount $TEMP || umount -l $TEMP; } 2> /dev/null
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
esac

#!/bin/env sh

trap "{ umount $TEMP || umount -l $TEMP; losetup -D; } 2> /dev/null" EXIT
calc(){ awk 'BEGIN{ print int('"$1"') }'; }

shrink() {
	for img in "$@"; do
		loop=$(losetup -f)
		losetup $loop $img
		mount $loop $TEMP || { echo -e "There was a problem shrinking $img, skipping\n" 1>&2; continue; }
		total_size=$($BUSYBOX df -B1 $TEMP | awk 'END{print $2}')
        	space_size=$($BUSYBOX df -B1 $TEMP | awk 'END{print $4}')
		umount $TEMP || umount -l $TEMP
		losetup -D
		[[ $space_size == 0 ]] && continue
		shrink_space=$(calc $total_size-$space_size)
		shrink_space=$(calc $shrink_space/1024/1024)
		resize2fs -f $img ${shrink_space}M 2> /dev/null || while true; do
			(( count++ ))
			shrink_space=$( calc "$shrink_space+5" )
			resize2fs -f $img ${shrink_space}M 2> /dev/null && break
			(( count == 30 )) && break
		done
		e2fsck -fy $img
	done
}

get_sizes() {
	super_size=$( calc $1/1024/1024 )
	for img in $PARTS; do
		size=$(stat -c%s $img)
		size=$( calc $size/1024/1024 )
		echo -e "${img%.img}\t${size}M"
		sum=$( calc $sum+$size )
	done
	echo -e "\nSuper block size is ${super_size}M.\n"
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

remove_overlay() {
	mount_vendor
	sed -i 's/^overlay/# overlay/' $TEMP/etc/fstab*
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
        losetup -D
	fallocate -l $( calc $(stat -c%s $vendor)-52428800) $vendor
	resize2fs -f $vendor &> /dev/null
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
			chcon -h $(echo "$line")
		done < "$HOME"/${img%.img}_context
		{ umount $TEMP || umount -l $TEMP; } 2> /dev/null
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

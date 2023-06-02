#!/bin/env sh

trap "umount $TEMP $TEMP2 2> /dev/null" EXIT
calc(){ awk 'BEGIN{ print int('"$1"') }'; }

shrink() {
	for img in "$@"; do
		mount $img $TEMP
		total_size=$($BUSYBOX df -B1 $TEMP | awk 'END{print $2}')
        	space_size=$($BUSYBOX df -B1 $TEMP | awk 'END{print $4}')
		umount $TEMP
		shrink_space=$(calc $total_size-$space_size)
		shrink_space=$(calc $shrink_space/1024/1024+50)
		while ! resize2fs -f $img ${shrink_space}M; do
			shrink_space=$( calc "$shrink_space+5" )
			resize2fs -f $img ${shrink_space}M
		done
		e2fsck -fy $img
	done
}

get_sizes() {
	super_size=$( calc $1/1024/1024 )
	for img in *.img; do
		case $img in
			system*.img|vendor.img|product.img|odm.img)
				size=$(stat -c%s $img)
				size=$( calc $size/1024/1024 )
				echo -e "${img%.img/}\t${size}M"
				sum=$( calc $sum+$size );;
		esac
	done
	if (( super_size-sum < 0 )); then
		echo -e "\nPartition sizes exceed the super block size. Program cannot continue."
		exit 1
	fi
	echo
	echo "Free space you can distribute is $( calc $super_size-$sum )Mb"
	echo
}

add_space() {
	case $1 in
			 odm*)
				bytes=$(stat -c%s $1)
				megabytes=$( calc $bytes/1024/1024 )
				total=$( calc $megabytes+$2 )
				echo "Size of the $1 was ${megabytes}Mb"
				fallocate -l "${total}M" $1 && echo -e "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb\n" || echo "Something went wrong"
				resize2fs -f $1 1> /dev/null;;
	
			 product*)
				bytes=$(stat -c%s $1)
				megabytes=$( calc $bytes/1024/1024 )
				total=$( calc $megabytes+$2 )
				echo "Size of the $1 was ${megabytes}Mb"
				fallocate -l "${total}M" $1 && echo -e "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb\n" || echo "Something went wrong"
				resize2fs -f $1 1> /dev/null;;
			 system*)
				bytes=$(stat -c%s $1)
				megabytes=$( calc $bytes/1024/1024 )
				total=$( calc $megabytes+$2 )
				echo "Size of the $1 was ${megabytes}Mb"
				fallocate -l ${total}M $1 && echo -e "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb\n" || echo "Something went wrong"
				resize2fs -f $1 1> /dev/null;;
			 system_ext*)
				bytes=$(stat -c%s $1)
				megabytes=$( calc $bytes/1024/1024 )
				total=$( calc $megabytes+$2 )
				echo "Size of the $1 was ${megabytes}Mb"
				fallocate -l ${total}M $1 && echo -e "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb\n" || echo "Something went wrong"
				resize2fs -f $1 1> /dev/null;;
			 vendor*)
				bytes=$(stat -c%s $1)
				megabytes=$( calc $bytes/1024/1024 )
				total=$( calc $megabytes+$2 )
				echo "Size of the $1 was ${megabytes}Mb"
				fallocate -l ${total}M $1 && echo -e "New size of the ${1%.img} is $( calc $(stat -c%s $1)/1024/1024 )Mb\n" || echo "Something went wrong"
				resize2fs -f $1 1> /dev/null;;
	esac
}

disable_encryption() {
	vendor=$HOME/extracted/vendor.img
	fallocate -l $( calc $(stat -c%s $vendor)+52428800) $vendor
	resize2fs -f $vendor &> /dev/null
	mount $vendor $TEMP || \
		{ echo -e "Program cannot mount vendor, therefore cannot disable file encryption.\n"; return 1; }

	echo -e "Disabling Android file encryption system...\n"
	sed -i 's|,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0||;
                s|,metadata_encryption=aes-256-xts:wrappedkey_v0||;
                s|,keydirectory=/metadata/vold/metadata_encryption||;
                s|,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized||;
                s|,encryptable=aes-256-xts:aes-256-cts:v2+_optimized||;
                s|,encryptable=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0||;
                s|,quota||;s|inlinecrypt||;s|,wrappedkey||' $1 
	umount $TEMP || umount -l $TEMP
	fallocate -l $( calc $(stat -c%s $vendor)-52428800) $vendor
	resize2fs -f $vendor &> /dev/null
	echo -e "Android file encryption system has been disabled succesfully\n"
	sleep 2
}

case $1 in
	"shrink") shift; shrink "$@";;
	"get") get_sizes $2;;
	"expand") add_space $2 $3;;
	"dfe") disable_encryption $TEMP/etc/fstab.qcom;;
esac

#!/bin/env sh

export PATH="$PWD/bin:$PATH"
export HOME="$PWD"
export LINUX=0
export LOG_FILE="$HOME/pay2sup.log"
export OUT=/sdcard/Payload2Super
export GRANT_RW=0
export RESIZE=0
export READ_ONLY=0
export EROFS=0
export DFE=0
export TEMP="$HOME"/tmp
export TEMP2="$HOME"/tmp2
export BACK_TO_EROFS=0
export RECOVERY=0

trap "exit" INT
trap "{ umount $TEMP || umount -l $TEMP; losetup -D; sed -i 's/+/[ DEBUG ]/g' $LOG_FILE; } 2> /dev/null" EXIT

[ "$PWD" = "/" ] && { echo "Working directory cannot be the root of your file system, it is dangerous"; exit 1; }

[ $(id -u) -eq 0 ] || {
	echo "Program must be run as the root user, use sudo -E on Linux platforms and su for Android"
	exit
}

TOOLCHAIN="make_ext4fs \
	mkfs.erofs \
	magiskboot \
	toybox \
	pigz \
	7z \
	dump.erofs \
	fuse.erofs \
	extract.erofs \
	lpmake \
	lpunpack \
	payload-dumper \
	adb"

toolchain_check() {
	[ -d "$HOME/bin" ] && chmod +x -R "$HOME"/bin || toolchain_download
	echo "Checking the toolchain integrity"
	echo
	for tool in $TOOLCHAIN; do
		if [ -f "$HOME/bin/$tool" ]; then
			continue
		else
			[ $tool = "adb" ] && [ $LINUX = 0 ] && continue
			[ $tool = "toybox" ] && [ $LINUX -eq 1 ] && continue
			missing="$missing $tool "
		fi
	done
	[ -z "$missing" ] || { \
		echo "$missing tool(s) missing in path, re-run the script to renew the toolchain."
		rm -rf "$HOME"/bin
		exit 1
	}
}

cleanup() { 
	rm -rf "$HOME"/extracted "$HOME"/flashable "$HOME"/super* "$HOME"/empty_space "$HOME"/*_context
}

get_os_type() {
	# I have no choice but to check for /usr :(
	if [ -d "/usr" ]; then
		export LINUX=1
		export OUT=~
	else
		[ -d "/sdcard" ] && [ ! -d "$OUT" ] && mkdir "$OUT"
		export TOYBOX=toybox
	fi
}

get_partitions() {
	vendor="$HOME"/extracted/vendor.img
	if dump.erofs "$vendor" >/dev/null 2>&1; then
		fuse.erofs "$vendor" "$TEMP" 1> /dev/null
	else
		7z e "$vendor" "etc/fstab*" 1> /dev/null
		FSTABS=$(sed 's/\x0/ /g' fstab*)
		rm -f fstab*
	fi
	[ -z "$FSTABS" ] && FSTABS="$(cat $TEMP/etc/fstab*)"
	[ -z "$FSTABS" ] && { echo "Partition list cannot be retrieved, this is a fatal error, exiting..."; exit 1; }
	PART_LIST=$(\
		echo "$FSTABS" | awk '!seen[$2]++ &&\
        !/\/data|\/metadata|\/boot|\/vendor_boot|\/recovery|\/init_boot|\/dtbo|\/cache|\/misc|\/oem|\/persist/ &&\
        $2 ~ /^\/[a-z]*(_|[a-z])*[^/]$/ {
                gsub("/","")
                printf "%s.img ", $2
	}')
	for img in "$HOME"/extracted/*.img; do
		case $PART_LIST in *${img##*/}* ) export PARTS="$PARTS ${img##*/} "; esac
	done
	{ umount "$TEMP" || umount -l "$TEMP"; } 2> /dev/null
}

toolchain_download() {
	[ -d "$HOME/bin" ] && chmod +x -R "$HOME/bin" && return
	if [ $LINUX -eq 0 ]; then
		   URL="https://github.com/elfametesar/uploads/raw/main/toolchain_android_arm64.tar"
	else
		   URL="https://github.com/elfametesar/uploads/raw/main/toolchain_linux_x64.tar"
	fi	
	echo "Downloading toolchain"
	curl -k -L $URL -o ${URL##*/} 1> /dev/null
	echo "Extracting toolchain"
	echo
	mkdir "$HOME"/bin
	tar xf ${URL##*/} -C "$HOME"/bin/
	rm ${URL##*/}
}


calc(){ awk 'BEGIN{ printf "%.0f\n", '"$1"' }'; }

grant_rw(){
	img_size=$(stat -c%s $1)
	new_size=$(calc $img_size*1.25/512)
	resize2fs -f $1 ${new_size}s
	e2fsck -y -E unshare_blocks $1
	resize2fs -f -M $1
	resize2fs -f -M $1
	
	img_size=$(stat -c%s $1)
	new_size=$(calc "($img_size+20*1024*1024)/512")
	resize2fs -f $1 ${new_size}s
	[ $RESIZE -eq 1 ] && {
		resize2fs -f -M $1
		resize2fs -f -M $1
	}
}

rebuild() {
	[ $LINUX -eq 1 ] && [ ! -d "/etc/selinux" ] && return
	loop=$(losetup -f)
	losetup $loop "$1"
	mount -o ro $loop "$TEMP" || { losetup -D; return; }
	$TOYBOX cp -rf "$TEMP"/* "$TEMP2"/
	size=$(du -sm | cut -f1)
	find "$TEMP" -exec ls -d -Z {} + > "$HOME/${1%.img}_context"
	context="$(find $TEMP -exec ls -d -Z {} +)"
	umount "$TEMP" || umount -l "$TEMP2" && losetup -D
	make_ext4fs -l ${size}M -L ${1%.img} -a ${1%.img} $1 "$TEMP2" || return
	loop=$(losetup -f)
	losetup $loop "$1"
	mount $loop "$TEMP"
	echo "$context" | while read context file; do
		chcon -h $context $file
	done
	umount "$TEMP" || umount -l "$TEMP"
	losetup -D
}

erofs_conversion() {
	[ $LINUX -eq 1 ] && [ ! -d "/etc/selinux" ] && return 1
	[ $RECOVERY -eq 1 ] && return 1
	printf "Because partition image sizes exceed the super block, program cannot create super.img. You can convert back to EROFS, or debloat partitions to fit the super block. Enter y for EROFS, n for debloat (y/n): "
	read choice
	echo
	[ "$choice" = "n" ] && return 1
	for img in $PARTS; do
		loop=$(losetup -f)
		losetup $loop $img
		mount $loop "$TEMP" || { echo "Program cannot convert ${img%*.img} to EROFS because of mounting issues, skipping."; echo; continue; }
		echo "Converting ${img%*.img} to EROFS"
		echo
		mkfs.erofs -zlz4hc ${img%*.img}_erofs.img "$TEMP" 1> /dev/null
		{ umount "$TEMP" || umount -l "$TEMP" && losetup -D; } >/dev/null 2>&1 
		mv ${img%*.img}_erofs.img $img
	done
	BACK_TO_EROFS=1
}


super_extract() {
	if [ -b "$ROM" ] && [ $LINUX -eq 1 ]; then
		   echo "Extracting from block devices is Android-only feature"
		   exit 1
	fi
	{ file "$ROM" | grep -q -i "archive"; } && {
		echo "Extracting super from archive (This takes a while)"
		echo
		super_path="$(7z l "$ROM" | awk '/super.img/ { print $6 }')"
		firmware_images=$(7z l "$ROM" | awk '/boot.img|vendor_boot.img|dtbo.img|vbmeta.img|vbmeta_system.img/ { printf "%s ", $6}')
		7z e -y "$ROM" $(echo $firmware_images) -oextracted 1> /dev/null
		7z e -y "$ROM" "${super_path}" 1> /dev/null
		case ${super_path##*/} in 
			*.gz) pigz -d ${super_path##*/};;
			*.img) :;;
			*) 7z e -y "${super_path##*/}" >/dev/null 2>&1 && rm "${super_path##*/}";;
		esac
		ROM=super.img
	}
	if file "$ROM" | grep -q sparse; then
		echo "Converting sparse super to raw"
		echo
		simg2img "$ROM" super_raw.img 1> /dev/null
		mv super_raw.img super.img
		ROM=super.img
	fi

	echo "Unpacking super"
	echo
	if [ -b "$ROM" ]; then
		case $SLOT in
			_a) slot_num=0;;
			_b) slot_num=1;;
		esac
		if lpunpack --slot=$slot_num "$ROM" extracted 2>&1 | grep -q "sparse"; then
			echo "But extracting it from super block first because it is sparse"
			echo
			dd if=/dev/block/by-name/super of=super_sparse.img
			simg2img super_sparse.img super.img
			rm super_sparse.img
			lpunpack --slot=$slot_num super.img extracted 1> /dev/null || { echo "This is not a valid super image or block"; cleanup; exit 1; }
		fi
	else
		lpunpack "$ROM" extracted 1> /dev/null || { echo "This is not a valid super image or block"; cleanup; exit 1; }
	fi
	rm "$HOME"/super* >/dev/null 2>&1
	cd extracted
	for img in *.img; do
		[ -s "$img" ] || { rm $img; continue; }
		case $img in *_a.img|*_b.img) mv $img ${img%_*}.img;; esac
	done
}

payload_extract() {
	echo "Extracting images from payload (This takes a while)"
	echo
	payload-dumper -c ${CPU:-1} -o extracted "$ROM" 1> /dev/null || { echo "Program cannot extract payload"; exit 1; }
	cd extracted
}

read_write() {
	echo "Readying images for super packing process"
	echo
	for img in $PARTS; do
		if dump.erofs $img >/dev/null 2>&1; then 
			[ $LINUX -eq 1 ] && [ ! -d "/etc/selinux" ] && echo "Your distro does not have SELINUX therefore doesn't support read&write process. Continuing as read-only..." && echo && sleep 2 && export READ_ONLY=1 && return 1
			echo "Converting EROFS ${img%.img} image to ext4"
			echo
			$SHELL "$HOME"/erofs_to_ext4.sh convert $img 1> /dev/null || { echo "An error occured during conversion, exiting"; exit 1; }
			[ $DFE -eq 1 ] && [ $img = "vendor.img" ] && $SHELL "$HOME"/pay2sup_helper.sh dfe
		else
			if ! tune2fs -l $img | grep -i -q shared_blocks; then
				[ $img = "vendor.img" ] && {
				       	[ $DFE -eq 1 ] && $SHELL "$HOME"/pay2sup_helper.sh dfe
					$SHELL "$HOME"/pay2sup_helper.sh remove_overlay
				}
				continue
			fi
			echo "Making ${img%.img} partition read&write"
			echo
			grant_rw $img 1> /dev/null
			if tune2fs -l $img | grep -i -q shared_blocks; then
				rebuild $img 1> /dev/null
			fi
			if [ $img = "vendor.img" ]; then
				[ $DFE -eq 1 ] && $SHELL "$HOME"/pay2sup_helper.sh dfe
				$SHELL "$HOME"/pay2sup_helper.sh remove_overlay
			fi
		fi
	done
	export READ_ONLY=0
}

get_super_size() {
	[ $RECOVERY -eq 1 ] && {
		super_size=$(blockdev --getsize64 /dev/block/by-name/super)
		SLOT=$(getprop ro.boot.slot_suffix)
		return
	}
	printf "%s\n\n%s\n\n%s" "Enter the size of your super block, you can obtain it by:" "blockdev --getsize64 /dev/block/by-name/super" "If you don't want to enter it manually, only press enter and the program will detect it automatically from your device: "
	read super_size
	echo
	if [ ${super_size:-"0"} -gt 1 ]; then
		printf "Enter the slot name you want to use (lowercase), leave empty if your device is A-only: "
		read SLOT
		case $SLOT in
			"a"|"_a") SLOT=_a; return;;
			"b"|"_b") SLOT=_b; return;;
		esac
	fi
	if [ $LINUX -eq 0 ]; then
		super_size=$(blockdev --getsize64 /dev/block/by-name/super)
		SLOT=$(getprop ro.boot.slot_suffix)
	else
		echo "Program requires connecting to your device through ADB and your device needs to be rooted or in recovery. It will wait until your device is connected. Please connect your device. If you connected it to your PC, press enter. If you wish to exit the program, press CTRL + c"
		echo
		read
		while true; do
			if adb get-state | grep -q "device"; then
				super_size=$(adb shell su -c blockdev --getsize64 /dev/block/by-name/super) || { echo "Can't do this without root permission. Make sure shell is granted with root access in your root app."; echo; }
				SLOT=$(adb shell su -c getprop ro.boot.slot_suffix) && break
			elif adb get-state | grep -q "recovery"; then
				super_size=$(adb shell blockdev --getsize64 /dev/block/by-name/super) || { echo "A problem occured while estimating your device super size in recovery state, exiting"; exit 1; }
				SLOT=$(adb shell getprop ro.boot.slot_suffix) && break
			else
				echo "Cannot access the device, put it in recovery mode as a last resort and connect to your PC. Program will automatically continue."
				echo
				adb wait-for-any-recovery
				super_size=$(adb shell blockdev --getsize64 /dev/block/by-name/super) || { echo "A problem occured while estimating your device super size, exiting"; exit 1; }
				SLOT=$(adb shell getprop ro.boot.slot_suffix) && break
			fi
		done
	fi
}

shrink_before_resize() {
	echo "Shrinking partitions..."
	echo
	$SHELL "$HOME"/pay2sup_helper.sh shrink $PARTS 1> /dev/null
}

get_read_write_state() {
	for img in $PARTS; do
		if dump.erofs $img >/dev/null 2>&1; then
			export EROFS=1
			export READ_ONLY=1
			return 1
		elif tune2fs -l $img 2> /dev/null | grep -i -q shared_blocks; then
			[ $GRANT_RW -eq 0 ] && echo "Program cannot resize partitions because they are read-only" && echo
			[ -s $img ] || continue
			export READ_ONLY=1
			return 1
		else
			export EROFS=0
			export READ_ONLY=0
		fi
	done
}

resize() {
	[ $READ_ONLY -eq 1 ] && return
	printf "Do you wish to shrink partitions to their minimum sizes before resizing? (y/n): "
	read shrink
	echo
	[ $shrink = "y" ] && shrink_before_resize 2> /dev/null
	for img in $PARTS; do
		if dump.erofs $img >/dev/null 2>&1; then
			if [ $READ_ONLY -eq 0 ]; then
				echo "EROFS partitions cannot be resized unless they are converted to EXT4, switching on read&write mode" && echo
				read_write || { echo "EROFS partitions cannot be resized unless they are converted to EXT4, and your distro does not support this conversion."; echo; return 1; }
			else
				return
			fi
		fi
		clear
		echo "PARTITION SIZES"
		echo
	        if ! $SHELL "$HOME"/pay2sup_helper.sh get $( calc $super_size-10000000 ); then
			echo "Shrinking partitions because they exceed the super block size"
			echo
			shrink_before_resize 1> /dev/null
		        if ! $SHELL "$HOME"/pay2sup_helper.sh get $( calc $super_size-10000000 ) >/dev/null 2>&1; then
				erofs_conversion && return || $SHELL "$HOME"/pay2sup_helper.sh get $( calc $super_size-10000000 ) 2>&1 1>/dev/null || exit 1
			fi
		fi
		printf "Enter the amount of space you wish to give for ${img%.img} (MB): "
		read add_size
		echo
		$SHELL "$HOME"/pay2sup_helper.sh expand $img ${add_size:-0}
		sleep 1
	done
}

pack() {
	[ $BACK_TO_EROFS -eq 0 ] && [ $DFE -eq 1 ] && [ $READ_ONLY -eq 1 ] && \
	        echo "Because partitions are still read-only, file encryption disabling is not possible." && echo
	[ $RECOVERY -eq 0 ] && {
		printf "If you wish to make any changes to partitions, script pauses here. Your partitions can be found in $PWD. Please make your changes and press enter to continue. If you don't have SELINUX installed in your system, be careful not to replace system files as it will break SELINUX contexts."
		echo
		read
		while mountpoint -q "$TEMP" || mountpoint -q "$TEMP2"; do
			umount "$TEMP" || umount -l "$TEMP"
			umount "$TEMP2" || umount -l "$TEMP2"
		done
		echo
		[ -d "/etc/selinux" ] && [ $READ_ONLY -eq 0 ] && echo "Restoring SELINUX contexts..." && echo && $SHELL "$HOME"/pay2sup_helper.sh restore_secontext 2>> "$LOG_FILE" 1> /dev/null
	}
	if [ $BACK_TO_EROFS -eq 0 ] && [ $RESIZE -eq 0 ] && [ $READ_ONLY -eq 0 ] && [ $RECOVERY -eq 0 ]; then
		printf "Do you want to shrink partitions to their minimum sizes before repacking? (y/n): "
		read shrink
		echo
		[ $shrink = "y" ] && shrink_before_resize 2> /dev/null
	fi
	if [ $RESIZE -eq 0 ] && [ $RECOVERY -eq 0 ]; then	
		if ! $SHELL "$HOME"/pay2sup_helper.sh get $super_size 1> /dev/null; then
			echo "Shrinking partitions because they exceed the super block size"
			echo
			shrink_before_resize 1> /dev/null
		        if ! $SHELL "$HOME"/pay2sup_helper.sh get $( calc $super_size-10000000 ) >/dev/null 2>&1; then
				erofs_conversion && return || $SHELL "$HOME"/pay2sup_helper.sh get $( calc $super_size-10000000 ) 2>&1 1>/dev/null || exit 1
			fi
		fi
	fi
	for img in *.img; do
		case $PARTS in *$img*)
			lp_part_name=${img%.img}$SLOT
			sum=$( calc $sum+$(stat -c%s $img) )
			lp_parts="$lp_parts --partition $lp_part_name:readonly:$(stat -c%s $img):main --image $lp_part_name=$img ";;
		*)
			mv $img "$HOME"/flashable/firmware-update;;
		esac
	done
	lp_args="--metadata-size 65536 --super-name super --metadata-slots 2 --device super:$super_size --group main:$sum $lp_parts $SPARSE --output $HOME/flashable/super.img"
	echo "Packaging super image"
	echo
	lpmake $lp_args 1> /dev/null || { echo "Something went wrong with super.img creation, exiting"; exit 1; } 

}

patch_kernel() {
	[ $BACK_TO_EROFS -eq 1 ] && return
	if [ ! -f "boot.img" ] && [ ! -f "vendor_boot.img" ]; then
		if [ $LINUX -eq 0 ]; then
			dd if=/dev/block/by-name/boot$SLOT of=boot.img
			dd if=/dev/block/by-name/vendor_boot$SLOT of=vendor_boot.img
		else
			echo "You have no kernel files in workspace for program to patch for EXT4. Provide the program kernel files by putting them in $PWD or program will have the skip this step. Press enter to continue."
			echo
			read
			[ -f "boot.img" ] && [ -f "vendor_boot.img" ] || return
		fi
	fi
	echo "Patching the kernel for EXT4 support.."
	echo
	for img in boot.img vendor_boot.img; do
		$SHELL $HOME/pay2sup_helper.sh patch_kernel "$PWD/$img" 1> /dev/null || { echo "Cannot patch $img for EXT4 because of a problem, skipping..."; echo; continue; }
	done
}

flashable_package() {
	cd "$HOME"/flashable
	echo "Compressing super image because it is too large"
	echo
	pigz -f -q -1 super.img || { echo "Cannot compress super.img because of an issue"; exit 1; }
	updater_script=META-INF/com/google/android/update-binary
	echo "Creating zip structure"
	echo
	echo '#!/sbin/sh

OUTFD=/proc/self/fd/$2
ZIPFILE="$3"

ui_print() {
  echo -e "ui_print $1" >>$OUTFD
}

package_extract_file() {
  unzip -p "$ZIPFILE" $1 >$2
}

' > $updater_script
	printf "%s\n\n" "ui_print \"Flashing repacked super rom\"" >> $updater_script
	for firmware in firmware-update/*; do
		case $firmware in *.img) 
			part_name=${firmware##*/}
			part_name=${part_name%.*}
			echo "ui_print \"Updating $part_name...\"" >> $updater_script
			echo "package_extract_file $firmware /dev/block/bootdevice/by-name/${part_name}_a" >> $updater_script
			printf "%s\n\n" "package_extract_file $firmware /dev/block/bootdevice/by-name/${part_name}_b" >> $updater_script;;
		esac
	done
	echo 'ui_print "Installing super..."' >> $updater_script
	echo 'unzip -p "$ZIPFILE" super.img.gz | pigz -d -c > /dev/block/bootdevice/by-name/super' >> $updater_script
	printf "\n%s\n%s\n" "avbctl --force disable-verity" "avbctl --force disable-verification" >> $updater_script
	echo "Creating flashable rom"
	echo
	7z a "$OUT/FlashableSuper.zip" META-INF super.img.gz firmware-update -mx0 -mmt${CPU:-1} -tzip 1> /dev/null
	echo "Your flashable rom is ready! You can find it in $OUT"
	echo
}

project_structure() {
	rm -rf extracted flashable tmp tmp2
	mkdir -p \
		flashable/META-INF/com/google/android/\
		flashable/firmware-update\
		extracted\
		tmp\
		tmp2
}

recovery_resize() {
	shrink_before_resize 
	$SHELL "$HOME"/pay2sup_helper.sh get $( calc $super_size-10000000 ) 1> /dev/null
	space=$(cat empty_space)
	add_size=$( calc $space/$(echo $PARTS | wc -w) )
	echo "Expanding partitions"
	echo
	for img in $PARTS; do
		[ $space -eq 1 ] && {
			echo "Partitions exceed the super block size, cannot continue"
			exit 1
	       	}
		$SHELL "$HOME"/pay2sup_helper.sh expand $img ${add_size:-0} 1> /dev/null
	done
}

recovery() {
	trap "cleanup; rm -rf $HOME/bin" EXIT
	[ -f "$LOG_FILE" ] && rm $LOG_FILE
	ROM=/dev/block/by-name/super
	DFE=1
	[ $NOT_IN_RECOVERY -ne 1 ] && SPARSE="--sparse"
	chmod +x -R "$HOME"/bin
	{
		project_structure
		get_os_type
		get_super_size
		super_extract
		get_partitions
		read_write
		recovery_resize
		patch_kernel
		pack
		if [ $NOT_IN_RECOVERY -eq 1 ]; then
			rm -rf "$HOME"/extracted
			flashable_package
		else
			echo "Flashing super image..."
			simg2img "$HOME"/flashable/super.img /dev/block/by-name/super
			echo "Flashing boot image..."
			dd if="$HOME"/extracted/boot.img of=/dev/block/by-name/boot$SLOT
			echo "Flashing vendor_boot image..."
			dd if="$HOME"/extracted/vendor_boot.img of=/dev/block/by-name/vendor_boot$SLOT
		fi
		cleanup
	} 2>> "$LOG_FILE"
}

main() {
	set -x
	ROM=$1
	{ get_os_type; toolchain_check; }
	[ -z $CONTINUE ] && {
		cleanup
		if [ -z "$ROM" ] || [ ! -f "$ROM" ] && [ ! -b "$ROM" ]; then
			echo "You need to specify a valid ROM file or super block first"
		       	exit 1
		fi
		project_structure
		case "$ROM" in
			*.bin) payload_extract;;
			*.img|/dev/block/by-name/super) super_extract;;
			*.tgz)
				echo "Extracting the first layer of this archive to check if it is viable"
				echo
				7z e -y "$ROM" -o"$HOME" >/dev/null 2>&1 || { echo "ROM is not supported"; exit 1; }
				ROM="$(7z l $ROM | awk '/.tar/ {print $6}')"
				super_extract ;;
			*)
				if 7z l "$ROM" 2> /dev/null | grep -E -q '[a-z]*[A-Z]*[/]*super.img.*' 2> /dev/null; then
					super_extract 
				elif 7z l "$ROM" 2> /dev/null | grep -q payload.bin >/dev/null 2>&1; then
					payload_extract 
				elif [ -b "$ROM" ]; then
					super_extract 
				else
					echo "ROM is not supported"
					exit
				fi
				;;
		esac
	} || cd "$HOME"/extracted
	{
		get_super_size
		get_partitions
		get_read_write_state
		[ $GRANT_RW -eq 1 ] && read_write
		[ $GRANT_RW -eq 1 ] || [ $READ_ONLY -eq 0 ] && [ ! -z $DEBLOAT ] && $SHELL "$HOME/pay2sup_helper.sh" debloat $debloat_list
		[ $RESIZE -eq 1 ] && resize 
		if [ $GRANT_RW -eq 1 ] || [ $READ_ONLY -eq 0 ]; then
			[ -d "/etc/selinux" ] && echo "Preserving SELINUX contexts..." && echo && $SHELL "$HOME"/pay2sup_helper.sh preserve_secontext 1> /dev/null
		fi
		get_read_write_state
		patch_kernel
		pack
		flashable_package
		cleanup
		exit
	}
}

help_me() {
	echo "
OPTION 1: $0 [-rw|--read-write] [-r|--resize] payload.bin|super.img|rom.zip|/dev/block/by-name/super
OPTION 2: $0 [-rw|--read-write] [-r|--resize] [-c|--continue]

-rw  | --read-write         = Grants write access to all the partitions.

-r   | --resize	            = Resizes partitions based on user input. User input will be asked during the program.

-dfe | --disable-encryption = Disables Android's file encryption. This parameter requires read&write partitions.

-d   | --debloat	    = Debloats partition images with a given debloat list. If list file isn't provided or doesn't exist, it will default to debloat.txt in project directory. If that doesn't exist either, it will skip debloating. 

-t   | --thread	            = Certain parts of the program are multitaskable. If you wish to make the program faster, you can specify a number here.

-c   | --continue           = Continues the process if the program had to quit early. Do not specify a payload file with this option. NOTE: This option could be risky depending on which part of the process the program exited. Use only if you know what you're doing.

-h   | --help	            = Prints out this help message.

Note that --continue or payload.zip|.bin flag has to come after all other flags otherwise other flags will be ignored. You should not use payload.zip|.bin and --continue flags mixed with together. They are mutually exclusive.
"
}

[ -z "$*" ] && help_me | head -n4 && exit

for _ in "$@"; do
	case $1 in
		"--recovery")
			export RECOVERY=1
			recovery
			exit;;
		"-d"| "--debloat")
			export DEBLOAT=1
			shift
			[ -f "$1" ] && debloat_list="$(realpath $1)" && shift || debloat_list="$HOME/debloat.txt"
			[ -f "$debloat_list" ] || curl -k -L https://raw.githubusercontent.com/elfametesar/Payload2Super/experimental/debloat.txt -o debloat.txt >/dev/null 2>&1
			continue;;
		"-rw"| "--read-write")
			export GRANT_RW=1
			shift
			continue;;
		"-t"|"--thread")
			shift
			export CPU=$1
			shift
			continue;;
		"-r"|"--resize")
			export RESIZE=1
			shift
			continue;;
		"-dfe"| "--disable-encryption")
			export DFE=1
			shift
			continue;;
		"-h"|"--help")
			help_me 
			exit;;
		"-c"|"--continue")
			if [ ! -d "$HOME/extracted" ] || ! ls "$HOME/extracted" | grep -q ".img"; then
				echo "Cannot continue because source files do not exist" 
				exit 1
			fi
			export CONTINUE=1
			main 2> "$LOG_FILE";;	
		-*)
			help_me
			echo "$1 is not a valid command"
			exit;;
		*)
			main "$(realpath $1 2> /dev/null)" 2> "$LOG_FILE";;

	esac
done


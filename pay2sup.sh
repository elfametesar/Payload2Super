#!/bin/env sh

export PATH=$PWD/bin:$PATH
export HOME=$PWD
export LINUX=0
export LOG_FILE=$HOME/pay2sup.log
export OUT=/sdcard/Payload2Super
export GRANT_RW=0
export RESIZE=0
export READ_ONLY=0
export EROFS=0
export DFE=0
export TEMP=$HOME/tmp
export TEMP2=$HOME/tmp2
export BACK_TO_EROFS=0
export RECOVERY=0

trap "exit" INT
trap "{ umount $TEMP 2> /dev/null || umount -l $TEMP; losetup -D; } 2> /dev/null" EXIT


[[ $(id -u) != 0 ]] && {
	echo "Program must be run as the root user, use sudo -E on Linux platforms and su for Android"
	exit
}

TOOLCHAIN=(make_ext4fs \
	mkfs.erofs \
	busybox \
	pigz \
	7z \
	dump.erofs \
	fuse.erofs \
	extract.erofs \
	lpmake \
	lpunpack \
	payload-dumper \
	adb)

toolchain_check() {
	[[ -d $HOME/bin ]] || toolchain_download
	echo -e "Checking the toolchain integrity\n"
	for tool in ${TOOLCHAIN[@]}; do
		if [[ -f $HOME/bin/$tool ]]; then
			continue
		else
			[[ $tool == adb && $LINUX == 0 ]] && continue
			[[ $tool == make_ext4fs || $tool == busybox && $LINUX == 1 ]] && continue
			missing+=($tool)
		fi
	done
	[[ -z $missing ]] || { \
		echo "${missing[@]} tool(s) missing in path, re-run the script to renew the toolchain."
		rm -rf $HOME/bin
		exit 1
	}
}

cleanup() { 
	rm -rf $HOME/extracted $HOME/flashable $HOME/super* $HOME/empty_space
}

get_os_type() {
	case $OSTYPE in
		linux-gnu)
			export LINUX=1
			export OUT=~;;
		*)
			[[ -d /sdcard && ! -d $OUT ]] && mkdir $OUT
			export BUSYBOX=busybox;;
	esac	
}

get_partitions() {
	vendor=$HOME/extracted/vendor.img
	if dump.erofs $vendor &> /dev/null; then
		fuse.erofs $vendor $TEMP 1> /dev/null
	else
		loop=$(get_loop $vendor)
		mount -o ro $loop $TEMP
	fi
	mountpoint -q $TEMP || { echo "Partition list cannot be retrieved, this is a fatal error, exiting..."; exit 1; }
	for fstab in $TEMP/etc/fstab*; do
		FSTABS+=$(cat $fstab)
	done
	PART_LIST=$(echo "$FSTABS" | awk '!seen[$2]++ { if($2 != "/data" && $2 != "/metadata" && $2 != "/boot" && $2 != "/vendor_boot" && $2 != "/recovery" && $2 != "/init_boot" && $2 != "/dtbo" && $2 != "/cache" && $2 != "/misc" && $2 != "/oem" && $2 != "/persist" ) print $2 }'  | grep -E -o '^/[a-z]*(_|[a-z])*[^/]$')
	PART_LIST=${PART_LIST//\//}
	PART_LIST=$(awk '{ print $1".img" }' <<< "$PART_LIST")
	for img in $HOME/extracted/*.img; do
		[[ $PART_LIST == *${img##*/}* ]] && export PARTS+="${img##*/} "
	done
	umount $TEMP || umount -l $TEMP
	losetup -D
}

toolchain_download() {
	[[ -d $HOME/bin ]] && return
	if [[ $LINUX == 0 ]]; then
		   URL="https://github.com/elfametesar/uploads/raw/main/toolchain_android_arm64.tar"
	else
		   URL="https://github.com/elfametesar/uploads/raw/main/toolchain_linux_x64.tar"
	fi	
	echo "Downloading toolchain"
	curl -L $URL -o ${URL##*/} 1> /dev/null
	echo -e "Extracting toolchain\n"
	mkdir $HOME/bin
	tar xf ${URL##*/} -C $HOME/bin/
	rm ${URL##*/} 	
}


calc(){ awk 'BEGIN{ print int('"$1"') }'; }

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
	[[ $RESIZE == 1 ]] && {
		resize2fs -f -M $1
		resize2fs -f -M $1
	}
}

get_loop() {
	local loop=$(losetup -f)
	losetup $loop $1
	echo $loop
}

rebuild() {
	[[ $LINUX == 1 && ! -d /etc/selinux ]] && return
	local loop=$(get_loop $1)
	mount -o ro $loop $TEMP || { losetup -D; return; }
	local size=$(blockdev --getsize64 $loop)
	local secontext=$(ls -d -Z $TEMP | sed "s|$TEMP|$TEMP2|")
	size=$( calc $size/1024/1024 )
	local new_image=${1/.img/_rw.img}
	fallocate -l ${size}M $new_image
	mkfs.ext4 $new_image
	local loop2=$(get_loop $new_image)
	mount $loop2 $TEMP2
	cp -ra $TEMP/* $TEMP2/
	chcon -h $(echo ${secontext})
	{ umount $TEMP $TEMP2 || umount -l $TEMP $TEMP2; losetup -D; } 2> /dev/null
	mv $new_image $1
}

erofs_conversion() {
	[[ $LINUX == 1 && ! -d /etc/linux ]] && return 1
	echo -n "Because partition image sizes exceed the super block, program cannot create super.img. You can convert back to EROFS, or debloat partitions to fit the super block. Enter y for EROFS, n for debloat (y/n): "
	read choice
	echo
	[[ $choice == "n" ]] && return 1
	for img in $PARTS; do
		loop=$(get_loop $img)
		mount $loop $TEMP || { echo -e "Program cannot convert ${img%*.img} to EROFS because of mounting issues, skipping.\n"; continue; }
		echo -e "Converting ${img%*.img} to EROFS\n"
		mkfs.erofs -zlz4hc ${img%*.img}_erofs.img $TEMP 1> /dev/null
		{ umount $TEMP || umount -l $TEMP && losetup -D; } &> /dev/null
		mv ${img%*.img}_erofs.img $img
	done
	BACK_TO_EROFS=1
}


super_extract() {
	if [[ -b $ROM && $LINUX == 1 ]]; then
		   echo "Extracting from block devices is Android-only feature"
		   exit 1
	fi
	{ file $ROM | grep -q -i "archive"; } && {
		echo -e "Extracting super from archive (This takes a while)\n"
		super_path="$(7z l $ROM | grep -o -E '[a-z]*[A-Z]*[/]*super.img.*')"
		7z e $ROM "*.img" "*/*.img" "*/*/*.img" -o$HOME/extracted 1> /dev/null
		7z e $ROM "${super_path}" -o$HOME 1> /dev/null
		if [[ ${super_path##*/} == *.gz ]]; then
			pigz -d ${super_path##*/}
		else
			7z e "${super_path##*/}" &> /dev/null && rm "${super_path##*/}"
		fi
		ROM=super.img
	}
	if file $ROM | grep -q sparse; then
		echo -e "Converting sparse super to raw\n"
		simg2img $ROM super_raw.img
		mv super_raw.img super.img
		ROM=super.img
	fi

	echo -e "Unpacking super\n"
	if [[ -b $ROM ]]; then
		if lpunpack $ROM extracted 1> /dev/null | grep -q "sparse"; then
			echo -e "But extracting it from super block first because it is sparse\n"
			dd if=/dev/block/by-name/super of=super_sparse.img
			simg2img super_sparse.img super.img
			rm super_sparse.img
		fi
	fi
	lpunpack $ROM extracted 1> /dev/null || { echo "This is not a valid super image or block"; cleanup; exit 1; }
	rm $HOME/super* &> /dev/null
	cd extracted
	for img in *.img; do
		[[ -s $img ]] || { rm $img; continue; }
		if [[ $img == *_a.img || $img == *_b.img ]]; then
			mv $img ${img%_*}.img
		fi
	done
}

payload_extract() {
	echo -e "Extracting images from payload (This takes a while)\n"
	payload-dumper -c ${CPU:-1} -o extracted $ROM 1> /dev/null || { echo "Program cannot extract payload"; exit 1; }
	cd extracted
}

read_write() {
	echo -e "Readying images for super packing process\n"
	for img in $PARTS; do
		if dump.erofs $img 1> /dev/null; then 
			[[ $LINUX == 1 && ! -d /etc/selinux ]] && echo -e "Your distro does not have SELINUX therefore doesn't support read&write process. Continuing as read-only...\n" && sleep 2 && export READ_ONLY=1 && return 1
			echo -e "Converting EROFS ${img%.img} image to ext4\n"
			sh $HOME/erofs_to_ext4.sh convert $img 1> /dev/null || { echo "An error occured during conversion, exiting"; exit 1; }
			[[ $DFE == 1 ]] && [[ $img == vendor.img ]] && sh $HOME/pay2sup_helper.sh dfe
		else
			if ! tune2fs -l $img | grep -i -q shared_blocks; then
				[[ $img == vendor.img ]] && {
				       	[[ $DFE == 1 ]] && sh $HOME/pay2sup_helper.sh dfe
					sh $HOME/pay2sup_helper.sh remove_overlay
				}
				continue
			fi
			echo -e "Making ${img%.img} partition read&write\n"
			grant_rw $img 1> /dev/null
			if tune2fs -l $img | grep -i -q shared_blocks; then
				rebuild $img 1> /dev/null
			fi
			if [[ $img == vendor.img ]]; then
				[[ $DFE == 1 ]] && sh $HOME/pay2sup_helper.sh dfe
				sh $HOME/pay2sup_helper.sh remove_overlay
			fi
		fi
	done
	export READ_ONLY=0
}

get_super_size() {
	[[ $RECOVERY == 1 ]] && {
		super_size=$(blockdev --getsize64 /dev/block/by-name/super)
		SLOT=$(getprop ro.boot.slot_suffix)
		return
	}
	echo -en "Enter the size of your super block, you can obtain it by:\n\nblockdev --getsize64 /dev/block/by-name/super\n\nIf you don't want to enter it manually, only press enter and the program will detect it automatically from your device: "
	read super_size
	echo
	if (( ${super_size:-"0"} > 1 )); then
		echo -n "Enter the slot name you want to use, leave empty if your device is A-only: "
		read SLOT
		case $SLOT in
			"a"|"_a") SLOT=_a; return;;
			"b"|"_b") SLOT=_b; return;;
		esac
	fi
	if [[ $LINUX == 0 ]]; then
		super_size=$(blockdev --getsize64 /dev/block/by-name/super)
		SLOT=$(getprop ro.boot.slot_suffix)
	else
		echo -e "Program requires connecting to your device through ADB and your device needs to be rooted or in recovery. It will wait until your device is connected. Please connect your device. If you connected it to your PC, press enter. If you wish to exit the program, press CTRL + c\n"
		read
		while true; do
			if adb get-state | grep -q "device"; then
				super_size=$(adb shell su -c blockdev --getsize64 /dev/block/by-name/super) || { echo -e "Can't do this without root permission. Make sure shell is granted with root access in your root app.\n"; }
				SLOT=$(adb shell su -c getprop ro.boot.slot_suffix) && break
			elif adb get-state | grep -q "recovery"; then
				super_size=$(adb shell blockdev --getsize64 /dev/block/by-name/super) || { echo "A problem occured while estimating your device super size in recovery state, exiting"; exit 1; }
				SLOT=$(adb shell getprop ro.boot.slot_suffix) && break
			else
				echo -e "Cannot access the device, put it in recovery mode as a last resort and connect to your PC. Program will automatically continue.\n"
				adb wait-for-any-recovery
				super_size=$(adb shell blockdev --getsize64 /dev/block/by-name/super) || { echo "A problem occured while estimating your device super size, exiting"; exit 1; }
				SLOT=$(adb shell getprop ro.boot.slot_suffix) && break
			fi
		done
	fi
}

shrink_before_resize() {
	echo -e "Shrinking partitions...\n"
	sh $HOME/pay2sup_helper.sh shrink $PARTS 1> /dev/null
}

get_read_write_state() {
	for img in $PARTS; do
		if dump.erofs $img &> /dev/null; then
			export EROFS=1
			export READ_ONLY=1
			return 1
		elif tune2fs -l $img &> /dev/null | grep -i -q shared_blocks; then
			[[ $GRANT_RW == 0 ]] && echo -e "Program cannot resize partitions because they are read-only\n"
			export READ_ONLY=1
			return 1
		else
			export EROFS=0
			export READ_ONLY=0
		fi
	done
}

resize() {
	[[ $READ_ONLY == 1 ]] && return
	echo -en "Do you wish to shrink partitions to their minimum sizes before resizing? (y/n): "
	read shrink
	echo
	[[ $shrink == "y" ]] && shrink_before_resize 2> /dev/null
	for img in $PARTS; do
		if dump.erofs $img &> /dev/null; then
			if [[ $READ_ONLY == 0 ]]; then
				echo -e "EROFS partitions cannot be resized unless they are converted to EXT4, switching on read&write mode\n"
				read_write || { echo -e "EROFS partitions cannot be resized unless they are converted to EXT4, and your distro does not support this conversion.\n"; return 1; }
			else
				return
			fi
		fi
		clear
		echo -e "PARTITION SIZES\n"
		sh $HOME/pay2sup_helper.sh get $( calc $super_size-10000000 )
	        if [[ $? == 1 ]]; then
			shrink_before_resize 1> /dev/null || { erofs_conversion; return; }
		fi
		echo -n "Enter the amount of space you wish to give for ${img%.img} (MB): "
		read add_size
		echo
		sh $HOME/pay2sup_helper.sh expand $img ${add_size:-0}
		sleep 1
	done
}

pack() {
	[[ $BACK_TO_EROFS == 0 && $DFE == 1 && $READ_ONLY == 1 ]] && \
	       echo -e "Because partitions are still read-only, file encryption disabling is not possible.\n"
	if [[ $RESIZE == 0 && $RECOVERY == 0 ]]; then
		sh $HOME/pay2sup_helper.sh get $super_size 1> /dev/null 
		[[ $? == 1 ]] && erofs_conversion
		EROFS=1
	fi
	[[ $RECOVERY == 0 ]] && {
		echo -en "If you wish to make any changes to partitions, script pauses here. Your partitions can be found in $PWD. Please make your changes and press enter to continue."
		read
		echo
	}
	if [[ $BACK_TO_EROFS=0 && $RESIZE == 0 && $READ_ONLY == 0 && $RECOVERY == 0 ]]; then
		echo -en "Do you want to shrink partitions to their minimum sizes before repacking? (y/n): "
		read shrink
		echo
		[[ $shrink == "y" ]] && shrink_before_resize 2> /dev/null
	fi 	
	for img in *.img; do
		if [[ $PARTS == *$img* ]]; then
			lp_part_name=${img%.img}$SLOT
			sum=$( calc $sum+$(stat -c%s $img) )
			lp_parts+="--partition $lp_part_name:readonly:$(stat -c%s $img):main --image $lp_part_name=$img "
		else
			mv $img $HOME/flashable/firmware-update
		fi
	done
	lp_args="--metadata-size 65536 --super-name super --metadata-slots 2 --device super:$super_size --group main:$sum $lp_parts $SPARSE --output $HOME/flashable/super.img"
	echo -e "Packaging super image\n"
	lpmake $lp_args 1> /dev/null || { echo "Something went wrong with super.img creation, exiting"; exit 1; } 

}

flashable_package() {
	cd $HOME/flashable
	echo -e "Compressing super image because it is too large\n"
	pigz -f -q -1 super.img || { echo "Cannot compress super.img because of an issue"; exit 1; }
	updater_script=META-INF/com/google/android/update-binary
	echo -e "Creating zip structure\n"
	echo '#!/sbin/sh

OUTFD=/proc/self/fd/$2
ZIPFILE="$3"

ui_print() {
  echo -e "ui_print $1\nui_print" >>$OUTFD
}

package_extract_file() {
  unzip -p "$ZIPFILE" $1 >$2
}

' > $updater_script
	echo -e 'ui_print "Flashing repacked super rom"\n' >> $updater_script
	for firmware in firmware-update/*; do
		[[ $firmware == *.img ]] || continue 
		part_name=${firmware##*/}
		part_name=${part_name%.*}
		echo -e "ui_print \"Updating $part_name...\"" >> $updater_script
		echo -e "package_extract_file $firmware /dev/block/bootdevice/by-name/${part_name}_a" >> $updater_script
		echo -e "package_extract_file $firmware /dev/block/bootdevice/by-name/${part_name}_b\n" >> $updater_script
	done
	echo 'ui_print "Installing super..."' >> $updater_script
	echo 'unzip -p "$ZIPFILE" super.img.gz | pigz -d -c > /dev/block/bootdevice/by-name/super' >> $updater_script
	echo -e '\navbctl --force disable-verity\navbctl --force disable-verification' >> $updater_script
	echo -e "Creating flashable rom\n"
	7z a "$OUT/FlashableSuper.zip" META-INF super.img.gz firmware-update -mx0 -mmt${CPU:-1} -tzip 1> /dev/null
	echo -e "Your flashable rom is ready! You can find it in $OUT\n" 
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
	sh $HOME/pay2sup_helper.sh get $( calc $super_size-10000000 ) 1> /dev/null
	space=$(cat empty_space)
	add_size=$( calc $space/$(wc -w <<< "$PARTS") )
	echo "Expanding partitions"
	for img in $PARTS; do
		[[ $space == 1 ]] && {
			echo "Partitions exceed the super block size, cannot continue"
			exit 1
	       	}
		sh $HOME/pay2sup_helper.sh expand $img ${add_size:-0} 1> /dev/null
	done
}

recovery() {
	ROM=/dev/block/by-name/super
	DFE=1
	SPARSE="--sparse"
	chmod +x -R $HOME/bin
	project_structure
	get_os_type
	super_extract 2> $LOG_FILE
	get_super_size 2>> $LOG_FILE
	get_partitions 2>> $LOG_FILE
	read_write 2>> $LOG_FILE
	recovery_resize 2>> $LOG_FILE
	pack 2>> $LOG_FILE
	if [[ $IN_RECOVERY == 1 ]]; then
		echo "Moving super image to $OUT, you can flash it in recovery from there"
		mv $HOME/flashable/super.img $OUT
	else
		echo "Flashing super image..."
		simg2img $HOME/flashable/super.img /dev/block/by-name/super
	fi
	cleanup
}

main() {
	ROM=$1
	get_os_type 2>> $LOG_FILE
	toolchain_check 2>> $LOG_FILE
	[[ -z $CONTINUE ]] && {
		if [[ -z $ROM ]] || [[ ! -f $ROM ]] && [[ ! -b $ROM ]]; then 
			echo "You need to specify a valid ROM file or super block first"
		       	exit 1
		fi
		project_structure
		case $ROM in
			*.bin) payload_extract 2>> $LOG_FILE;;
			*.img|/dev/block/by-name/super) super_extract 2>> $LOG_FILE;;
			*)
				if 7z l $ROM 2> /dev/null | grep -E -q '[a-z]*[A-Z]*[/]*super.img.*' 2> /dev/null; then
					super_extract 2>> $LOG_FILE
				elif 7z l $ROM 2> /dev/null | grep -q payload.bin &> /dev/null; then
					payload_extract 2>> $LOG_FILE
				elif [[ -b $ROM ]]; then
					super_extract 2>> $LOG_FILE
				else
					echo "ROM is not supported"
					exit
				fi
				;;
		esac
	} || cd $HOME/extracted
	get_super_size 2>> $LOG_FILE
	get_partitions 2>> $LOG_FILE
	get_read_write_state
	[[ $GRANT_RW == 1 ]] && read_write 2>> $LOG_FILE
	[[ $RESIZE == 1 ]] && resize 2>> $LOG_FILE
	get_read_write_state
	pack 2>> $LOG_FILE
	flashable_package 2>> $LOG_FILE
	cleanup
	exit
}

help_me() {
	echo "
OPTION 1: $0 [-rw|--read-write] [-r|--resize] payload.bin|super.img|rom.zip|/dev/block/by-name/super
OPTION 2: $0 [-rw|--read-write] [-r|--resize] [-c|--continue]

-rw | --read-write          = Grants write access to all the partitions.

-r  | --resize	            = Resizes partitions based on user input. User input will be asked during the program.

-dfe | --disable-encryption = Disables Android's file encryption. This parameter requires read&write partitions.

-t  | --thread	            = Certain parts of the program are multitaskable. If you wish to make the program faster, you can specify a number here.

-c  | --continue            = Continues the process if the program had to quit early. Do not specify a payload file with this option. NOTE: This option could be risky depending on which part of the process the program exited. Use only if you know what you're doing.

-h  | --help	            = Prints out this help message.

Note that --continue or payload.zip|.bin flag has to come after all other flags otherwise other flags will be ignored. You should not use payload.zip|.bin and --continue flags mixed with together. They are mutually exclusive.
"
}
[[ -z $@ ]] && help_me | head -n4 && exit


for _ in "$@"; do
	case $1 in
		"--recovery")
			export RECOVERY=1
			recovery
			exit;;

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
			[[ -f $LOG_FILE ]] && rm $LOG_FILE
			if [[ ! -d $HOME/extracted ]] || ! ls $HOME/extracted | grep -q ".img"; then
				echo "Cannot continue because source files do not exist" 
				exit 1
			fi
			export CONTINUE=1
			main;;
		*)
			main "$(realpath $1 2> /dev/null)"
			exit;;
		"")
			help_me
			echo "You need to enter the necessary parameters"
			exit;;
		-*)
			help_me
			echo "$1 is not a valid command"
			exit;;

	esac
done

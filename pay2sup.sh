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

trap "exit" INT

[[ $(id -u) != 0 ]] && {
	echo "Program must be run as the root user, use sudo -E on Linux platforms and su for Android"
	exit
}


TOOLCHAIN=(make_ext4fs \
	busybox
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
			[[ $tool == adb || $tool == fuse.erofs && $LINUX == 0 ]] && continue
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
	rm -rf $HOME/extracted $HOME/flashable $HOME/super*
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

super_extract() {
	if [[ -b $SUPER && $LINUX == 1 ]]; then
		   echo "Extracting from block devices is Android-only feature"
		   exit 1
	fi
	{ file $SUPER | grep -q -i "archive"; } && {
		if 7z l $SUPER | grep -q "super.img"; then
			echo -e "Extracting super from archive (This takes a while)\n"
			super_path="$(7z l $SUPER | grep -o -E '[a-z]*[A-Z]*[/]*super.img.*')"
			7z e $SUPER "*.img" "*/*.img" "*/*/*.img" -o$HOME/extracted 1> /dev/null
			7z e $SUPER "${super_path}" -o$HOME 1> /dev/null
			if [[ ${super_path##*/} == *.gz ]]; then
				pigz -d ${super_path##*/}
				else
				7z e "${super_path##*/}" &> /dev/null && rm "${super_path##*/}"
			fi
			SUPER=super.img
		else
			   echo "This archive does not contain a super image"
			   exit 1
		fi
	}
	echo -e "Unpacking super\n"
	lpunpack $SUPER extracted 1> /dev/null || { echo "This is not a valid super image or block"; cleanup; exit 1; }
	rm $HOME/super* &> /dev/null
	cd extracted
	for img in *.img; do
		[[ -s $img ]] || { rm $img; continue; }
		mv $img ${img%_*}.img
	done
}

extract() {
	[[ $PAYLOAD == *.zip ]] && {
		7z l $PAYLOAD payload.bin | grep -q payload.bin || {
			echo "No payload file found in this archive. Make sure you have a valid flashable file"
			exit 1
		}
	}
	echo -e "Extracting images from payload (This takes a while)\n"
	payload-dumper -o extracted $PAYLOAD 1> /dev/null || { echo "Program cannot extract payload"; exit 1; }
	cd extracted
}

read_write() {
	echo -e "Readying images for super packing process\n"
	for img in system.img system_ext.img product.img vendor.img odm.img; do
		if dump.erofs $img 1> /dev/null; then 
			[[ $LINUX == 1 && ! -d /etc/selinux ]] && echo -e "Your distro does not have SELINUX therefore doesn't support read&write process. Continuing as read-only...\n" && sleep 2 && export READ_ONLY=1 && return 1
			echo -e "Converting EROFS ${img%.img} image to ext4\n"
			sh $HOME/erofs_to_ext4.sh convert $img 1> /dev/null || { echo "An error occured during conversion, exiting"; exit 1; }
			[[ $DFE == 1 ]] && [[ $img == vendor.img ]] && sh $HOME/pay2sup_helper.sh dfe
		else
			if ! tune2fs -l $img | grep -i -q shared_blocks; then
				[[ $DFE == 1 ]] && [[ $img == vendor.img ]] && sh $HOME/pay2sup_helper.sh dfe
				continue
			fi
			echo -e "Making ${img%.img} partition read&write\n"
			grant_rw $img 1> /dev/null
			[[ $DFE == 1 ]] && [[ $img == vendor.img ]] && sh $HOME/pay2sup_helper.sh dfe
		fi
	done
	export READ_ONLY=0
}

get_super_size() {
	if [[ $LINUX == 0 ]]; then
		super_size=$(blockdev --getsize64 /dev/block/by-name/super)
	else
		echo -e "Program requires connecting to your device through ADB and your device needs to be rooted or in recovery. It will wait until your device is connected. Please connect your device. If you connected it to your PC, press enter. If you wish to exit the program, press CTRL + c\n"
		read
		while true; do
			if adb get-state | grep -q "device"; then
				super_size=$(adb shell su -c blockdev --getsize64 /dev/block/by-name/super) && break || { echo -e "Can't do this without root permission. Make sure shell is granted with root access in your root app.\n"; }
			elif adb get-state | grep -q "recovery"; then
				super_size=$(adb shell blockdev --getsize64 /dev/block/by-name/super) && break || { echo "A problem occured while estimating your device super size in recovery state, exiting"; exit 1; }
			else
				echo -e "Cannot access the device, put it in recovery mode as a last resort and connect to your PC. Program will automatically continue.\n"
				adb wait-for-any-recovery
				super_size=$(adb shell blockdev --getsize64 /dev/block/by-name/super) && break || { echo "A problem occured while estimating your device super size, exiting"; exit 1; }
			fi
		done
	fi
}

shrink_before_resize() {
	if [[ $shrink == "y" ]]; then
		echo -e "Shrinking partitions...\n"
		sh $HOME/pay2sup_helper.sh shrink \
			system*.img\
		       	odm.img\
		       	product.img\
			vendor.img 1> /dev/null
	fi
}

get_read_write_state() {
	for img in system*.img vendor.img product.img; do
		if dump.erofs $img &> /dev/null; then
			export EROFS=1
			export READ_ONLY=1
			return 1
		elif tune2fs -l $img | grep -i -q shared_blocks; then
			echo -e "Program cannot resize partitions because they are read-only\n"
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
	[[ $shrink == "y" ]] && shrink_before_resize 2&> /dev/null
	for img in system*.img vendor.img odm.img product.img; do
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
		sh $HOME/pay2sup_helper.sh get $( calc $super_size-10000000 ) || exit $?
		echo -n "Enter the amount of space you wish to give for ${img%.img} (MB): "
		read add_size
		echo
		sh $HOME/pay2sup_helper.sh expand $img ${add_size:-0}
		sleep 1
	done
}

pack() {
	[[ $DFE == 1 && $READ_ONLY == 1 ]] && \
	       echo -e "Because partitions are still read-only, file encryption disabling is not possible.\n"
	echo -en "If you wish to make any changes to partitions, script pauses here. Your partitions can be found in $PWD. Please make your changes and press enter to continue."
	read
	echo
	if [[ $RESIZE == 0 && $READ_ONLY == 0 ]]; then
		echo -en "Do you want to shrink partitions to their minimum sizes before repacking? (y/n): "
		read shrink
		echo
		[[ $shrink == "y" ]] && shrink_before_resize 2> /dev/null
	fi 	
	for img in *.img; do
		case $img in system*|vendor.img|odm*|product*)
			lp_part_name=${img%.img}_a
			sum=$( calc $sum+$(stat -c%s $img) )
			lp_parts+="--partition $lp_part_name:readonly:$(stat -c%s $img):main --image $lp_part_name=$img ";;
		*)
			mv $img $HOME/flashable/firmware-update;;
		esac
	done
	lp_args="--metadata-size 65536 --super-name super --metadata-slots 2 --device super:$super_size --group main:$sum $lp_parts --output $HOME/flashable/super.img"
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
		[[ $firmware == *.img ]] || break 
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
	rm -rf extracted flashable tmp
	mkdir -p \
		flashable/META-INF/com/google/android/\
		flashable/firmware-update\
		extracted\
		tmp
}

main_super() {
	[[ -z $SUPER ]] && echo "Specify a valid super flashable or super device" && exit 1
	project_structure
	get_os_type 2> $LOG_FILE
	toolchain_check 2>> $LOG_FILE
	super_extract 2>> $LOG_FILE
	get_super_size 2>> $LOG_FILE
	get_read_write_state
	[[ $GRANT_RW == 1 ]] && read_write 2>> $LOG_FILE
	[[ $RESIZE == 1 ]] && resize 2>> $LOG_FILE
	get_read_write_state
	pack 2>> $LOG_FILE
	flashable_package 2>> $LOG_FILE
	cleanup
	exit
}


main_payload () {
	[[ -z $PAYLOAD || ! -f $PAYLOAD ]] && { echo "You need to specify a valid rom or payload file first"; exit 1; }
	project_structure
	get_os_type 2> $LOG_FILE
	toolchain_check 2> $LOG_FILE
	extract 2>> $LOG_FILE 
	get_super_size 2>> $LOG_FILE
	get_read_write_state
	[[ $GRANT_RW == 1 ]] && read_write 2>> $LOG_FILE
	[[ $RESIZE == 1 ]] && resize 2>> $LOG_FILE
	get_read_write_state
	pack 2>> $LOG_FILE
	flashable_package 2>> $LOG_FILE
	cleanup
}

help_me() {
	echo "
OPTION 1: $0 [-rw|--read-write] [-r|--resize] payload.bin|rom.zip
OPTION 2: $0 [-rw|--read-write] [-r|--resize] --remake super.zip|.img or /path/to/superblock
OPTION 3: $0 [-rw|--read-write] [-r|--resize] [-c|--continue]

-rw | --read-write          = Grants write access to all the partitions.

-r  | --resize	            = Resizes partitions based on user input. User input will be asked during the program.

-dfe | --disable-encryption = Disables Android's file encryption. This parameter requires read&write partitions.

-t  | --thread	            = Certain parts of the program are multitaskable. If you wish to make the program faster, you can specify a number here.

-c  | --continue            = Continues the process if the program had to quit early. Do not specify a payload file with this option. NOTE: This option could be risky depending on which part of the process the program exited. Use only if you know what you're doing.

-s  | --remake	            = Additional feature to repack super flashable images. It can also extract super from /dev/block/by-name/super on Android.

-h  | --help	            = Prints out this help message.

Note that --remake, --continue or payload.zip|.bin flag has to come after all other flags otherwise other flags will be ignored. You should not use --remake <super_flashable.zip> and payload.zip|.bin or --continue flags mixed with together. They are mutually exclusive.
"
}
[[ -z $@ ]] && echo "OPTION 1: $0 [-rw|--read-write] [-r|--resize] payload.bin|rom.zip
OPTION 2: $0 [-rw|--read-write] [-r|--resize] --remake super.zip|.img or /path/to/superblock
OPTION 3: $0 [-rw|--read-write] [-r|--resize] [-c|--continue]" && exit


for _ in "$@"; do
	case $1 in
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
		*.zip|*.bin)
			export PAYLOAD="$(realpath $1 2> /dev/null)"
			main_payload
			exit;;
		"-s"|"--remake")
			shift
			export SUPER="$(realpath $1 2> /dev/null)"
			main_super
			exit;;
		"-c"|"--continue")
			[[ -f $LOG_FILE ]] && rm $LOG_FILE
			if [[ ! -d $HOME/extracted ]] || ! ls $HOME/extracted | grep -q ".img"; then
				echo "Cannot continue because source files do not exist" 
				exit 1
			fi
			cd $HOME/extracted
			get_os_type 2>> $LOG_FILE
			toolchain_check 2>> $LOG_FILE
			get_super_size 2>> $LOG_FILE
			get_read_write_state
			[[ $GRANT_RW == 1 ]] && read_write 2>> $LOG_FILE
			[[ $RESIZE == 1 ]] && resize 2>> $LOG_FILE
			get_read_write_state
			pack 2>> $LOG_FILE
			flashable_package 2>> $LOG_FILE
			cleanup
			exit;;
		"")
			help_me
			echo "You need to enter the necessary parameters"
			exit;;
		*)
			help_me
			echo "$1 is not a valid command"
			exit;;

	esac
done


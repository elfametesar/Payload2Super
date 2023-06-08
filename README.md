# Payload2Super

```
OPTION 1: pay2sup.sh [-rw|--read-write] [-r|--resize] payload.bin|super.img|rom.zip|/dev/block/by-name/super
OPTION 2: pay2sup.sh [-rw|--read-write] [-r|--resize] [-c|--continue]

-rw | --read-write           = Grants write access to all the partitions.

-r  | --resize	             = Resizes partitions based on user input. User input will be asked during the program.

-dfe | --disable-encryption  = Disables Android's file encryption. This parameter requires read&write partitions.

-t  | --thread	             = Certain parts of the program are multitaskable. If you wish to make the program faster, you can specify a number here.

-c  | --continue             = Continues the process if the program had to quit early. Do not specify a payload file with this option. NOTE: This option could be risky depending on which part of the process the program exited. Use only if you know what you're doing.

-h  | --help	             = Prints out this help message.

Note that --continue or payload.zip|.bin flag has to come after all other flags otherwise other flags will be ignored. You should not use payload.zip|.bin and --continue flags mixed with together. They are mutually exclusive.

```

This tool has only been tested on POCO F3 device, and ~~is compatible with devices that have the same type of super partition scheme.~~ This tool is aimed to support multiple devices, however it requires testers, which I have none. You are free to test it on your device and give feedbacks.

It basically converts any payload flashable ROMs into super flashables to make flashing easier and faster. You can also repack super flashables to grant them read&write access and increase/decrease partition sizes or disable Android's file encryption.

## FEATURES
 - Can convert payload flashables to super flashables
 - Can repack super flashables from zips or /dev/block/by-name/super partition
 - Can grant partitions read and write access
 - Can increase/shrink partitions
 - Can disable Android's file encryption
 - Can use multi-threads to make process faster
 - Can continue if the program has exited in the middle of a process.

# FAQ
 - I get an error while repacking super, or resizing partitions, saying partition sizes exceed the super block size, what do I do?

This happens more often because the ROM you're converting is EROFS and while converting to EXT4, it has to get bigger because of the filesystems' compression rates. If the source ROM is too big, this error can happen.


# To get this tool

Download in the releases section and flash it.

# Tested on

- POCO F3
- Motorola G20

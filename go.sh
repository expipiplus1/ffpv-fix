#!/usr/bin/env bash

arm-none-eabi-gcc -mthumb -march=armv6-m -mlittle-endian -mcpu=cortex-m0 -O0 wait.c -c
arm-none-eabi-gcc -T link.ld -nostartfiles wait.o -o wait
arm-none-eabi-objcopy --output-target=ihex wait wait.hex
srec_cat VTX2G4_national_STLINK_Update_09Apr2019.hex -I wait.hex -I -o combined.hex -Intel -line-length=44
arm-none-eabi-objcopy --input-target=ihex --output-target=binary combined.hex combined.bin
address=$(arm-none-eabi-nm -A wait | grep myWait | sed 's/.*:\([[:xdigit:]]*\) .*/\1/')
radare2 -m 0x08000000 -A -a arm -b16 -e asm.cpu=cortex -w combined.bin -c "s 0x08005518; wa bl 0x$address" -qq
arm-none-eabi-objcopy --input-target=binary --output-target=ihex --change-addresses 0x08000000 combined.bin combined.hex

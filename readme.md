# Fixing the broken firmware on the FuriousFPV 2.4GHz video TX

## What's wrong.

The most recent version of the firmware sometimes only sends a single byte on
the serial connection to the flight controller. This happens most often when the
VTX and the flight controller are powered up at the same time. If the VTX is
powered on after the flight controller then it seems to function.

To test this:

- Connect the flight controller and VTX.
- Power them up simultaneously.
- Observe that the VTX is not controllable from the flight controller.
  - An easy way to do this is to put some debug sensor writes in
    `vtx_ffpv24g.c` in inav.
- Power cycle the VTX.
- Observe that it is now functioning correctly.

I hypothesise that the UART handler on the VTX is getting into a bad state
during powerup because of a bad state on the serial connection which hasn't yet
been initialized by the flight controller.

## The fix

Sadly putting the VTX initialization code as high as possible in inav's startup
code doesn't solve this issue. So, instead of speeding up the flight
controller's side of things, perhaps we can slow down the VTX's startup.

We can do this by inserting a sleep into the startup routing in the VTX. Sadly
the firmware is not open source, but that won't stop us.

### Where to put the sleep

First we'll go to the
[datasheet](https://www.st.com/content/ccc/resource/technical/document/reference_manual/cf/10/a8/c4/29/fb/4c/42/DM00091010.pdf/files/DM00091010.pdf/jcr:content/translations/en.DM00091010.pdf)
for this chip and look in the interrupt vector table for the reset entry. We
can see it's at offset 0x04. We'll follow the chain here until basic things
like the stack have been set up, and put the sleep in place just before the
peripherals are initialized.

Download the firmware from
[https://furiousfpv.com/download.php](https://furiousfpv.com/download.php), the
file is called `Update_VTX2G4`. Extract
`VTX2G4_national_STLINK_Update_09Apr2019.hex`, it has sha256 hash
`c2291b9a292178a5169585f1e8047bd8ad084389e5eff174b138d812e4c7088f`.

Using `radare2 -m 0x08000000 -A -a arm -b16 -e asm.cpu=cortex firmware.bin`

Generate `firmware.bin` with: `arm-none-eabi-objcopy --input-target=ihex
--output-target=binary VTX2G4_national_STLINK_Update_09Apr2019.hex firmware.bin`

Examine the contents of `0x08000004`:

- run `pd 1 @0x08000004` to see `0x08000004      .dword 0x080000cd`
- This address has the LSB set to indicate that the processor should be put
  into Thumb mode.

Looking at the block at `0x080000cc`:

```
[0x080000c0]> pd 10 @0x080000cc
            0x080000cc  ~   0448           ldr r0, aav.0x08003a55      ; [0x80000e0:4]=0x8003a55 aav.0x08003a55
            ;-- aav.0x080000cd:
            ; UNKNOWN XREF from fcn.08000000 (0x8000004)
            0x080000cd                    unaligned
            0x080000ce      8047           blx r0
            0x080000d0      0448           ldr r0, aav.0x080000b9      ; [0x80000e4:4]=0x80000b9 aav.0x080000b9
            0x080000d2      0047           bx r0
```

We can see here that this function makes two calls, the first to `0x08003a54`.
Looking at `0x08003a54` we can see it's poking around at `0x40021000`:

```
[0x080000c0]> pd 10 @0x08003a54
            ; CALL XREF from aav.0x080000cd (+0x1)
            0x08003a54  ~   1348           ldr r0, [0x08003aa4]        ; [0x8003aa4:4]=0x40021000
            ;-- aav.0x08003a55:
            ; UNKNOWN XREF from aav.0x080000df (+0x1)
            0x08003a55                    unaligned
            0x08003a56      0168           ldr r1, [r0]
            0x08003a58      0122           movs r2, 1
            0x08003a5a      1143           orrs r1, r2
            0x08003a5c      0160           str r1, [r0]
```

This is where the Reset and Clock Control registers are, better not mess with
this function.

The other function which `0x080000cc` calls is `0x080000b9`. The block at
`0x080000b8` sets up the stack pointer and calls `0x080007a8`:

```
[0x080000c0]> pd 10 @0x080000b8
|           ; CODE XREF from aav.0x080000cd (+0x5)
|           0x080000b8  ~   0348           ldr r0, [0x080000c8]        ; [0x80000c8:4]=0x200025d0
|           ;-- aav.0x080000b9:
|           ; UNKNOWN XREF from aav.0x080000df (+0x5)
|           0x080000b9                    unaligned
|           0x080000ba      8546           mov sp, r0
\           0x080000bc      00f074fb       bl fcn.080007a8
```

`0x080007a8` sets up some stuff (looks like calling a couple of virtual
functions on two structs at `0x08006998` and `0x080069a8`) and then calls
`0x080000c0` which immediately calls `0x08005519`. It's here where we'll put
the delaying function.

### Inserting the delay

Observe that the first thing `0x08005518` does is jump to `0x08001fd0`.

```
[0x08000000]> pd 1 @0x08005518
            ; CODE XREF from fcn.080000c0 (0x80000c2)
            0x08005518  ~   fcf75afd       bl fcn.08001fd0
```

We will wrap this function with a sleep.

Run radare again with `-w` to open the file in write mode, or execute `oo+` to
reopen the existing firmware in write mode.

Change this branch to a branch to where our new function will live
(`0x08006a90`, it's the first unused address in the flash).

```
[0x08000000]> s 0x08005518
[0x08005518]> wa bl 0x08006a90
Written 4 byte(s) (bl 0x08006a90) = wx 01f0bafa
```

Convert this back into intel hex format now: `arm-none-eabi-objcopy
--input-target=binary --output-target=ihex firmware.bin firmware.hex`

Now, create a function which delays for a bit and then calls `0x08001fd0`, the
source for this is in `wait.c`. Place this function at `0x08006a90` with the
linker script `link.ld`.

Merge these hex files using `srec_cat firmware.hex -I wait.hex -I -o
combined.hex -Intel -line-length=44`, `srec_cat` can be found in the `srecord`
utilities.

#### Flashing the new firmware to the board

Using a ST-Link V2 programmer.

Wire GND and 3.3V up to the programmer.

> I had to power the VTX externally, or I got a bunch of errors like `init mode
> failed (unable to connect to the target)` from `openocd` or `unknown device`
> from `st-info --probe`. If powering it externally, don't connect the 3.3V pad
> to the st-link programmer.

- Wire `SWDIO` to the unlabeled pad on the edge of the board above the `U5` label.
- Wire `SWCLK` to the adjacent unlabeled pad further from the edge.

Flash the new firmware to the board using openocd.

```
$ openocd -f interface/stlink-v2.cfg -f target/stm32f0x.cfg \
    -c "init; reset halt; flash write_image erase unlock /path/to/combined.hex; reset halt; exit"
```

You may need to unlock the chip first using the `stm32f0x unlock 0` openocd
command, I had trouble getting the autounlock to work.

Power cycle the board and FC and observe that the settings can be changed from
the flight controller even if they are powered up at the same time.

### Troubleshooting

#### Examining the program on the VTX with openocd and gdb:

- Create an elf binary for the firmware `arm-none-eabi-objcopy
  --input-target=binary --output-target=elf32-little combined.bin combined.elf`
- Wire up the VTX as above
- Start openocd and reset the board: `openocd -f interface/stlink-v2.cfg -f
  target/stm32f0x.cfg -c "init; reset halt;"`
- Start gdb and connect to openocd: `gdb combined.elf`, `target remote localhost:3333`

You now have a gdb session debugging the live program on the VTX. If you want
to check that the sleeping function is being run, set a breakpoint there:

- Add a breakpoint `break *0x08006a90`
- Reset the VTX: `monitor reset halt`
- Run the program `continue`
- Observe that the breakpoint has been hit

## TODO

- Add functionality for reporting the temperature over UART, this is advertised in the spec, but at the moment always returns 30 degrees.

- More sophisticated waiting

- What's going on at `0x08006998`? Worryingly it references `0x08006a90` which
  is where our new function is at.

```
  ;-- aav.0x08006998:
0x08006998           .dword 0x080069b8 ; aav.0x080069b8
0x0800699c           .dword 0x20000000 ; cpsr
0x080069a0           .dword 0x000000d8
0x080069a4           .dword 0x08004c56 ; aav.0x08004c56
0x080069a8           .dword 0x08006a90 ; fcn.08006a90
0x080069ac           .dword 0x200000d8
0x080069b0           .dword 0x000024f8
0x080069b4           .dword 0x08004c66 ; aav.0x08004c66
```

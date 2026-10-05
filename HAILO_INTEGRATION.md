# Hailo-8 Integration Plan for Raspberry Pi 5 AOSP 17

This document describes the intended integration layout for a Hailo-8 / Hailo-8L accelerator in this Raspberry Pi 5 Android device tree.

## Goal

Keep the AI accelerator stack out of the Android UI layer and split it into:

- kernel / boot-time hardware enablement
- vendor userspace runtime and daemon
- Android Car UI consuming only inference results

This keeps the system maintainable and lets the kernel tree and vendor userspace evolve independently.

## Recommended repository roles

### Local repository layout

This workspace now has four relevant repositories for Raspberry Pi 5 Android integration:

- `android_device_brcm_rpi5`: Android device tree, init, sepolicy, product definitions, native Android-facing service scaffold
- `android_device_brcm_rpi5-kernel`: packaged kernel artifacts copied into the Android build (`Image`, dtbs, overlays, modules)
- `android_kernel_manifest`: kernel repo manifest that pins the Raspberry Pi kernel fork and vendor repository
- `android_kernel_brcm_rpi`: external Raspberry Pi kernel fork where Hailo PCIe driver integration must happen
- `proprietary_vendor_brcm`: vendor firmware and model assets copied into `vendor.img`

### 1. Kernel / boot image
Use the Raspberry Pi kernel base and add the Hailo PCIe driver stack here.

In this project, the kernel image is produced from an external fork of `raspberrypi/linux` and copied into the device build as `device/brcm/rpi5-kernel/Image`.

Responsibilities:

- enable PCIe for the M.2 HAT+ path
- load or build in the Hailo PCIe driver
- expose the device to userspace
- support firmware loading for the accelerator
- keep very early boot logic minimal and robust

This is the place for:

- kernel config
- device tree / overlay changes
- Hailo kernel module or in-tree driver integration
- boot-time module loading if the driver is modular

Expected ownership split:

- external kernel fork: Hailo PCIe driver integration, kernel config, DT changes, module build
- this device tree: boot image packaging, vendor userspace packaging, init, sepolicy, Android-facing service integration

Current kernel packaging flow:

- build `//common:rpi5` in `android_kernel_brcm_rpi`
- export artifacts with `tools/rpi/export_android_rpi5_kernel.ps1` or `tools/rpi/export_android_rpi5_kernel.sh`
- consume the exported `Image`, DTBs, overlays, and modules from `android_device_brcm_rpi5-kernel`

### 2. Vendor image
Place the runtime, firmware, and service logic here.

Responsibilities:

- HailoRT runtime libraries
- Hailo CLI or validation tools
- Hailo firmware blobs
- a small native daemon for inference tasks
- init rc service definitions
- SELinux policy additions
- optional GStreamer plugins if used

This is the correct place for:

- vendor/bin/hailo daemon
- vendor/lib64/libhailort.so
- vendor/etc/init/*.rc
- vendor/etc/selinux or device sepolicy rules
- vendor firmware assets

### 3. System / product image
Keep Android UI, app-facing logic, and Car-related screens here.

Responsibilities:

- display warnings and camera summaries
- receive inference events from the vendor daemon
- render UI
- optionally forward events to CarService / app logic

This is the wrong place for the AI runtime itself.

## What belongs in boot

The boot image should contain only the parts needed to make the Hailo hardware visible early.

Suggested contents:

- Raspberry Pi kernel
- PCIe support
- Hailo kernel driver or module
- device tree / overlay adjustments
- early module load hook if required

Do not put these into boot:

- HailoRT runtime
- models
- Python examples
- Android app code

## What belongs in vendor

Vendor is the main Hailo execution layer.

Suggested contents:

- libhailort and related shared libraries
- hailortcli for debugging
- native Hailo daemon
- configuration files
- firmware files
- SELinux policy
- init rc service file

Suggested file locations:

- vendor/bin/hailo_service
- vendor/lib64/libhailort.so
- vendor/etc/init/hailo_service.rc
- vendor/firmware/hailo/*

Expected Hailo-8 firmware files from the imported kernel driver:

- `vendor/firmware/hailo/hailo8_fw.bin`
- `vendor/firmware/hailo/hailo8_board_cfg.bin`
- `vendor/firmware/hailo/hailo8_fw_cfg.bin`

`hailo8_fw.bin` is mandatory; the other two are optional. Fetch it with
`proprietary_vendor_brcm/rpi5/tools/fetch_hailo_firmware.ps1` (default version 4.24.0, SHA256 verified).
`rpi5-vendor.mk` packages whichever of these files exist.

The kernel module is loaded at boot (`on boot` in `hailo_service.rc`). `hailo_service` probes
`/dev/hailo0` via ioctl and publishes its state in `vendor.hailo.status`
(`starting`, `fw_missing`, `waiting_device`, `fw_not_loaded`, `error`, `ready`, `stopped`).

`libhailort.so` is built with `proprietary_vendor_brcm/rpi5/tools/build_hailort_android.sh` (Android NDK, run on
Linux/WSL2) and packaged to `/vendor/lib64` by `rpi5-vendor.mk` when present. `hailo_service` loads it with `dlopen`
after the driver reports ready, creates a vdevice, configures `default.hef` (fetch with `fetch_hailo_model.ps1`) and
publishes the outcome in `vendor.hailo.rt_status` (`ok`, `lib_missing`, `lib_error`, `device_error`, `model_missing`,
`model_error`). Because of the `dlopen`, the image builds and boots without the library.

Current scaffold in this repository:

- `hailo/Android.bp`
- `hailo/hailo_service.c`
- `hailo/hailo_service.rc`
- `hailo/hailo_service.conf`

Current vendor placeholder paths:

- `vendor/brcm/rpi5/proprietary/vendor/firmware/hailo/`
- `vendor/brcm/rpi5/proprietary/vendor/etc/hailo/models/`

## Suggested Android build targets

The build should be split into three visible layers:

### boot / kernel layer
- kernel image
- dtb / dtbo if needed
- Hailo PCIe driver

### vendor layer
- HailoRT libraries
- Hailo daemon
- firmware
- sepolicy

### product / system layer
- Car UI application
- client-side binder or socket bridge

## Minimal Hailo service design

The first version of the Android-side service should be small and resilient.

### Responsibilities

1. Initialize the device
   - detect Hailo hardware
   - load runtime state
   - verify firmware and model availability

2. Run inference
   - accept frames from camera pipeline
   - execute inference
   - post-process results

3. Publish results
   - detected object class
   - confidence
   - bounding boxes
   - warnings
   - timestamps

4. Handle errors
   - device disappearance
   - timeout
   - thermal or performance fallback
   - automatic restart via init

### IPC options

Recommended first choices:

- AIDL / Binder
- local socket
- lightweight native callback service

Keep the Android app as a consumer only.

## Suggested boot sequence

1. Bootloader loads the kernel
2. Kernel initializes PCIe and the Hailo driver
3. init starts the Hailo daemon from vendor
4. daemon opens the accelerator through HailoRT
5. daemon emits inference events
6. Android UI shows the result

## Suggested implementation order

### Phase 1
- kernel sees the Hailo device
- HailoRT can open it
- run a trivial test daemon

### Phase 2
- camera pipeline produces frames
- daemon performs one real model inference
- events reach Android

### Phase 3
- integrate Car UI and driver alerts
- add lane / object / DMS features

## Suggested integration points in this tree

This device tree already contains the relevant hooks:

- device configuration: `device.mk`
- board configuration: `BoardConfig.mk`
- early init / ramdisk: `ramdisk/`
- SELinux policy: `sepolicy/`
- vendor properties: `vendor.prop`

The Hailo integration should be wired into those existing locations instead of adding AI logic to the app layer.

## Practical recommendation

For this project, the cleanest stack is:

- Raspberry Pi kernel tree for boot and PCIe enablement
- Hailo PCIe driver in the kernel stack
- HailoRT in vendor userspace
- native daemon in vendor/bin
- Android Car UI as a thin consumer of inference events

This keeps the build maintainable and avoids coupling the AI pipeline to the UI layer.

## Test matrix

Use [HAILO_ADB_TEST_MATRIX.md](HAILO_ADB_TEST_MATRIX.md) to validate the kernel and vendor integration before adding any app layer.

# Hailo ADB Test Matrix

This matrix is intended to validate the Hailo kernel and vendor integration without an app.

## Scope

- kernel module loading
- device node creation
- firmware availability
- vendor service startup
- basic runtime health checks
- failure handling

## Test phases

### Phase 1: kernel bring-up

| ID | Check | ADB command | Expected result |
|---|---|---|---|
| P1 | Hailo on PCIe bus | adb shell "cat /sys/bus/pci/devices/*/vendor" | 0x1e60 present (needs dtparam=pciex1 in boot/config.txt) |
| K6 | Firmware search path | adb shell cat /proc/cmdline | contains firmware_class.path=/vendor/firmware |
| K1 | Hailo module present | adb shell ls /vendor/lib/modules | hailo_pci.ko is present after kernel export |
| K2 | Module loads | adb shell su -c "insmod /vendor/lib/modules/hailo_pci.ko" | No error; dmesg shows Hailo probe logs |
| K3 | Device node exists | adb shell ls -l /dev/hailo* | /dev/hailo0 or similar appears |
| K4 | Kernel logs | adb shell dmesg | Hailo PCIe, firmware, and device registration logs are visible |
| K5 | Firmware files visible | adb shell ls -l /vendor/firmware/hailo | hailo8_fw.bin, hailo8_board_cfg.bin, hailo8_fw_cfg.bin are present |

### Phase 2: vendor service bring-up

| ID | Check | ADB command | Expected result |
|---|---|---|---|
| V1 | Hailo service property | adb shell getprop persist.vendor.hailo.enabled | Returns 0 or 1 as configured |
| V2 | Start service path | adb shell setprop persist.vendor.hailo.enabled 1 | Service starts (the module itself is loaded at boot) |
| V3 | Service status | adb shell getprop init.svc.vendor.hailo_service | running |
| V4 | Service logs | adb shell logcat -d -s hailo_service | Startup, firmware check and device probe logs are visible |
| V5 | Config file present | adb shell ls -l /vendor/etc/hailo/hailo_service.conf | Config file exists and is readable |
| V6 | Service status property | adb shell getprop vendor.hailo.status | ready (other values: starting, fw_missing, waiting_device, fw_not_loaded, error, stopped) |
| V7 | HailoRT runtime probe | adb shell getprop vendor.hailo.rt_status | ok (libhailort loaded, vdevice created, model configured). Other values: not_probed, lib_missing, lib_error, device_error, model_missing, model_error |

### Phase 3: runtime sanity

| ID | Check | ADB command | Expected result |
|---|---|---|---|
| R1 | Open device from userspace | adb shell su -c "cat /dev/hailo0 > /dev/null" | No permission or device errors |
| R2 | Driver version | adb shell dmesg | Hailo driver version is reported |
| R3 | Firmware status | adb shell dmesg | Firmware load completes successfully |
| R4 | Restart path | adb shell setprop persist.vendor.hailo.enabled 0 then 1 | Service restarts cleanly |

### Phase 4: negative tests

| ID | Check | ADB command | Expected result |
|---|---|---|---|
| N1 | Missing firmware | remove one firmware file, then reload module | Probe fails with clear firmware error |
| N2 | Missing module | adb shell ls /vendor/lib/modules/hailo_pci.ko | Failure is obvious in packaging stage |
| N3 | Service disabled | adb shell setprop persist.vendor.hailo.enabled 0 | Service stops |
| N4 | Module unload | adb shell su -c "rmmod hailo_pci" | Module unloads or reports a clear dependency error |

## Suggested test order

1. Build and export the kernel.
2. Flash boot/vendor images.
3. Verify K1 to K5.
4. Verify V1 to V5.
5. Verify R1 to R4.
6. Run the negative tests.

## Notes

- If a test requires root, use adb root or the equivalent privileged shell on your build.
- If the module is built into the kernel instead of a module, replace insmod and rmmod checks with boot-time dmesg validation.
- This matrix is intentionally app-free so that kernel and vendor integration can be validated early.
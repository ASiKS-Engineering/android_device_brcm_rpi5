Raspberry Vanilla AOSP 17 device configuration for Raspberry Pi 5.

See [HAILO_INTEGRATION.md](HAILO_INTEGRATION.md) for the proposed Hailo-8 boot, vendor, and Android service layout.
See [HAILO_ADB_TEST_MATRIX.md](HAILO_ADB_TEST_MATRIX.md) for the app-free ADB validation matrix.

On the automotive build, enable developer options and open System > Developer tools >
Raspberry Pi to view the device model, Android and kernel versions, and elapsed time since
boot when the screen opens. The status screen is read-only and does not diagnose boot health.
The existing Power menu is unchanged. The recovery reboot and automatic boot-failure
fallback have not been verified and should not be relied on until the bootloader
configuration and recovery path are tested.

/*
 * set_reboot_order - arm a one-shot alternative boot order for the next reboot.
 *
 * Usage: set_reboot_order sd_nvme | default
 *
 * The Raspberry Pi 5 bootloader has no mailbox tag that carries a BOOT_ORDER value. The order
 * is selected by the bootloader EEPROM config, which supports a [tryboot] section that is only
 * active when the one-shot "tryboot" reboot flag is set:
 *
 *     [all]
 *     BOOT_ORDER=0xf16      # default: NVMe -> SD
 *     [tryboot]
 *     BOOT_ORDER=0xf61      # one-shot: SD -> NVMe
 *
 * (BOOT_ORDER digits are read right to left: 1 = SD, 6 = NVMe, f = restart loop.)
 *
 * This tool only sets or clears that tryboot flag through the VideoCore mailbox
 * (RPI_FIRMWARE_SET_REBOOT_FLAGS). The firmware clears the flag by itself on the next reboot.
 */

#include <android/log.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define LOG_TAG "set_reboot_order"

#define VCIO_DEVICE "/dev/vcio"
#define VCIO_IOC_MAGIC 100
#define IOCTL_MBOX_PROPERTY _IOWR(VCIO_IOC_MAGIC, 0, char *)

#define RPI_FIRMWARE_SET_REBOOT_FLAGS 0x00038064u
#define RPI_REBOOT_FLAG_TRYBOOT 0x1u
#define MBOX_REQUEST_SUCCESS 0x80000000u

static int set_reboot_flags(uint32_t flags)
{
    uint32_t msg[7] = {
        sizeof(msg),                    /* total buffer size in bytes */
        0,                              /* process request */
        RPI_FIRMWARE_SET_REBOOT_FLAGS,  /* tag */
        4,                              /* value buffer size */
        4,                              /* request size */
        flags,                          /* value */
        0,                              /* end tag */
    };

    int fd = open(VCIO_DEVICE, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "open(%s): %s", VCIO_DEVICE,
                            strerror(errno));
        return -1;
    }

    int ret = ioctl(fd, IOCTL_MBOX_PROPERTY, msg);
    int err = errno;
    close(fd);

    if (ret < 0) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "mailbox ioctl: %s", strerror(err));
        return -1;
    }
    if (msg[1] != MBOX_REQUEST_SUCCESS) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "firmware rejected request: 0x%08x",
                            msg[1]);
        return -1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "usage: %s sd_nvme|default", argv[0]);
        return 2;
    }

    uint32_t flags;
    if (strcmp(argv[1], "sd_nvme") == 0) {
        flags = RPI_REBOOT_FLAG_TRYBOOT;
    } else if (strcmp(argv[1], "default") == 0) {
        flags = 0;
    } else {
        __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, "unknown order '%s'", argv[1]);
        return 2;
    }

    if (set_reboot_flags(flags) != 0)
        return 1;

    __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "reboot order '%s' armed", argv[1]);
    return 0;
}

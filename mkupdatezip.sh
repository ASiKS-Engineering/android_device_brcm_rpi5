#!/bin/bash

#
# SPDX-License-Identifier: Apache-2.0
#
# Builds a TWRP-flashable update zip (boot, system, vendor) from the current build output.
# Copy the zip to a USB stick, reboot into TWRP and use Install -> Select Storage -> USB.
# /data stays untouched.
#
# Usage: mkupdatezip.sh      (after lunch and 'make bootimage systemimage vendorimage')

exit_with_error() {
  echo "$@"
  exit 1
}

[ -n "${TARGET_PRODUCT}" ] || exit_with_error "TARGET_PRODUCT environment variable is not set. Run lunch first."
[ -n "${ANDROID_PRODUCT_OUT}" ] || exit_with_error "ANDROID_PRODUCT_OUT environment variable is not set. Run lunch first."

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# <image file>:<partition suffix on the NVMe>, see mkimg.sh for the layout
IMAGES="boot.img:p1 system.img:p5 vendor.img:p6"

for ENTRY in ${IMAGES}; do
  FILE=${ENTRY%%:*}
  [ -f "${ANDROID_PRODUCT_OUT}/${FILE}" ] || exit_with_error "${FILE} not found. Run 'make ${FILE%.img}image' first."
done

VERSION=RaspberryVanillaAOSP17
DATE=$(date +%Y%m%d)
TARGET=$(echo "${TARGET_PRODUCT}" | sed 's/^aosp_//')
ZIPNAME=${VERSION}-${DATE}-${TARGET}-update.zip
ZIPPATH=${ANDROID_PRODUCT_OUT}/${ZIPNAME}

STAGE=$(mktemp -d) || exit_with_error "mktemp failed"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/META-INF/com/google/android"
cp "${SCRIPT_DIR}/updatezip/update-binary" "${STAGE}/META-INF/com/google/android/update-binary"
chmod 755 "${STAGE}/META-INF/com/google/android/update-binary"
echo "# intentionally empty, the update-binary is a shell script" > "${STAGE}/META-INF/com/google/android/updater-script"

FINGERPRINT_FILE=${ANDROID_PRODUCT_OUT}/build_fingerprint-${TARGET_PRODUCT}.txt
if [ -f "${FINGERPRINT_FILE}" ]; then
  tr -d '\n' < "${FINGERPRINT_FILE}" > "${STAGE}/fingerprint.txt"
else
  echo -n "${TARGET_PRODUCT}-${DATE}" > "${STAGE}/fingerprint.txt"
fi

: > "${STAGE}/images.txt"
for ENTRY in ${IMAGES}; do
  FILE=${ENTRY%%:*}
  PART=${ENTRY##*:}
  echo "Hashing ${FILE}..."
  SIZE=$(stat -c %s "${ANDROID_PRODUCT_OUT}/${FILE}")
  SHA=$(sha256sum "${ANDROID_PRODUCT_OUT}/${FILE}" | cut -d' ' -f1)
  echo "${FILE} ${PART} ${SIZE} ${SHA}" >> "${STAGE}/images.txt"
  ln -s "${ANDROID_PRODUCT_OUT}/${FILE}" "${STAGE}/${FILE}"
done

echo "Creating ${ZIPPATH}..."
rm -f "${ZIPPATH}"
(cd "${STAGE}" && zip -q -X -1 "${ZIPPATH}" META-INF/com/google/android/update-binary \
    META-INF/com/google/android/updater-script fingerprint.txt images.txt \
    $(for ENTRY in ${IMAGES}; do echo "${ENTRY%%:*}"; done)) || exit_with_error "zip failed"

echo "Done, created ${ZIPPATH}!"
exit 0

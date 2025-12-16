function pre_update_initramfs__301_config_fit_ota_script(){

    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        display_alert "ota config" "Installing FIT OTA support into initramfs" "info"
        local root_dir="${MOUNT}"
        # Copy 99-copy-tools hook file
        local hook_src="${SRC}/extensions/armbian-ota/armbian_ota_tools/99-copy-tools"
        local hook_dst="${root_dir}/etc/initramfs-tools/hooks/zz-copy-tools"

        if [[ -f "${hook_src}" ]]; then
            cp "${hook_src}" "${hook_dst}" || {
                display_alert "ota config" "Failed to copy 99-copy-toolshook" "err"
                return 1
            }
            chmod +x "${hook_dst}"
            display_alert "ota config" "99-copy-tools hook installation completed" "info"
        else
            display_alert "ota config" "99-copy-tools source file not found: ${hook_src}" "warn"
        fi

        # Copy fit-ota.sh script to initramfs
        display_alert "ota config" "Installing fit-ota script" "info"
        # Copy fit-ota.sh script
        local ota_src="${SRC}/extensions/armbian-ota/armbian_ota_tools/fit-ota"
        local ota_dst="${root_dir}/etc/initramfs-tools/scripts/init-premount/1-fit-ota"

        if [[ -f "${ota_src}" ]]; then
            cp "${ota_src}" "${ota_dst}" || {
                display_alert "ota config" "Failed to copy fit-ota script" "err"
                return 1
            }
            chmod +x "${ota_dst}"
            display_alert "ota config" "fit-ota script installation completed" "info"
        else
            display_alert "ota config" "fit-ota.sh source file not found: ${ota_src}" "warn"
        fi
    fi

}
function pre_umount_final_image__901_create_ota_image() {
    display_alert "pre_umount_final_image__901 Extracting partition images from loop device" "Detecting and extracting partitions from ${LOOP}" "info"


    # Check for secure boot and auto ota configuration
    local secure_boot_and_decrypt="no"
    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        secure_boot_and_decrypt="yes"
        display_alert "Secure boot and auto ota enabled" "Using FIT image workflow" "info"
    fi

    # Create temporary directory for OTA package building
    local ota_temp_dir="${WORKDIR}/ota_package_build_$$"
    mkdir -p "$ota_temp_dir"

    # Check if loop device exists
    if [[ ! -b "${LOOP}" ]]; then
        display_alert "Error: Loop device not found" "${LOOP}" "err"
        return 1
    fi

    # Check required tools
    local required_tools="tar mount"
    for tool in $required_tools; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            display_alert "Error: Missing required tool" "$tool" "err"
            return 1
        fi
    done

    # For secure boot and auto ota, we don't need to detect partitions
    local boot_partition=""
    local rootfs_partition=""

    if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
        display_alert "Secure boot mode" "Skipping partition detection" "info"
        # In secure boot mode, we'll use /dev/mapper/armbian-root directly
        rootfs_partition="encrypted"
    else
        # Normal mode: Dynamically detect boot and rootfs partitions
        local partitions_found=()

        # Get all partition information (including size, mount point)
        local partition_info
        partition_info=$(lsblk -ln -o NAME,SIZE,MOUNTPOINT "${LOOP}" | grep -E "${LOOP##*/}p?[0-9]+" | sort)

        # Print partition_info for debugging
        display_alert "Loop device partitions" "${LOOP}" "info"
        display_alert "DEBUG: partition_info content" "=== START ===" "info"
        echo "$partition_info" | while IFS= read -r line; do
            display_alert "DEBUG partition_info line" "[$line]" "info"
        done
        display_alert "DEBUG: partition_info content" "=== END ===" "info"

        if [[ -z "$partition_info" ]]; then
            display_alert "Error: No partitions found on loop device" "${LOOP}" "err"
            return 1
        fi

        # Iterate through partitions, using mount point detection strategy
        while IFS= read -r partition_line; do
            if [[ -n "$partition_line" ]]; then
                display_alert "DEBUG raw line" "[$partition_line]" "debug"

                # Get clearer information: NAME, SIZE, MOUNTPOINT
                local partition_name=$(echo "$partition_line" | awk '{print $1}')
                local part_size=$(echo "$partition_line" | awk '{print $2}')
                local mount_point=$(echo "$partition_line" | awk '{print $3}')

                local full_path="/dev/$partition_name"

                display_alert "DEBUG parsed fields" "name=${partition_name}, size=${part_size}, mount=${mount_point}" "debug"

                if [[ -b "$full_path" ]]; then
                    partitions_found+=("$full_path")

                    # Use mount point information to differentiate
                    if [[ -n "$mount_point" ]]; then
                        # Detect boot partition: mount path contains "/boot"
                        if [[ "$mount_point" == *"/boot" && -z "$boot_partition" ]]; then
                            boot_partition="$full_path"
                            display_alert "Detected boot partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                            continue
                        fi

                        # Detect rootfs partition: mounted at root directory (does not end with "/boot")
                        if [[ "$mount_point" != *"/boot" && -z "$rootfs_partition" ]]; then
                            rootfs_partition="$full_path"
                            display_alert "Detected rootfs partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                            continue
                        fi
                    fi
                fi
            fi
        done <<< "$partition_info"

        # Ensure at least rootfs partition exists
        if [[ -z "$rootfs_partition" ]]; then
            display_alert "Error: Could not identify rootfs partition" "" "err"
            return 1
        fi
    fi

    # Get partition information
    local boot_size=0
    local rootfs_size=0

    if [[ "$secure_boot_and_decrypt" != "yes" ]]; then
        rootfs_size=$(blockdev --getsize64 "$rootfs_partition" 2>/dev/null || echo "0")
        if [[ -n "$boot_partition" ]]; then
            boot_size=$(blockdev --getsize64 "$boot_partition" 2>/dev/null || echo "0")
        fi
        display_alert "Found partitions" "boot: ${boot_partition:-"none"} (${boot_size} bytes), rootfs: ${rootfs_partition} (${rootfs_size} bytes)" "info"
    else
        display_alert "Secure boot mode active" "Using boot.itb and encrypted rootfs" "info"
    fi

    # Create temporary mount points
    local boot_mount="${WORKDIR}/boot_mount"
    local rootfs_mount="${WORKDIR}/rootfs_mount"
    mkdir -p "$boot_mount" "$rootfs_mount"

    local extract_boot=false
    local extract_rootfs=true  # rootfs always extracted

    # Define tar package paths
    local boot_tar="${ota_temp_dir}/boot.tar.gz"
    local rootfs_tar="${ota_temp_dir}/rootfs.tar.gz"

    # SHA256 checksum files to be included in final OTA tarball
    local boot_sha_file="${ota_temp_dir}/boot.sha256"
    local rootfs_sha_file="${ota_temp_dir}/rootfs.sha256"

    # Handle boot partition content
    if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
        local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
        local uboot_dir="${uboot_src}"
        # For secure boot with auto ota, look for boot.itb in the chroot
        local boot_itb_source="${uboot_dir}/fit/boot.itb"
        if [[ -f "$boot_itb_source" ]]; then
            display_alert "Copying FIT boot image" "${boot_itb_source} -> boot.itb" "info"
            if cp "$boot_itb_source" "${ota_temp_dir}/boot.itb"; then
                local boot_itb_size=$(stat -c%s "${ota_temp_dir}/boot.itb")
                display_alert "FIT boot image copied" "boot.itb size: $((boot_itb_size / 1024)) KB" "info"

                # Generate SHA256 for boot.itb
                if command -v sha256sum >/dev/null 2>&1; then
                    (cd "${ota_temp_dir}" && sha256sum "boot.itb" > "${boot_sha_file}") || {
                        display_alert "Warning: Failed to generate SHA256 for boot.itb" "${boot_sha_file}" "warn"
                    }
                else
                    display_alert "Warning: sha256sum not available; skipping boot.itb SHA256" "" "warn"
                fi
            else
                display_alert "Warning: Failed to copy boot.itb" "" "warn"
            fi
        else
            display_alert "Warning: boot.itb not found at ${boot_itb_source}" "" "warn"
        fi
    elif [[ -n "$boot_partition" && -b "$boot_partition" ]]; then
        # Normal boot partition extraction
        display_alert "Extracting boot partition content" "${boot_partition} -> boot.tar.gz" "info"
        if mount "$boot_partition" "$boot_mount"; then
            # Create boot.tar.gz
            if (cd "$boot_mount" && tar -czf "$boot_tar" .); then
                local boot_tar_size=$(stat -c%s "$boot_tar")
                display_alert "Boot content archived" "boot.tar.gz size: $((boot_tar_size / 1024)) KB" "info"
                display_alert "Boot partition contents" "Found $(find "$boot_mount" -type f | wc -l) files" "debug"
                extract_boot=true

                # Generate SHA256 for boot.tar.gz
                if command -v sha256sum >/dev/null 2>&1; then
                    (cd "${ota_temp_dir}" && sha256sum "boot.tar.gz" > "${boot_sha_file}") || {
                        display_alert "Warning: Failed to generate SHA256 for boot.tar.gz" "${boot_sha_file}" "warn"
                    }
                else
                    display_alert "Warning: sha256sum not available; skipping boot.tar.gz SHA256" "" "warn"
                fi
            else
                umount "$boot_mount" 2>/dev/null || true
                display_alert "Warning: Failed to create boot.tar.gz" "" "warn"
            fi
            umount "$boot_mount" 2>/dev/null || true
        else
            display_alert "Warning: Failed to mount boot partition" "${boot_partition}" "warn"
        fi
    fi

    # Extract rootfs partition content
    local rootfs_source=""

    if [[ "$secure_boot_and_decrypt" == "yes" || "${RK_AUTO_DECRYP}" == "yes" ]]; then
        # For encrypted rootfs, we need to use the mapper device
        rootfs_source="/dev/mapper/armbian-root"
        display_alert "Encrypted rootfs detected" "Using mapper device: ${rootfs_source}" "info"

        # Ensure the encrypted partition is set up
        if [[ ! -e "$rootfs_source" ]]; then
            display_alert "Error: Encrypted mapper device not found" "${rootfs_source}" "err"
            rm -rf "$ota_temp_dir"
            return 1
        fi
    else
        # Normal rootfs partition
        rootfs_source="$rootfs_partition"
    fi

    display_alert "Extracting rootfs partition content" "${rootfs_source} -> rootfs.tar.gz" "info"
    if mount "$rootfs_source" "$rootfs_mount"; then
        # Create rootfs.tar.gz
        if (cd "$rootfs_mount" && tar -czf "$rootfs_tar" --exclude="./dev/*" --exclude="./proc/*" --exclude="./sys/*" --exclude="./tmp/*" --exclude="./run/*" .); then
            local rootfs_tar_size=$(stat -c%s "$rootfs_tar")
            display_alert "Rootfs content archived" "rootfs.tar.gz size: $((rootfs_tar_size / 1024 / 1024)) MB" "info"
            display_alert "Rootfs partition contents" "Found $(find "$rootfs_mount" -type f | wc -l) files" "debug"
            extract_rootfs=true

            # Generate SHA256 for rootfs.tar.gz
            if command -v sha256sum >/dev/null 2>&1; then
                (cd "${ota_temp_dir}" && sha256sum "rootfs.tar.gz" > "${rootfs_sha_file}") || {
                    display_alert "Warning: Failed to generate SHA256 for rootfs.tar.gz" "${rootfs_sha_file}" "warn"
                }
            else
                display_alert "Warning: sha256sum not available; skipping rootfs.tar.gz SHA256" "" "warn"
            fi
        else
            umount "$rootfs_mount" 2>/dev/null || true
            display_alert "Error: Failed to create rootfs.tar.gz" "" "err"
            rm -rf "$ota_temp_dir"
            return 1
        fi
        umount "$rootfs_mount" 2>/dev/null || true
    else
        display_alert "Error: Failed to mount rootfs partition" "${rootfs_source}" "err"
        rm -rf "$ota_temp_dir"
        return 1
    fi

    # Clean up temporary mount points
    rm -rf "$boot_mount" "$rootfs_mount"

    # Verify extraction results

    # Check rootfs.tar.gz (must exist)
    if [[ ! -f "$rootfs_tar" ]]; then
        display_alert "Error: rootfs.tar.gz not found" "" "err"
        return 1
    fi

    # Verify rootfs.tar.gz integrity
    if ! tar -tzf "$rootfs_tar" >/dev/null 2>&1; then
        display_alert "Error: rootfs.tar.gz is corrupted or invalid" "" "err"
        return 1
    fi

    # Verify SHA256 sums if generated
    if [[ -f "${rootfs_sha_file}" ]]; then
        if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${rootfs_sha_file}")" >/dev/null 2>&1); then
            display_alert "Error: rootfs.tar.gz SHA256 verification failed" "${rootfs_sha_file}" "err"
            return 1
        fi
    fi

    if [[ "$secure_boot_and_decrypt" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        # Verify boot.itb exists and is readable
        if [[ ! -r "${ota_temp_dir}/boot.itb" ]]; then
            display_alert "Error: boot.itb is not readable" "" "err"
            return 1
        fi

        if [[ -f "${boot_sha_file}" ]]; then
            if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${boot_sha_file}")" >/dev/null 2>&1); then
                display_alert "Error: boot.itb SHA256 verification failed" "${boot_sha_file}" "err"
                return 1
            fi
        fi

        display_alert "Archive verification completed" "boot.itb and rootfs.tar.gz are valid" "info"
    elif [[ -f "$boot_tar" ]]; then
        if ! tar -tzf "$boot_tar" >/dev/null 2>&1; then
            display_alert "Error: boot.tar.gz is corrupted or invalid" "" "err"
            return 1
        fi

        if [[ -f "${boot_sha_file}" ]]; then
            if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${boot_sha_file}")" >/dev/null 2>&1); then
                display_alert "Error: boot.tar.gz SHA256 verification failed" "${boot_sha_file}" "err"
                return 1
            fi
        fi

        display_alert "Archive verification completed" "boot.tar.gz and rootfs.tar.gz are valid" "info"
    else
        display_alert "Archive verification completed" "rootfs.tar.gz is valid (no boot partition found)" "info"
    fi

    # Display extraction summary
    local summary=""
    if [[ "$secure_boot_and_decrypt" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        summary="boot.itb + rootfs.tar.gz (secure boot)"
    elif [[ -f "$boot_tar" ]]; then
        summary="boot.tar.gz + rootfs.tar.gz"
    else
        summary="rootfs.tar.gz only"
    fi
    display_alert "Extraction summary" "Created $summary" "info"

    # Create final OTA package
    display_alert "Creating final OTA package" "Combining tools and images" "info"

    # Use Armbian official variable to get image name
    local base_image_name=""

	# Get kernel version information
	local kernel_version_for_image="unknown"
	if [[ -n "$KERNEL_VERSION" ]]; then
		kernel_version_for_image="$KERNEL_VERSION"
	elif [[ -n "$IMAGE_INSTALLED_KERNEL_VERSION" ]]; then
		kernel_version_for_image="${IMAGE_INSTALLED_KERNEL_VERSION/-$LINUXFAMILY/}"
	fi

	# Construct vendor and version prefix
	local vendor_version_prelude="${VENDOR}_${IMAGE_VERSION:-"${REVISION}"}_"
	if [[ "${include_vendor_version:-"yes"}" == "no" ]]; then
		vendor_version_prelude=""
	fi

	# Construct base name
	base_image_name="${vendor_version_prelude}${BOARD^}_${RELEASE}_${BRANCH}_${kernel_version_for_image}"

	# Add desktop environment suffix
	if [[ -n "$DESKTOP_ENVIRONMENT" ]]; then
		base_image_name="${base_image_name}_${DESKTOP_ENVIRONMENT}"
	fi

	# Add extra image suffix
	if [[ -n "$EXTRA_IMAGE_SUFFIX" ]]; then
		base_image_name="${base_image_name}${EXTRA_IMAGE_SUFFIX}"
	fi

	# Add build type suffix
	if [[ "$BUILD_DESKTOP" == "yes" ]]; then
		base_image_name="${base_image_name}_desktop"
	fi
	if [[ "$BUILD_MINIMAL" == "yes" ]]; then
		base_image_name="${base_image_name}_minimal"
	fi
	if [[ "$ROOTFS_TYPE" == "nfs" ]]; then
		base_image_name="${base_image_name}_nfsboot"
	fi

    # Create OTA package name
    local ota_package_name="${base_image_name}-OTA.tar.gz"
    local ota_output_path="${DEST}/images/${ota_package_name}"

    # Ensure output directory exists
    mkdir -p "${DEST}/images/"

    # Copy arbian_ota_tools directory
    local tools_source_dir="${SRC}/extensions/armbian-ota/armbian_ota_tools"
    if [[ -d "$tools_source_dir" ]]; then
        cp -r "$tools_source_dir" "$ota_temp_dir/" || {
            display_alert "Error: Failed to copy arbian_ota_tools" "$tools_source_dir" "err"
            rm -rf "$ota_temp_dir"
            return 1
        }
        display_alert "Copied OTA tools" "armbian_ota_tools -> ${ota_package_name}" "info"
    else
        display_alert "Warning: arbian_ota_tools directory not found" "$tools_source_dir" "warn"
    fi

    # Create OTA package manifest file
    local manifest_file="$ota_temp_dir/ota_manifest.txt"
    cat > "$manifest_file" << EOF
# Armbian OTA Package Manifest
# Generated on: $(date)
# Original image: ${base_image_name}

Package Contents:
EOF

    # Add file list to manifest
    if [[ "$secure_boot_and_decrypt" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        echo "- boot.itb: FIT boot image for secure boot" >> "$manifest_file"
    elif [[ -f "$boot_tar" ]]; then
        echo "- boot.tar.gz: Boot partition image" >> "$manifest_file"
    fi
    if [[ -f "$rootfs_tar" ]]; then
        echo "- rootfs.tar.gz: Root filesystem image" >> "$manifest_file"
    fi
    if [[ -d "$tools_source_dir" ]]; then
        echo "- arbian_ota_tools/: OTA update tools and utilities" >> "$manifest_file"
    fi

    # Create final OTA tar.gz package
    display_alert "Creating final OTA package" "${ota_package_name}" "info"
    if (cd "$ota_temp_dir" && tar -czf "$ota_output_path" .); then
        local ota_size=$(stat -c%s "$ota_output_path")
        display_alert "OTA package created successfully" "${ota_package_name} ($((ota_size / 1024 / 1024)) MB)" "info"

        # Display OTA package contents
        display_alert "OTA package contents" "" "info"
        tar -tzf "$ota_output_path" | head -20 | while read -r file; do
            display_alert "  - $file" "" "info"
        done

        # Create checksums
        local ota_md5=$(md5sum "$ota_output_path" | awk '{print $1}')
        local ota_sha256=$(sha256sum "$ota_output_path" | awk '{print $1}')

        # Write checksums file
        local checksum_file="${DEST}/images/${base_image_name}-OTA.checksums"
        cat > "$checksum_file" << EOF
# Armbian OTA Package Checksums
# Package: ${ota_package_name}
# Generated: $(date)

MD5:    ${ota_md5}
SHA256: ${ota_sha256}
EOF
        display_alert "Checksums generated" "${checksum_file}" "info"

    else
        display_alert "Error: Failed to create OTA package" "${ota_package_name}" "err"
        rm -rf "$ota_temp_dir"
        return 1
    fi

    # Clean up temporary directory
    rm -rf "$ota_temp_dir"

    display_alert "OTA package creation completed" "Package: ${ota_package_name}" "info"
}


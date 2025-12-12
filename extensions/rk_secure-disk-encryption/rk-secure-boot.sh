function fetch_sources_tools__rksdk_tools() {
	fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/ackPeng/rockchip_sdk_tools.git"}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}"
}

function pre_config_uboot_target__generate_fit_keys() {
    # 目标：在 U-Boot 配置前生成 FIT 签名所需密钥及可选系统加密密钥。

    local uboot_workdir rkbin_root rk_sign_tool keys_dir
    uboot_workdir="$(pwd)"  # 当前即 u-boot 源码目录
    keys_dir="${uboot_workdir}/keys"

    # 若用户显式设置 UBOOT_DIR 变量则优先使用
    if [[ -n "${UBOOT_DIR}" ]]; then
        uboot_workdir="${UBOOT_DIR}"
        keys_dir="${UBOOT_DIR}/keys"
    fi

    rkbin_root="${SRC}/cache/sources/rockchip_sdk_tools/rkbin"
    echo "rkbin_root = ${rkbin_root}"

    # 查找 rk_sign_tool 可执行文件（优先 PATH）
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_root}" && -x "${rkbin_root}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_root}/tools/rk_sign_tool"
    fi

    if [[ -z "${rk_sign_tool}" ]]; then
        display_alert "secure-uboot" "rk_sign_tool 未找到，跳过 FIT 密钥生成" "warn"
        return 0
    fi

    mkdir -p "${keys_dir}" || { display_alert "secure-uboot" "无法创建目录 ${keys_dir}" "err"; return 1; }

    # 幂等：若已有 dev.key 和 dev.crt 则认为已生成过，避免覆盖
    if [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.crt" ]]; then
        display_alert "secure-uboot" "检测到已存在密钥，跳过生成 (${keys_dir})" "info"
        export UBOOT_FIT_KEYS_DIR="${keys_dir}"
        return 0
    fi

    display_alert "secure-uboot" "使用 rk_sign_tool 生成初始密钥对" "info"
    (
        cd "${keys_dir}" || exit 1
        # 生成 rsa 2048 位密钥对 (工具输出 private_key.pem / public_key.pem)
        "${rk_sign_tool}" kk --bits 2048 --out ./ || exit_with_error "rk_sign_tool 生成密钥失败" "${rk_sign_tool}"
        ln -rsf private_key.pem dev.key
        ln -rsf public_key.pem dev.pubkey

        # 生成自签名证书（subject 可按需修改）
        openssl req -batch -new -x509 -key dev.key -out dev.crt -subj "/CN=Armbian FIT Key/" || exit_with_error "生成自签名证书失败" "dev.crt"

        # 生成系统加密用随机密钥（32 字节 hex 表示）
        openssl rand -hex 32 > system_enc_key || exit_with_error "生成 system_enc_key 失败" "system_enc_key"
    )

    # 导出路径供后续阶段或打包使用
    export UBOOT_FIT_KEYS_DIR="${keys_dir}"
    display_alert "secure-uboot" "FIT 密钥生成完成: ${UBOOT_FIT_KEYS_DIR}" "info"
}


# 辅助函数：设置 vendor 构建环境
function setup_vendor_build_environment() {
    # 生成密钥 (幂等)
    if [[ "${DISABLE_FIT_KEY_GEN}" != "yes" ]]; then
        pre_config_uboot_target__generate_fit_keys || display_alert "secure-uboot" "FIT 密钥生成失败" "warn"
    fi
}

# 辅助函数：修改 boot 分区名称和标签
function modify_boot_partition_name() {
    # 设置 boot 分区的文件系统标签为 "boot"
    export BOOT_FS_LABEL="boot"
    display_alert "secure-uboot" "设置 boot 分区标签为: ${BOOT_FS_LABEL}" "info"
}

# 辅助函数：创建 SPI loader 镜像
function create_spi_loader_image() {
    display_alert "secure-uboot" "创建 SPI loader 镜像" "info"

    dd if=/dev/zero of=rkspi_loader.img bs=1M count=0 seek=16 2>/dev/null

    # 创建分区表
    /sbin/parted -s rkspi_loader.img mklabel gpt
    /sbin/parted -s rkspi_loader.img unit s mkpart idbloader 64 7167
    /sbin/parted -s rkspi_loader.img unit s mkpart vnvm 7168 7679
    /sbin/parted -s rkspi_loader.img unit s mkpart reserved_space 7680 8063
    /sbin/parted -s rkspi_loader.img unit s mkpart reserved1 8064 8127
    /sbin/parted -s rkspi_loader.img unit s mkpart uboot_env 8128 8191
    /sbin/parted -s rkspi_loader.img unit s mkpart reserved2 8192 16383
    /sbin/parted -s rkspi_loader.img unit s mkpart uboot 16384 32734

    # 写入数据
    if [[ -f idbloader.img ]]; then
        dd if=idbloader.img of=rkspi_loader.img seek=64 conv=notrunc 2>/dev/null
    fi
    if [[ -f u-boot.itb ]]; then
        dd if=u-boot.itb of=rkspi_loader.img seek=16384 conv=notrunc 2>/dev/null
    fi
}

# 辅助函数：收集 vendor 产物
function collect_vendor_artifacts() {
    local vendor_board="${1}"
    local dst_dir="${uboottempdir}/usr/lib/${uboot_name}"

    mkdir -p "${dst_dir}" || exit_with_error "创建打包目录失败" "${dst_dir}"

    # 可能的产物列表
    local artifacts=(
        "rkspi_loader.img"
        "idbloader.img"
        "u-boot.bin"
        "u-boot-nodtb.bin"
        "u-boot.dtb"
        "u-boot.itb"
        "u-boot.its"
        "spl/u-boot-spl.bin"
        "tpl/u-boot-tpl.bin"
    )

    local copied=0
    for artifact in "${artifacts[@]}"; do
        if [[ -f "${artifact}" ]]; then
            cp -v "${artifact}" "${dst_dir}/" 2>&1 | grep -v '->' || true
            copied=$((copied+1))
        fi
    done

    if [[ ${copied} -gt 0 ]]; then
        display_alert "secure-uboot" "已复制 ${copied} 个产物到 ${dst_dir}" "info"
    fi

    # 保存最终配置
    if [[ -f .config ]]; then
        cp .config "${dst_dir}/vendor-final.config"
    fi

    # 生成元数据
    generate_uboot_metadata "${dst_dir}" "${vendor_board}"
}

# 辅助函数：生成 U-Boot 元数据
function generate_uboot_metadata() {
    local dst_dir="${1}"
    local vendor_board="${2}"

    cat > "${dst_dir}/u-boot-metadata-target-1.sh" <<VENDOR_META
declare -a UBOOT_TARGET_BINS=($(ls "${dst_dir}" 2>/dev/null | sed 's/^/"/;s/$/"/' | tr '\n' ' '))
declare UBOOT_TARGET_MAKE='${vendor_board}'
declare UBOOT_TARGET_CONFIG='vendor-final.config'
VENDOR_META
}

# 辅助函数：应用 secure-boot-config 目录下的配置和补丁
function apply_secure_boot_config() {
    local secure_config_dir="${SRC}/extensions/rk_secure-disk-encryption/secure-boot-config"

    if [[ ! -d "${secure_config_dir}" ]]; then
        display_alert "secure-uboot" "secure-boot-config 目录不存在: ${secure_config_dir}" "debug"
        return 0
    fi

    display_alert "secure-uboot" "应用 secure-boot-config 配置和补丁" "info"

    # 1. 处理 defconfig 文件
    if [[ -d "${secure_config_dir}/defconfig" ]]; then
        display_alert "secure-uboot" "应用 defconfig 配置" "info"
        mkdir -p configs
        local defconfig_count=0
        for config_file in "${secure_config_dir}/defconfig"/*; do
            [[ -f "${config_file}" ]] || continue
            cp -vf "${config_file}" configs/ && defconfig_count=$((defconfig_count + 1))
        done
        display_alert "secure-uboot" "已应用 ${defconfig_count} 个 defconfig 文件" "debug"
    fi

    # 2. 处理设备树文件
    if [[ -d "${secure_config_dir}/dt" ]]; then
        display_alert "secure-uboot" "应用设备树文件" "info"
        mkdir -p arch/arm/dts
        local dt_count=0
        for dt_file in "${secure_config_dir}/dt"/*; do
            [[ -e "${dt_file}" ]] || continue
            cp -rf "${dt_file}" arch/arm/dts/ && dt_count=$((dt_count + 1))
        done
        display_alert "secure-uboot" "已应用 ${dt_count} 个设备树文件" "debug"
    fi

    # 3. 处理 board 目录
    if [[ -d "${secure_config_dir}/board" ]]; then
        display_alert "secure-uboot" "应用板级配置文件" "info"
        local board_count=0
        # 递归复制整个 board 目录结构
        cp -rf "${secure_config_dir}/board"/* . 2>/dev/null && board_count=$((board_count + 1))
        display_alert "secure-uboot" "已应用板级配置文件" "debug"
    fi

    # 4. 应用补丁文件（如果有）
    if compgen -G "${secure_config_dir}"/*.patch > /dev/null; then
        display_alert "secure-uboot" "应用安全启动补丁" "info"
        local patch_applied=0
        local patch_failed=0
        for patch_file in "${secure_config_dir}"/*.patch; do
            [[ -f "${patch_file}" ]] || continue
            local patch_name=$(basename "${patch_file}")

            # 检查补丁是否可以应用
            if git apply --check "${patch_file}" 2>/dev/null; then
                if git apply "${patch_file}"; then
                    patch_applied=$((patch_applied + 1))
                    display_alert "secure-uboot" "补丁已应用: ${patch_name}" "debug"
                else
                    patch_failed=$((patch_failed + 1))
                    display_alert "secure-uboot" "补丁应用失败: ${patch_name}" "err"
                fi
            else
                # 尝试使用 patch 命令
                if patch -p1 < "${patch_file}" 2>/dev/null; then
                    patch_applied=$((patch_applied + 1))
                    display_alert "secure-uboot" "补丁已应用(patch): ${patch_name}" "debug"
                else
                    patch_failed=$((patch_failed + 1))
                    display_alert "secure-uboot" "补丁应用失败(patch): ${patch_name}" "err"
                fi
            fi
        done

        display_alert "secure-uboot" "补丁应用完成: 成功=${patch_applied} 失败=${patch_failed}" "info"
    fi

    # 5. 处理其他配置文件
    local config_files=(
        "include/configs"
        "scripts"
        "include"
    )

    for config_subdir in "${config_files[@]}"; do
        if [[ -d "${secure_config_dir}/${config_subdir}" ]]; then
            display_alert "secure-uboot" "应用配置目录: ${config_subdir}" "info"
            mkdir -p "${config_subdir}"
            cp -rf "${secure_config_dir}/${config_subdir}"/* "${config_subdir}/" 2>/dev/null || true
        fi
    done

    display_alert "secure-uboot" "secure-boot-config 应用完成" "info"
}


function build_custom_uboot__vendor_fit_secure() {
    # 使用 Rockchip vendor make.sh 来构建安全 FIT 版本 U-Boot。

    # 条件限制：Rockchip 系列 (rockchip64 / rk35xx / 下游命名) 或强制。
    if [[ ! "${LINUXFAMILY}" =~ ^(rockchip|rockchip64|rk35|rk35xx) ]]; then
        display_alert "secure-uboot" "LINUXFAMILY=${LINUXFAMILY} 不匹配 Rockchip，跳过 vendor FIT U-Boot 构建" "debug"
        return 0
    fi

    # 检查是否有 make.sh（vendor 构建标志）
    if [[ ! -f ./make.sh ]]; then
        display_alert "secure-uboot" "未找到 vendor make.sh，回退到标准构建流程" "warn"
        return 0
    fi

    # 防止重复执行
    if [[ "${EXTENSION_BUILT_UBOOT}" == "yes" ]]; then
        display_alert "secure-uboot" "已由其它步骤标记 EXTENSION_BUILT_UBOOT，跳过" "debug"
        return 0
    fi

    display_alert "secure-uboot" "开始 vendor FIT U-Boot 构建" "info"

    # 使用标准补丁流程，而不是手动复制
    display_alert "secure-uboot" "应用标准补丁流程" "info"

    # 确保 uboot_git_revision 已设置（patch_uboot_target 需要）
    declare -g uboot_git_revision
    if [[ -z "${uboot_git_revision}" ]]; then
        uboot_git_revision="$(git rev-parse HEAD)"
    fi

    # 应用标准补丁流程（这会自动处理 BOOTPATCHDIR 中的所有补丁）
    # 包括：board_recomputer-rk3588/、target_*、common 等目录
    patch_uboot_target

    # 应用 secure-boot-config 目录下的额外配置和补丁
    apply_secure_boot_config

    # 设置 vendor 构建环境
    setup_vendor_build_environment

    # 复制rkbin到u-boot目录的上一级目录
    local rkbin_source="${SRC}/cache/sources/rockchip_sdk_tools/rkbin"
    local rkbin_dest="../rkbin"
    if [[ -d "${rkbin_source}" ]]; then
        display_alert "secure-uboot" "复制rkbin到 ${rkbin_dest}" "info"
        rm -rf "${rkbin_dest}" 2>/dev/null || true
        cp -rf "${rkbin_source}" "${rkbin_dest}" || {
            display_alert "secure-uboot" "复制rkbin失败" "err"
            return 1
        }
    else
        display_alert "secure-uboot" "rkbin源目录不存在: ${rkbin_source}" "warn"
    fi

    # 复制prebuilts到u-boot目录的上一级目录
    local prebuilts_source="${SRC}/cache/sources/rockchip_sdk_tools/external/prebuilts"
    local prebuilts_dest="../prebuilts"
    if [[ -d "${prebuilts_source}" ]]; then
        display_alert "secure-uboot" "复制prebuilts到 ${prebuilts_dest}" "info"
        rm -rf "${prebuilts_dest}" 2>/dev/null || true
        cp -rf "${prebuilts_source}" "${prebuilts_dest}" || {
            display_alert "secure-uboot" "复制prebuilts失败" "err"
            return 1
        }
    else
        display_alert "secure-uboot" "prebuilts源目录不存在: ${prebuilts_source}" "warn"
    fi

    # 使用 vendor make.sh 构建
    display_alert "secure-uboot" "开始 vendor u-boot 编译" "info"
    local vendor_board="${UBOOT_VENDOR_BOARD:-recomputer-rk3588-devkit}"
    bash ./make.sh "${vendor_board}" --spl-new || exit_with_error "vendor u-boot 编译失败" "make.sh"

    # 需要 idblock 支持：生成 idblock.bin
    display_alert "secure-uboot" "生成 idblock.bin" "info"
    bash ./make.sh --idblock || display_alert "secure-uboot" "idblock 生成失败 (继续)" "warn"

    # 复制关键文件
    cp idblock.bin idbloader.img || true
    if [[ -f fit/uboot.itb ]]; then
        cp fit/uboot.itb u-boot.itb
    fi
    if [[ -f fit/u-boot.its ]]; then
        cp fit/u-boot.its u-boot.its
    fi

    # 创建 SPI loader 镜像
    create_spi_loader_image

    # 收集产物到 Armbian 打包目录
    collect_vendor_artifacts "${vendor_board}"

    # 标记为已构建
    EXTENSION_BUILT_UBOOT=yes
    uboot_target_counter=1
    display_alert "secure-uboot" "vendor FIT secure U-Boot 构建完成" "info"
    return 0
}


function pre_package_kernel_image__create_resource_img() {

    display_alert "Creating resource.img" "Using rk3588-recomputer-devkit.dtb" "info"

    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local dtb_path="${kernel_src}/arch/arm64/boot/dts/rockchip/rk3588-recomputer-devkit.dtb"
    # local dtb_path="${uboot_src}/arch/arm/dts/rk3588-recomputer-devkit.dtb"
    local resource_tool="${uboot_src}/tools/resource_tool"
    local output_resource_img="${kernel_src}/resource.img"

    # 检查必要文件和工具
    [[ -f "${dtb_path}" ]] || {
        display_alert "Missing DTB file" "${dtb_path}" "err"
        return 0
    }

    [[ -n "${resource_tool}" && -x "${resource_tool}" ]] || {
        display_alert "Missing resource_tool" "Searched in u-boot and rkbin-tools directories" "err"
        return 0
    }

    display_alert "Using resource_tool" "${resource_tool}" "debug"
    
    # 创建临时工作目录
    local temp_work_dir=$(mktemp -d)
    mkdir -p "${temp_work_dir}"
    
    # 复制DTB文件到工作目录
    local dtb_filename=$(basename "${dtb_path}")
    cp "${dtb_path}" "${temp_work_dir}/${dtb_filename}"

    # 确保输出目录存在且可写
    local output_dir=$(dirname "${output_resource_img}")
    mkdir -p "${output_dir}"

    # 使用resource_tool创建resource.img
    (
        cd "${temp_work_dir}"

        display_alert "Debug: Packing resource.img" "DTB: ${dtb_filename}, Output: ${output_resource_img}" "debug"
        display_alert "Debug: Working directory" "$(pwd)" "debug"
        display_alert "Debug: Files in temp dir" "$(ls -la)" "debug"

        # 先在当前目录创建，然后移动到目标位置
        "${resource_tool}" --pack "${dtb_filename}" "./resource.img" || {
            display_alert "Failed to create resource.img in temp dir" "resource_tool pack failed" "err"
            rm -rf "${temp_work_dir}"
            return 1
        }

        # 移动到最终位置
        if [[ -f "./resource.img" ]]; then
            mv "./resource.img" "${output_resource_img}" || {
                display_alert "Failed to move resource.img to ${output_resource_img}" "mv failed" "err"
                rm -rf "${temp_work_dir}"
                return 1
            }
        else
            display_alert "resource.img not created in temp directory" "file missing" "err"
            rm -rf "${temp_work_dir}"
            return 1
        fi
    )
    
    # 清理临时目录
    rm -rf "${temp_work_dir}"
    
    # 验证生成的resource.img
    if [[ -f "${output_resource_img}" && -s "${output_resource_img}" ]]; then
        local img_size=$(stat -c %s "${output_resource_img}")
        display_alert "Successfully created resource.img" "Size: ${img_size} bytes" "info"
        
        # 可选：显示resource.img内容
        "${resource_tool}" --print --image="${output_resource_img}" 2>/dev/null || true
    else
        display_alert "Failed to create resource.img" "File not found or empty" "err"
        return 1
    fi
}

function pre_umount_final_image__package_fit() {
    display_alert "fit-post-initrd" "开始在最终卸载前重建 FIT" "info"
    local boot_dir="${MOUNT}/boot"  # 使用挂载点真实 /boot
    [[ -d "${boot_dir}" ]] || { display_alert "fit-post-initrd" "/boot 不存在，跳过" "err"; return 0; }

    local ramdisk_path=""
    if compgen -G "${boot_dir}/initrd.img-"* > /dev/null; then
        ramdisk_path="$(ls -1t ${boot_dir}/initrd.img-* | head -1)"
        display_alert "fit-post-initrd" "使用官方 initrd: ${ramdisk_path}" "info"
    elif [[ -f "${boot_dir}/uInitrd" ]]; then
        ramdisk_path="${boot_dir}/uInitrd"
        display_alert "fit-post-initrd" "使用 uInitrd: ${ramdisk_path}" "info"
    elif [[ -f "${SRC}/userpatches/overlay/rootfs.cpio.gz" ]]; then
        ramdisk_path="${SRC}/userpatches/overlay/rootfs.cpio.gz"
        display_alert "fit-post-initrd" "官方 initrd 未找到，回退 rootfs.cpio.gz" "warn"
    else
        display_alert "fit-post-initrd" "未找到任何 initramfs，无法生成 FIT" "err"
        return 0
    fi

    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local kernel_img_path="${kernel_src}/arch/arm64/boot/Image"
    local dtb_path="${kernel_src}/arch/arm64/boot/dts/rockchip/rk3588-recomputer-devkit.dtb"
    local resource_path="${kernel_src}/resource.img"
    local rk_mkimage="${SRC}/cache/sources/rockchip_sdk_tools/rkbin/tools/mkimage"
    [[ -x "${rk_mkimage}" ]] || { display_alert "fit-post-initrd" "缺少 mkimage: ${rk_mkimage}" "err"; return 0; }

    [[ -f "${kernel_img_path}" ]] || { display_alert "fit-post-initrd" "缺少内核镜像: ${kernel_img_path}" "err"; return 0; }
    [[ -f "${dtb_path}" ]] || { display_alert "fit-post-initrd" "缺少设备树: ${dtb_path}" "err"; return 0; }

    # 使用主机临时目录
    local fit_work="${TMPDIR:-/tmp}/fit-final-$$"
    rm -rf "${fit_work}" 2>/dev/null || true
    mkdir -p "${fit_work}" || { display_alert "fit-post-initrd" "创建临时工作目录失败: ${fit_work}" "err"; return 0; }

    # 复制必要文件到工作目录
    cp -f "${kernel_img_path}" "${fit_work}/Image"
    cp -f "${dtb_path}" "${fit_work}/board.dtb"
    if [[ -f "${resource_path}" ]]; then cp -f "${resource_path}" "${fit_work}/resource.img"; else : > "${fit_work}/resource.img"; fi
    cp -f "${ramdisk_path}" "${fit_work}/initrd.img"

    # 使用外部ITS模板文件
    local its_template="${SRC}/extensions/rk_secure-disk-encryption/secure-boot-config/fit_kernel.its"
    if [[ ! -f "${its_template}" ]]; then
        display_alert "fit-post-initrd" "ITS模板文件不存在: ${its_template}" "err"
        return 1
    fi

    # 复制ITS模板到工作目录
    cp -f "${its_template}" "${fit_work}/boot-final.its"

    # 替换占位符为实际文件路径
    sed -i "s|@KERNEL_DTB@|${dtb_path}|g" "${fit_work}/boot-final.its"
    sed -i "s|@KERNEL_IMG@|${kernel_img_path}|g" "${fit_work}/boot-final.its"
    sed -i "s|@RAMDISK_IMG@|${ramdisk_path}|g" "${fit_work}/boot-final.its"
    sed -i "s|@RESOURCE_IMG@|${resource_path}|g" "${fit_work}/boot-final.its"

    display_alert "fit-post-initrd" "生成最终 FIT (初始 boot-final.img)" "info"
    (
        cd "${fit_work}" || exit 1

        "${rk_mkimage}" -f boot-final.its  -E -p 0x800 boot-final.img || exit 1

    ) || { display_alert "fit-post-initrd" "mkimage 生成失败" "err"; rm -rf "${fit_work}"; return 0; }

    # 二次签名：参考 post_install_kernel_debs__package_initramfs_itb，若存在 scripts/fit.sh
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local uboot_dir="${uboot_src}"
    if [[ -z "${uboot_dir}" || ! -d "${uboot_dir}" ]]; then
        uboot_dir="$(find "${SRC}/cache/sources/u-boot-worktree" -maxdepth 4 -type d -name "u-boot-*${LINUXFAMILY}*" | head -1)"
    fi

    # 加载U-Boot构建时的环境变量
    local env_file="${SRC}/cache/sources/.uboot_build_env"
    if [[ -f "${env_file}" ]]; then
        display_alert "fit-post-initrd" "加载U-Boot构建环境变量" "info"
        source "${env_file}"
    else
        display_alert "fit-post-initrd" "未找到U-Boot构建环境文件，使用默认环境" "warn"
    fi

    display_alert "fit-post-initrd" "执行二次签名脚本 fit.sh" "info"
    (
        cd "${uboot_dir}" || exit 1
        cp "${fit_work}/boot-final.img" .
        ./scripts/fit.sh --boot_img "${fit_work}/boot-final.img" || display_alert "fit-post-initrd" "fit.sh 执行失败" "err"

    )

    if [[ ! -f "${uboot_dir}/fit/boot.itb" ]]; then
        display_alert "fit-post-initrd" "fit目录没有镜像" "info"
        return 1
    fi

    # 清理临时工作目录
    rm -rf "${fit_work}" 2>/dev/null || true

    display_alert "fit-flash" "删除fstab 的boot设置" "info"

    local fstab_file="${MOUNT}/etc/fstab"

    if [[ ! -f "${fstab_file}" ]]; then
        display_alert "fit-flash" "没有fstab文件" "info"
        return 0
    fi

    # 如果已经没有 boot 条目，则跳过
    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        display_alert "fit-flash" "没有 boot 条目" "info"
        return 0
    fi

    display_alert "secure-uboot" "pre_umount_image: 删除 fstab 中的 boot 分区挂载条目" "info"

    # 打印 sed 执行前的 fstab 内容
    display_alert "secure-uboot" "sed 执行前的 fstab 内容:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    # 创建备份
    cp "${fstab_file}" "${fstab_file}.bak" 2>/dev/null || true

    # 删除包含 /boot 的行
    sed -i '\|/boot|d' "${fstab_file}" 2>/dev/null || true

    # 打印 sed 执行后的 fstab 内容
    display_alert "secure-uboot" "sed 执行后的 fstab 内容:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    # 验证并清理
    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        rm -f "${fstab_file}.bak" 2>/dev/null || true
        display_alert "secure-uboot" "成功从 fstab 中删除 boot 分区挂载条目" "info"
    else
        display_alert "secure-uboot" "警告：fstab 中仍有 /boot 条目，请手动检查" "warn"
    fi
}

function post_umount_final_image__flash_fit_kernel() {
    # 在最终卸载后，将 FIT 镜像写入 boot 分区（仅在 RAW boot 模式下）
  
    display_alert "fit-flash" "RAW boot 模式：将 FIT 镜像写入 boot 分区" "info"

    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local fit_image="${uboot_src}/fit/boot.itb"
    local boot_dev="${LOOP}p1"

    display_alert "fit-flash" "目标 boot 设备: ${boot_dev}" "info"

    if [[ ! -f "${fit_image}" ]]; then
        display_alert "fit-flash" "FIT 镜像不存在: ${fit_image}" "err"
        return 1
    fi

    display_alert "fit-flash" "dd if="${fit_image}" of="${boot_dev}"" "info"
    dd if="${fit_image}" of="${boot_dev}" || {
        display_alert "fit-flash" "写入 FIT 镜像失败" "err"
        return 1
    }

    sync
    display_alert "fit-flash" "FIT 镜像写入完成" "info"

}

# 修改分区设置，使用 RAW boot 分区
function pre_prepare_partitions__set_raw_boot_partition() {
    display_alert "secure-uboot" "启用 RAW boot 分区模式" "info"

    BOOTPART_REQUIRED="yes"

    # 确保 boot 分区有足够的空间 (设置为 256 MiB)
    export BOOTSIZE=256
    display_alert "secure-uboot" "强制设置 boot 分区大小: ${BOOTSIZE} MiB" "info"

    # 禁用标准的 boot 文件系统处理
    export BOOT_RAW_MODE="yes"
}

# 修改分区名称和标签
function pre_prepare_partitions__change_boot_partition_name() {
    modify_boot_partition_name
    mkopts_label[ext4]=" -U 0b06166d-3930-4176-b30a-900806bd6202 -L  "

}


# 跳过标准的 boot 分区挂载和复制
function post_create_partitions__handle_raw_boot() {

    display_alert "secure-uboot" "RAW boot 模式：保存bootpart索引并阻止文件系统创建" "debug"

    # 确保 BOOTSIZE 已经设置
    if [[ -z "${BOOTSIZE}" ]]; then
        export BOOTSIZE=256
        display_alert "secure-uboot" "设置默认 BOOTSIZE=${BOOTSIZE} MiB" "info"
    fi

    # 保存原始bootpart索引，用于后续dd写入
    export RAW_BOOT_PART_INDEX="${bootpart}"
    display_alert "secure-uboot" "保存 boot 分区索引: ${RAW_BOOT_PART_INDEX}" "debug"

    # 延迟清除 bootpart 变量，在 mount_chroot_script 阶段再清除
    # 这样确保分区创建时能正确使用 BOOTSIZE

}

# 在挂载 rootfs 前清除 bootpart 变量
function pre_mount_chroot_script__delayed_raw_boot_cleanup() {
    # 延迟清除 bootpart，阻止后续的文件系统创建和挂载
    if [[ "${BOOT_RAW_MODE}" == "yes" ]]; then
        display_alert "secure-uboot" "延迟清理：清除 bootpart 变量" "debug"
        bootpart=""
    fi
}


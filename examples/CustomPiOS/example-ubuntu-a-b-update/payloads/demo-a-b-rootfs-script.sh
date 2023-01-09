#!/bin/bash

# Uncomment following 2 lines to enable stepping.
# set -vx
# trap read debug

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

# Ensure that getopt starts from first option if ". <script.sh>" was used.
OPTIND=1

ret_val=0

# Ensure we dont end the user's terminal session if invoked from source (".").
if [[ $0 != "${BASH_SOURCE[0]}" ]]; then
    ret='return'
else
    ret='exit'
fi

# Output formatting.

# Log level: 0=debug, 1=info, 2=warning, 3=error, 4=none
log_level=1

warn() { echo -e "\033[1;33mWarning:\033[0m $*" >&2; }

error() { echo -e "\033[1;31mError:\033[0m $*" >&2; }

header() { echo -e "\e[4m\e[1m\e[1;32m$*\e[0m"; }

bullet() { echo -e "\e[1;34m*\e[0m $*"; }

warn "***********************************************************"
warn "* THIS SCRIPT IS DEMONSTRATING AN A/B ROOT FS UPDATE ONLY *"
warn "* IT IS NOT SUITABLE FOR PRODUCTION DEVICE                *"
warn "***********************************************************"

# Log debug prefix - blue
log_debug_pref="\033[1;30m[D]\033[0m"

# Log info prefix - blue
log_info_pref="\033[1;34m[I]\033[0m"

# Log warning prefix - yellow
log_warn_pref="\033[1;33m[W]\033[0m"

# Log error prefix - red
log_error_pref="\033[1;31m[E]\033[0m"

#
# Files and Folders information
#
work_folder=
output_file=/adu/logs/swpupdate.output
log_file=/adu/logs/swupdate.log
result_file=/adu/logs/swupdate.result.json

boot_loader_folder=/boot

#
# For install task, the --image-file <image_file_name> option must be specified.
#
image_file=""

#
# Following files are based on the how the Yocto Refererence Image was built.
# This value can be replaced in this script, or specify in import manifest (handlerProperties) as needed.
#
software_version_file="/etc/adu-version"
public_key_file="/adukey/public.pem"

#
# Device Update specific arguments
#
check_is_installed=
installed_criteria=
do_download_action=
do_install_action=
do_apply_action=
do_cancel_action=

restart_device_to_apply=
restart_agent_to_apply=

#
# Debug options
#

# skip actual file copy operation during install action. Useful when already copied the file in previous debug session.
debug_install_no_file_copy=

#
# Remaining aguments and parameters
#
PARAMS=

#
# Output, Logs, and Result helper functions.
#
_timestamp=

# SWUpdate doesn't support everything necessary for the dual-copy or A/B update strategy.
# Here we figure out the current OS partition and then set some data or variables
# that we use to tell the installer which partition to target, and boot-loader which
# partition is actived root fs.
rootfs_dev=$(mount | grep "on / type" | cut -d':' -f 2 | cut -d' ' -f 1)
if [[ $rootfs_dev == '/dev/mmcblk0p2' ]]; then
    selection="stable,copy2"
    current_partition=2
    update_partition=3
    adu_active_root_fs=a
    adu_desired_root_fs=b
else
    selection="stable,copy1"
    current_partition=3
    update_partition=2
    adu_active_root_fs=b
    adu_desired_root_fs=a
fi

update_timestamp() {
    # See https://man7.org/linux/man-pages/man1/date.1.html
    _timestamp="$(date +'%Y/%m/%d:%H%M%S')"
}

log_debug() {
    if [ $log_level -gt 0 ]; then
        return
    fi
    log "$log_debug_pref" "$@"
}

log_info() {
    if [ $log_level -gt 1 ]; then
        return
    fi
    log "$log_info_pref" "$@"
}

log_warn() {
    if [ $log_level -gt 2 ]; then
        return
    fi
    log "$log_warn_pref" "$@"
}

log_error() {
    if [ $log_level -gt 3 ]; then
        return
    fi
    log "$log_error_pref" "$@"
}

log() {
    update_timestamp
    if [ -z $log_file ]; then
        echo -e "[$_timestamp]" "$@" >&1
    else
        echo "[$_timestamp]" "$@" >> $log_file
    fi
}

output() { update_timestamp;  if [ -z $output_file ]; then
        echo "[$_timestamp]" "$@" >&1
    else
        echo "[$_timestamp]" "$@" >> "$output_file"
    fi
}

result() {
    # NOTE: don't insert timestamp in result file.
    if [ -z $result_file ]; then
        echo "$@" >&1
    else
        echo "$@" > "$result_file"
    fi
}

#
# Helper function for creating extended result code that indicates
# errors from this script.
# Note: these error range (0x30501000 - 0x30501fff) a free to use.
#
# Usage: make_script_handler_erc error_value result_variable
#
# e.g.
#         error_code=20
#         RESULT=0
#         make_script_handler_erc RESULT $error_code
#         echo $RESULT
#
#  (RESULT is 0x30501014)
#
make_script_handler_erc() {
    local base_erc=0x30501000
    local -n res=$2 # name reference
    res=$((base_erc + $1))
}

# usage: make_aduc_result_json $resultCode $extendedResultCode $resultDetails <out param>
# shellcheck disable=SC2034
make_aduc_result_json() {
    local -n res=$4 # name reference
    res="{\"resultCode\":$1, \"extendedResultCode\":$2,\"resultDetails\":\"$3\"}"
}

#
# Usage
#
print_help() {
    echo ""
    echo "Usage: <script-file-name>.sh [options...]"
    echo ""
    echo ""
    echo "Device Update reserved argument"
    echo "==============================="
    echo ""
    echo "--action-is-installed                     Perform 'is-installed' check."
    echo "                                          Check whether the 'installed criteria' is met."
    echo "--installed-criteria                      A string contains the intalled-criteria."
    echo ""
    echo "--action-download                         Perform 'download' aciton."
    echo "--action-install                          Perform 'install' action."
    echo "--action-apply                            Perform 'apply' action."
    echo "--action-cancel                           Perform 'cancel' action."
    echo ""
    echo "--restart-device-to-apply                 Request the host device to restart to apply the update."
    echo "--restart-agent-to-apply                  Request the DU Agent to restart to applying the update."
    echo ""
    echo "File and Folder information"
    echo "==========================="
    echo ""
    echo "--work-folder             A work-folder (or sandbox folder)."
    echo "--swu-file, --image-file  A swu file to install."
    echo "--output-file             An output file."
    echo "--log-file                A log file."
    echo "--result-file             A file contain ADUC_Result data (in JSON format)."
    echo "--software-version-file   A file contain image version number."
    echo "--public-key-file         A public key file for signature validateion."
    echo "                          See InstallUpdate() function for more details."
    echo "Advanced Options"
    echo "================"
    echo ""
    echo "--boot-loader-folder      A root folder that stored the boot-loader files (usuall /boot)"
    echo ""
    echo ""
    echo "Debug Options"
    echo "=============="
    echo ""
    echo "--debug-install-no-file-copy  No actuall file copy during installation action"
    echo ""
    echo "--log-level <0-4>         A minimum log level. 0=debug, 1=info, 2=warning, 3=error, 4=none."
    echo "-h, --help                Show this help message."
    echo ""
    echo "Example:"
    echo ""
    echo "Scenario: is-installed check"
    echo "========================================"
    echo "    <script> --log-level 0 --action-is-installed --intalled-criteria 1.0"
    echo ""
    echo "Scenario: perform install action"
    echo "================================"
    echo "    <script> --log-level 0 --action-install --intalled-criteria 1.0 --swu-file example-device-update.swu --work-folder <sandbox-folder>"
    echo ""
}



log_text=""

mem_log() {
    echo $1
    log_text="$log_text$1\n"
}

#
# Parsing arguments
#
while [[ $1 != "" ]]; do
    case $1 in

    #
    # Device Update specific arguments.
    #
    --action-download)
        shift
        do_download_action=yes
        ;;

    --action-install)
        shift
        mem_log "Will runscript as 'installer' script."
        do_install_action=yes
        ;;

    --action-apply)
        shift
        do_apply_action=yes
        ;;

    --restart-device-to-apply)
        shift
        restart_device_to_apply=yes
        ;;

    --restart-agent-to-apply)
        shift
        restart_agent_to_apply=yes
        ;;

    --action-cancel)
        shift
        do_cancel_action=yes
        ;;

    --action-is-installed)
        shift
        check_is_installed=yes
        ;;

    --installed-criteria)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --installed-criteria requires an installedCriteria parameter."
            $ret 1
        fi
        installed_criteria="$1"
        shift
        ;;

    #
    # Update artifacts
    #
    --work-folder)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --work-folder parameter is mandatory."
            $ret 1
        fi
        work_folder="$1"
        mem_log "work folder: $work_folder"
        shift
        ;;

    --boot-loader-folder)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --boot-loader-folder parameter is mandatory."
            $ret 1
        fi
        boot_loader_folder="$1"
        mem_log "boot_loader_folder: $boot_loader_folder"
        shift
        ;;

    #
    # Output-related arguments.
    #
    # --output-file <file_path>, --result-file <file_path>, --log-file <file_path>
    #
    --output-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --output-file parameter is mandatory."
            $ret 1
        fi
        output_file="$1"

        #
        #Create output file path.
        #
        # Delete existing log.
        rm -f -r "$output_file"
        # Create dir(s) recursively (include filename, well remove it in the following line...).
        mkdir -p "$output_file"
        # Delete leaf-dir (w)
        rm -f -r "$output_file"

        shift
        ;;

    --result-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log  "ERROR: --result-file parameter is mandatory."
            $ret 1
        fi
        result_file="$1"
        echo "Result file : $result_file"
        #
        #Create result file path.
        #
        # Delete existing log.
        rm -f -r "$result_file"
        # Create dir(s) recursively (include filename, well remove it in the following line...).
        mkdir -p "$result_file"
        # Delete leaf-dir (w)
        rm -f -r "$result_file"
        shift
        ;;

    --software-version-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --software-version-file parameter is mandatory."
            $ret 1
        fi
        software_version_file="$1"
        shift
        ;;

    --swu-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --swu-file parameter is mandatory."
            $ret 1
        fi
        image_file="$1"
        mem_log "swu file (image file): $image_file"
        shift
        ;;

    --image-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --image-file parameter is mandatory."
            $ret 1
        fi
        image_file="$1"
        echo "swu file (image file): $image_file"
        shift
        ;;

    --public-key-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --public-key-file parameter is mandatory."
            $ret 1
        fi
        public_key_file="$1"
        shift
        ;;

    --log-file)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --log-file parameter is mandatory."
            $ret 1
        fi
        log_file="$1"
        shift
        ;;

    --log-level)
        shift
        if [[ -z $1 || $1 == -* ]]; then
            mem_log "ERROR: --log-level parameter is mandatory."
            $ret 1
        fi
        log_level=$1
        shift
        ;;

    --debug-install-no-file-copy)
        shift
        debug_install_no_file_copy=yes
        ;;

    -h | --help)
        print_help
        $ret 0
        ;;

    *) # preserve positional arguments
        PARAMS="$PARAMS $1"
        shift
        ;;
    esac
done

log_info $log_text

#
# Device Update related functions.
#

#
# A helper function that evaluates whether an update is currently installed on the target,
# based on 'p_installed_criteria' (param #1).
#
# Usage: is_installed <in installed_criteria> <in software_version_file> <out resultCode> <out extendedResultCode> <out resultDetails>
#
# shellcheck disable=SC2034
function is_installed {
    local -n rc=$3  # name reference for resultCode
    local -n erc=$4 # name reference for extendedResultCode
    local -n rd=$5  # name reference for resultDetails

    p_installed_criteria=$1
    p_software_version_file=$2

    if ! [[ -f $p_software_version_file ]]; then
        # Return 'not installed'
        rc=901
        make_script_handler_erc 100 erc
        rd="Image version file name ($p_software_version_file) doesnt exist."
    elif [[ $p_installed_criteria == "" ]]; then
        # Return 'not installed'
        rc=901
        make_script_handler_erc 101 erc
        rd="Installed criteria is empty."
    else
        {
            grep "^$p_installed_criteria$" "$p_software_version_file"
        }

        grep_res=$?

        if [[ $grep_res -eq "0" ]]; then
            # Return 'installed' code, if p_software_version_file contains p_installed_criteria string.
            rc=900
            erc=0
            rd=""
        else
            # Return 'not installed'
            rc=901
            erc=0
            rd="Installed criteria has not met ('$p_installed_criteria')."
        fi
    fi
}

#
# Example implementation of 'IsInstalled' function, for this update scenario.
#
#   Determine whether the specified 'installed-criteria' (parameter $1) is met.
#
#   For this update, the 'installed-criteria' is a version number of the image or software being installed.
#   This value number is geterated by the image or update build pipe line and saved in in $software_version_file.
#
# Expected resultCode:
#     ADUC_Result_Failure = 0,
#     ADUC_Result_IsInstalled_Installed = 900,     /**< Succeeded and content is installed. */
#     ADUC_Result_IsInstalled_NotInstalled = 901,  /**< Succeeded and content is not installed */
#
CheckIsInstalledState() {
    log_info "IsInstalledTask(\"$1\"), adu-version path:\"$software_version_file\""

    local local_rc=2
    local local_erc=3
    local local_rd="4"
    local aduc_result=""

    # Evaluates installedCriteria string.
    is_installed "$1" "$software_version_file" local_rc local_erc local_rd

    make_aduc_result_json "$local_rc" "$local_erc" "$local_rd" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"
}

#
# Example implementation of 'DownloadUpdate' function, for this update scenario.
#
# This fuction is no-op since no additional files are required for this update.
#
DownloadUpdate() {
    log_info "DownloadUpdate called"

    # Return ADUC_Result_Download_Success (500), no extended result code, no result details.
    make_aduc_result_json 500 0 "" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret $ret_val
}

#
# Performs the update installation.
#
# Before install any files, is_installed function is called to check whether the update is already installed on the target.
# If already installed, do nothing and report ADUC_Result_Install_Skipped_UpdateAlreadyInstalled (603) result code.
#
# Otherwise, try to install the update. If success, report ADUC_Result_Install_Success (600)
# Or, report ADUC_Result_Failure (0), if failed.
#
# Expected resultCode:
#    ADUC_Result_Failure = 0,
#    ADUC_Result_Install_Success = 600,                        /**< Succeeded. */
#    ADUC_Result_Install_Skipped_UpdateAlreadyInstalled = 603, /**< Succeeded (skipped). Indicates that 'install' action is no-op. */
#    ADUC_Result_Install_RequiredImmediateReboot = 605,        /**< Succeeded. An immediate device reboot is required, to complete the task. */
#    ADUC_Result_Install_RequiredReboot = 606,                 /**< Succeeded. A deferred device reboot is required, to complete the task. */
#    ADUC_Result_Install_RequiredImmediateAgentRestart = 607,  /**< Succeeded. An immediate agent restart is required, to complete the task. */
#    ADUC_Result_Install_RequiredAgentRestart = 608,           /**< Succeeded. A deferred agent restart is required, to complete the task. */
#
InstallUpdate() {
    log_info "InstallUpdate called"

    resultCode=0
    extendedResultCode=0
    resultDetails=""
    ret_val=0

    #
    # Note: we could simulate 'component off-line' scenario here.
    #

    # Check whether the component is already installed the specified update...
    echo is_installed "$installed_criteria" "$software_version_file" resultCode extendedResultCode resultDetails

    is_installed "$installed_criteria" "$software_version_file" resultCode extendedResultCode resultDetails

    is_installed_ret=$?

    if [[ $is_installed_ret -ne 0 ]]; then
        # is_installed function failed to execute.
        resultCode=0
        make_script_handler_erc "$is_installed_ret" extendedResultCode
        resultDetails="Internal error in 'is_installed' function."
    elif [[ $resultCode == 0 ]]; then
        # Failed to determine whether the update has been installed or not.
        # Return current ADUC_Result
        log_error "Failed to determine wehther the update has been installed or note."
    elif [[ $resultCode -eq 901 ]]; then
        # Not installed.

        # install an update.
        log_info "Installing update..."

        # [ BEGIN - Mock Installation ]
        # For this demo, we'll copy data from the active Root FS partition to the
        # secondary (non-active) partition, then write the '$installed_critiera' string
        # to the $software_version_file (to simulate a new version of the image being stalled)

        new_root_fs_dev=""
        adu_desired_root_fs=""

        if [[ $update_partition == 3 ]]; then
            # Write to partition B (/dev/mmcblk0p3)
            new_root_fs_dev="/dev/mmcblk0p3"
            adu_desired_root_fs='b'
        else
            # Write to partition A (/dev/mmcblk0p2)
            new_root_fs_dev="/dev/mmcblk0p2"
            adu_desired_root_fs='a'
        fi

        # Unmount the target parition if needed.
        tmp_out=$(mount | grep "$new_root_fs_dev")
        if [[ "$tmp_out" != "" ]]; then
            log_info "Unmounting '$new_root_fs_dev'..."
            umount $new_root_fs_dev
            log_info "umount result: $?"
        fi

        if [[ "$debug_install_no_file_copy" != "yes" ]]; then
            # Copy content from active partition to an update partition.
            # NOTE: in real-world scenario, data verification is needed.
            log_info "#### BEGIN DD####"
            dd if=$rootfs_dev of=$new_root_fs_dev bs=1M
            ret_val=$?

            if [[ $ret_val -eq 0 ]]; then
                resultDetails="Failed to copy partition data (err:$ret_val)"
                log_error "$resultDetails"
                # TODO: set erc.
                resultCode=0
            else
                log_info "Successfully copied file from $rootfs_dev to $new_root_fs_dev"
            fi
            log_info "#### END DD ####"
        fi

        log_info "Writing a version number to the update partition.."
        mount_dir=/mnt/adu_update_part_b
        mkdir -p $mount_dir
        mount  $new_root_fs_dev $mount_dir
        ret_val=$?

        if [[ $ret_val -eq 0 ]]; then
            resultDetails="Failed to mount $new_root_fs_dev (to: $mount_dir, error: $ret_val)"
            log_error "$resultDetails"
            # TODO: set erc.
            resultCode=0
        fi

        version_file="$mount_dir/$software_version_file"

        if [[ $ret_val -eq 0 ]]; then
            log_info "writing '$install_criteria' to '$version_file'"
            echo "$installed_criteria" | sudo tee $version_file

            # verify the image version file content.
            resultCode=0
            is_installed "$installed_criteria" "$software_version_file" resultCode extendedResultCode resultDetails
            if [[ ! $resultCode -eq 900 ]]; then
                resultCode=0
                resultDetails="Cannot write new version to the update partition ( $version_file )"
                # TODO: set erc.
                ref_val=1
            fi
        fi

        tmp_out=$(mount | grep "$new_root_fs_dev")
        if [[ "$tmp_out" != "" ]]; then
            log_info "Unmounting '$new_root_fs_dev'..."
            umount $new_root_fs_dev
            inner_ret_val=$?
            if [[ $inner_ret_val -eq 0 ]]; then
                log_warn "cannot unmount $new_root_fs_dev"
            else
                rm -fr $mount_dir
                inner_ret_val=$?
                if [[ $inner_ret_val -eq 0 ]]; then
                    log_warn "cannot remove $mount_dir"
                fi
            fi
        fi

        if [[ $ret_val -eq 0 ]]; then
            log_info "Successfully update the device. Will reboot during apply phase."
            resultDetails=""
            extendedResultCode=0
            resultCode=600
        fi

        # [ END - Mock Installation]
    else
        # Installed.
        log_info "It appears that this update has already been installed."
        resultCode=603
        extendedResultCode=0
        resultDetails="Already installed."
        ret_val=0
    fi

    # Prepare ADUC_Result json.
    make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret $ret_val
}

#
# Performs steps to finalize the update.
#
ApplyUpdate() {
    log_info "Applying update..."

    ret_val=0
    resultCode=0
    extendedResultCode=0
    resultDetails=""

    echo "Applying update." >> "${log_file}"

    # Tell boot-loader to use new partition after reboot.

    # Only delete the desired_root_fs
    rootfs_indicator_file="$boot_loader_folder/adu_desired_root_fs_$adu_desired_root_fs"
    if [[ $adu_desired_root_fs == 'b' ]]; then
        touch "$rootfs_indicator_file"
        ret_val=$?
        if [[ $ret_val -eq 0 ]]; then
            resultDetails="Cannot create or update $rootfs_indicator_file (error:$ret_val)"
            log_error "$resultDetails"
            # TODO: set erc.
            resultCode=0
        fi
    elif [ -f "$rootfs_indicator_file" ]; then
        # Remove the file, to tell the boot-loader to use the default partition.
        rm "$rootfs_indicator_file"
        ret_val=$?
        if [[ $ret_val -eq 0 ]]; then
            resultDetails="Cannot delete $rootfs_indicator_file (error:$ret_val)"
            log_error "$resultDetails"
            # TODO: set erc.
            resultCode=0
        fi
    fi

    if [[ $ret_val -eq 0 ]]; then
        if [ "$restart_device_to_apply" == "yes" ]; then
            # ADUC_Result_Apply_RequiredImmediateReboot = 705
            resultCode=705
        elif [ "$restart_agent_to_apply" == "yes" ]; then
            # ADUC_Result_Apply_RequiredImmediateAgentRestart = 707
            resultCode=707
        else
            # ADUC_Result_Apply_Success = 700
            resultCode=700
        fi
        extendedResultCode=0
        resultDetails=""
    else
        resultCode=0
        make_script_handler_erc "$ret_val" extendedResultCode
        resultDetails="Cannot set rpipart value to $update_partition"
        log_error "$resultDetails"
    fi

    # Prepare ADUC_Result json.
    aduc_result=""
    make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret $ret_val
}

#
# Cancel current update.
#
# Set the bootloader environment variable to tell the bootloader to boot into the current partition
# instead of the one that was updated. Note: rpipart variable is specific to our boot.scr script.
#
CancelUpdate() {
    log_info "CancelUpdate called"

    # Set the bootloader environment variable
    # to tell the bootloader to boot into the current partition.
    # rpipart variable is specific to our boot.scr script.
    echo "Cancelling update." >> "${log_file}"
    resultCode=0
    extendedResultCode=0
    resultDetails=""
    ret_val=

    echo "Revert update." >> "${log_file}"

    # Tell boot-loader to use active parition.

    # Only delete the desired_root_fs
    rootfs_indicator_file="$boot_loader_folder/adu_desired_root_fs_$adu_active_root_fs"
    if [[ $adu_active_root_fs == 'b' ]]; then
        touch "$rootfs_indicator_file"
        ret_val=$?
        if [[ $ret_val -eq 0 ]]; then
            resultDetails="Cannot create or update $rootfs_indicator_file (error:$ret_val)"
            log_error "$resultDetails"
            # TODO: set erc.
            resultCode=0
        fi
    elif [ -f "$rootfs_indicator_file" ]; then
        # Remove the file, to tell the boot-loader to use the default partition.
        rm "$rootfs_indicator_file"
        ret_val=$?
        if [[ $ret_val -eq 0 ]]; then
            resultDetails="Cannot delete $rootfs_indicator_file (error:$ret_val)"
            log_error "$resultDetails"
            # TODO: set erc.
            resultCode=0
        fi
    fi

    if [[ $ret_val -eq 0 ]]; then
        resultCode=800
    else
        resultCode=801
        make_script_handler_erc "$ret_val" extendedResultCode
        resultDetails="Failed to set rpipart to ${update_partition}"
        ret_val=0
    fi

    make_aduc_result_json "$resultCode" "$extendedResultCode" "$resultDetails" aduc_result

    # Show output.
    output "Result:" "$aduc_result"

    # Write ADUC_Result to result file.
    result "$aduc_result"

    $ret $ret_val
}

#
# Main
#
if [ -n "$check_is_installed" ]; then
    CheckIsInstalledState "$installed_criteria"
    exit $ret_val
fi

if [ -n "$do_download_action" ]; then
    DownloadUpdate
    exit $ret_val
fi

if [ -n "$do_install_action" ]; then
    InstallUpdate
    exit $ret_val
fi

if [ -n "$do_apply_action" ]; then
    ApplyUpdate
    exit $ret_val
fi

if [ -n "$do_cancel_action" ]; then
    CancelUpdate
    exit $ret_val
fi

$ret $ret_val
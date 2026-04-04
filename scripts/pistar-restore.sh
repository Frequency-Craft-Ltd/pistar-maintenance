#!/bin/bash

###############################################################################
# Pi-Star Restore Script (MSP-Grade)
# - Menu-based backup selection from S3 / B2 / OneDrive
# - Full / Wi-Fi-only / MMDVMHost-only restore modes
# - Rollback checkpoint (snapshot current configs)
# - SHA256 integrity verification
# - Decompression
# - Post-restore validation (MMDVMHost syntax)
# - Dry-run mode
# - Structured logging + exit codes
###############################################################################

RESTORE_DIR="/home/pi/pistar-restore"
ROLLBACK_DIR="/home/pi/pistar-rollback"
LOGFILE="/var/log/pistar-restore.log"
MACHINE_ID=$(hostname)

ENABLE_S3=0
ENABLE_B2=0
ENABLE_ONEDRIVE=1

S3_BUCKET="YOUR_BUCKET_NAME"
B2_BUCKET="YOUR_B2_BUCKET"
ONEDRIVE_BASE="onedrive:/PiStar-Backups"

DRYRUN=0
MODE="full"   # full | wifi | mmdvm

for arg in "$@"; do
    case "$arg" in
        --dry-run|--test)
            DRYRUN=1
            ;;
        --wifi-only)
            MODE="wifi"
            ;;
        --mmdvm-only)
            MODE="mmdvm"
            ;;
    esac
done

# Exit codes
# 0  = success
# 5  = no backup selected
# 10 = download failure
# 20 = checksum mismatch
# 30 = decompression failure
# 40 = restore failure
# 50 = validation failure
# 60 = rollback failure

WIFI_FILES=(
    "/etc/wpa_supplicant/wpa_supplicant.conf"
    "/etc/dhcpcd.conf"
    "/etc/hostapd/hostapd.conf"
)

MMDVM_FILES=(
    "/etc/mmdvmhost"
    "/etc/pistar-mmdvmhost"
    "/etc/pistar-mmdvmhost.backup"
    "/etc/pistar-mmdvmhost.factory"
    "/etc/pistar-mmdvmhost.pistar"
)

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$ts] [$MACHINE_ID] [$level] $msg" | tee -a "$LOGFILE"
}

fatal() {
    local code="$1"
    shift
    log "ERROR" "$* (exit code $code)"
    exit "$code"
}

list_backups_onedrive() {
    if ! command -v rclone >/dev/null 2>&1; then
        log "ERROR" "rclone not installed"
        return 1
    fi

    local remote_path="${ONEDRIVE_BASE}/${MACHINE_ID}"
    rclone lsf "$remote_path" 2>>"$LOGFILE"
}

list_backups_s3() {
    if ! command -v aws >/dev/null 2>&1; then
        log "ERROR" "AWS CLI not installed"
        return 1
    fi

    aws s3 ls "s3://${S3_BUCKET}/pi-star/${MACHINE_ID}/" 2>>"$LOGFILE" \
        | awk '{print $4}'
}

list_backups_b2() {
    if ! command -v b2 >/dev/null 2>&1; then
        log "ERROR" "Backblaze B2 CLI not installed"
        return 1
    fi

    b2 ls "$B2_BUCKET" "pi-star/${MACHINE_ID}/" 2>>"$LOGFILE" \
        | awk '{print $4}'
}

select_backup_menu() {
    log "INFO" "Fetching backup list from cloud for $MACHINE_ID"

    local backups=()
    local i=0

    if [ "$ENABLE_ONEDRIVE" -eq 1 ]; then
        mapfile -t backups < <(list_backups_onedrive | grep ".tar.gz$" | sort)
    elif [ "$ENABLE_S3" -eq 1 ]; then
        mapfile -t backups < <(list_backups_s3 | grep ".tar.gz$" | sort)
    elif [ "$ENABLE_B2" -eq 1 ]; then
        mapfile -t backups < <(list_backups_b2 | grep ".tar.gz$" | sort)
    else
        fatal 10 "No cloud provider enabled"
    fi

    if [ "${#backups[@]}" -eq 0 ]; then
        fatal 5 "No backups found in cloud for $MACHINE_ID"
    fi

    echo "Available backups for $MACHINE_ID:"
    for i in "${!backups[@]}"; do
        printf "  [%d] %s\n" "$i" "${backups[$i]}"
    done

    echo
    read -r -p "Select backup index to restore: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 0 ] || [ "$choice" -ge "${#backups[@]}" ]; then
        fatal 5 "Invalid selection"
    fi

    SELECTED_BACKUP="${backups[$choice]}"
    log "INFO" "Selected backup: $SELECTED_BACKUP"
}

download_from_s3() {
    local backup_name="$1"
    local s3_path="s3://${S3_BUCKET}/pi-star/${MACHINE_ID}/${backup_name}"

    if ! command -v aws >/dev/null 2>&1; then
        log "ERROR" "AWS CLI not installed"
        return 1
    fi

    log "INFO" "Downloading from S3: $s3_path"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would download $backup_name from S3"
        return 0
    fi

    aws s3 cp "$s3_path" "$RESTORE_DIR/" >>"$LOGFILE" 2>&1 || return 1
    return 0
}

download_from_b2() {
    local backup_name="$1"
    local b2_path="pi-star/${MACHINE_ID}/${backup_name}"

    if ! command -v b2 >/dev/null 2>&1; then
        log "ERROR" "Backblaze B2 CLI not installed"
        return 1
    fi

    log "INFO" "Downloading from B2: $b2_path"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would download $backup_name from B2"
        return 0
    fi

    b2 download-file-by-name "$B2_BUCKET" "$b2_path" "$RESTORE_DIR/$backup_name" >>"$LOGFILE" 2>&1 || return 1
    return 0
}

download_from_onedrive() {
    local backup_name="$1"
    local remote_path="${ONEDRIVE_BASE}/${MACHINE_ID}/${backup_name}"

    if ! command -v rclone >/dev/null 2>&1; then
        log "ERROR" "rclone not installed"
        return 1
    fi

    log "INFO" "Downloading from OneDrive: $remote_path"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would download $backup_name from OneDrive"
        return 0
    fi

    rclone copy "$remote_path" "$RESTORE_DIR/" >>"$LOGFILE" 2>&1 || return 1
    return 0
}

download_backup_and_checksum() {
    local backup_name="$1"
    local checksum_name="${backup_name}.sha256"

    if [ "$ENABLE_S3" -eq 1 ]; then
        download_from_s3 "$backup_name" || fatal 10 "Failed to download backup from S3"
        download_from_s3 "$checksum_name" || fatal 10 "Failed to download checksum from S3"
    elif [ "$ENABLE_B2" -eq 1 ]; then
        download_from_b2 "$backup_name" || fatal 10 "Failed to download backup from B2"
        download_from_b2 "$checksum_name" || fatal 10 "Failed to download checksum from B2"
    elif [ "$ENABLE_ONEDRIVE" -eq 1 ]; then
        download_from_onedrive "$backup_name" || fatal 10 "Failed to download backup from OneDrive"
        download_from_onedrive "$checksum_name" || fatal 10 "Failed to download checksum from OneDrive"
    else
        fatal 10 "No cloud provider enabled"
    fi
}

verify_checksum() {
    local file="$1"
    local checksum_file="$2"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would verify checksum for $file"
        return 0
    fi

    log "INFO" "Verifying checksum"

    sha256sum -c "$checksum_file" >>"$LOGFILE" 2>&1 || fatal 20 "Checksum verification failed"

    log "INFO" "Checksum OK"
}

decompress_backup() {
    local archive="$1"

    log "INFO" "Decompressing $archive"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would decompress $archive"
        return 0
    fi

    tar -xzf "$archive" -C "$RESTORE_DIR" >>"$LOGFILE" 2>&1 \
        || fatal 30 "Failed to decompress backup"

    log "INFO" "Decompression complete"
}

create_rollback_checkpoint() {
    log "INFO" "Creating rollback checkpoint in $ROLLBACK_DIR"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would snapshot current configs to $ROLLBACK_DIR"
        return 0
    fi

    mkdir -p "$ROLLBACK_DIR" || fatal 60 "Failed to create rollback directory"

    local paths=(
        "${WIFI_FILES[@]}"
        "${MMDVM_FILES[@]}"
    )

    for p in "${paths[@]}"; do
        if [ -e "$p" ]; then
            local dest="$ROLLBACK_DIR$(dirname "$p")"
            mkdir -p "$dest"
            cp -r "$p" "$dest/" 2>>"$LOGFILE" || fatal 60 "Failed to snapshot $p"
            log "INFO" "Snapshot: $p → $dest/"
        fi
    done

    log "INFO" "Rollback checkpoint created"
}

rollback_restore() {
    log "WARN" "Attempting rollback from $ROLLBACK_DIR"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would rollback configs from $ROLLBACK_DIR"
        return 0
    fi

    if [ ! -d "$ROLLBACK_DIR" ]; then
        fatal 60 "No rollback directory found"
    fi

    cp -r "$ROLLBACK_DIR"/etc/* /etc/ 2>>"$LOGFILE" || fatal 60 "Rollback failed"
    log "INFO" "Rollback completed"
}

restore_full() {
    local extracted_dir="$1"

    log "INFO" "Full restore from $extracted_dir"

    for src in "$extracted_dir"/etc/*; do
        local base
        base=$(basename "$src")
        local target="/etc/$base"

        if [ "$DRYRUN" -eq 1 ]; then
            log "INFO" "[DRY RUN] Would restore $src → $target"
        else
            cp -r "$src" "$target" 2>>"$LOGFILE" || fatal 40 "Failed to restore $src"
            log "INFO" "Restored $src → $target"
        fi
    done
}

restore_wifi_only() {
    local extracted_dir="$1"

    log "INFO" "Wi-Fi-only restore from $extracted_dir"

    for wf in "${WIFI_FILES[@]}"; do
        local rel="${wf#/etc/}"
        local src="$extracted_dir/etc/$rel"
        local target="$wf"

        if [ ! -e "$src" ]; then
            log "WARN" "Wi-Fi file not in backup: $src"
            continue
        fi

        if [ "$DRYRUN" -eq 1 ]; then
            log "INFO" "[DRY RUN] Would restore $src → $target"
        else
            cp -r "$src" "$target" 2>>"$LOGFILE" || fatal 40 "Failed to restore $src"
            log "INFO" "Restored $src → $target"
        fi
    done
}

restore_mmdvm_only() {
    local extracted_dir="$1"

    log "INFO" "MMDVMHost-only restore from $extracted_dir"

    for mf in "${MMDVM_FILES[@]}"; do
        local rel="${mf#/etc/}"
        local src="$extracted_dir/etc/$rel"
        local target="$mf"

        if [ ! -e "$src" ]; then
            log "WARN" "MMDVM file not in backup: $src"
            continue
        fi

        if [ "$DRYRUN" -eq 1 ]; then
            log "INFO" "[DRY RUN] Would restore $src → $target"
        else
            cp -r "$src" "$target" 2>>"$LOGFILE" || fatal 40 "Failed to restore $src"
            log "INFO" "Restored $src → $target"
        fi
    done
}

restore_files() {
    local extracted_dir="$1"

    case "$MODE" in
        full)
            restore_full "$extracted_dir"
            ;;
        wifi)
            restore_wifi_only "$extracted_dir"
            ;;
        mmdvm)
            restore_mmdvm_only "$extracted_dir"
            ;;
        *)
            fatal 40 "Unknown restore mode: $MODE"
            ;;
    esac

    log "INFO" "Restore mode '$MODE' completed"
}

validate_mmdvm() {
    if [ "$MODE" = "wifi" ]; then
        log "INFO" "Skipping MMDVM validation (Wi-Fi-only restore)"
        return 0
    fi

    local cfg="/etc/mmdvmhost"

    if [ ! -f "$cfg" ]; then
        log "WARN" "MMDVMHost config not found at $cfg; skipping validation"
        return 0
    fi

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would validate MMDVMHost config at $cfg"
        return 0
    fi

    log "INFO" "Validating MMDVMHost config (basic syntax check)"

    if ! grep -q "

\[General\]

" "$cfg"; then
        log "ERROR" "MMDVMHost config missing [General] section"
        log "WARN" "You may want to rollback using rollback_restore"
        return 1
    fi

    log "INFO" "MMDVMHost basic validation passed"
    return 0
}

log "INFO" "Starting Pi-Star restore (DRYRUN=$DRYRUN, MODE=$MODE)"

mkdir -p "$RESTORE_DIR"

select_backup_menu

BACKUP_NAME="$SELECTED_BACKUP"
CHECKSUM_NAME="${BACKUP_NAME}.sha256"

download_backup_and_checksum "$BACKUP_NAME"

verify_checksum "$RESTORE_DIR/$BACKUP_NAME" "$RESTORE_DIR/$CHECKSUM_NAME"

decompress_backup "$RESTORE_DIR/$BACKUP_NAME"

EXTRACTED_DIR="$RESTORE_DIR/$(basename "$BACKUP_NAME" .tar.gz)"

create_rollback_checkpoint

restore_files "$EXTRACTED_DIR"

if ! validate_mmdvm; then
    log "ERROR" "Post-restore validation failed"
    log "WARN" "You can run rollback_restore manually if needed"
    exit 50
fi

log "INFO" "Restore completed successfully"
exit 0
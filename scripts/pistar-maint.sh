#!/bin/bash

###############################################################################
# Pi-Star Maintenance Script (MSP-Grade)
# - Config snapshotting
# - Compression (tar.gz)
# - Integrity hashing (SHA256)
# - Optional cloud uploads (S3 / B2 / OneDrive via rclone)
# - Local + cloud retention
# - Email notifications
# - Self-update from GitHub
# - Dry-run mode
# - Structured logging and exit codes
###############################################################################

SCRIPT_VERSION="1.0.0"

#---------------------------#
# CONFIGURATION
#---------------------------#

BACKUP_DIR="/home/pi/pistar-backups"
LOGFILE="/var/log/pistar-update.log"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
MACHINE_ID=$(hostname)

UPLOAD_SOURCE="$BACKUP_DIR/$MACHINE_ID/$DATE"
HASH_FILE="$UPLOAD_SOURCE.checksums.sha256"

# Cloud toggles
ENABLE_S3=0
ENABLE_B2=0
ENABLE_ONEDRIVE=1

CLOUD_FATAL=0

S3_BUCKET="YOUR_BUCKET_NAME"
B2_BUCKET="YOUR_B2_BUCKET"
S3_PATH="s3://${S3_BUCKET}/pi-star/${MACHINE_ID}/${DATE}/"
B2_PATH="b2://${B2_BUCKET}/pi-star/${MACHINE_ID}/${DATE}/"
ONEDRIVE_BASE="onedrive:/PiStar-Backups"
ONEDRIVE_PATH="${ONEDRIVE_BASE}/${MACHINE_ID}/${DATE}"

LOCAL_RETENTION_COUNT=10
ONEDRIVE_RETENTION_DAYS=30

ENABLE_EMAIL=0
EMAIL_TO="you@example.com"
EMAIL_FROM="pistar@example.com"
EMAIL_SUBJECT_PREFIX="[Pi-Star Maintenance]"

ENABLE_SELF_UPDATE=1
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_URL="https://raw.githubusercontent.com/Anubis161Killer/pistar-maintenance/main/scripts/pistar-maint.sh"

DRYRUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|--test)
            DRYRUN=1
            ;;
    esac
done

# Exit codes
# 0  = success
# 10 = backup failure
# 15 = compression failure
# 20 = hashing failure
# 30 = Pi-Star update/upgrade failure
# 40 = cloud upload failure (if CLOUD_FATAL=1)
# 50 = self-update failure
# 60 = email notification failure (non-fatal)

CONFIG_PATHS=(
    "/etc/pistar-release"
    "/etc/hostapd"
    "/etc/dhcpcd.conf"
    "/etc/wpa_supplicant/wpa_supplicant.conf"
    "/etc/mmdvmhost"
    "/etc/dstar-radio"
    "/etc/pistar-css"
    "/etc/pistar-firewall"
    "/etc/pistar-remote"
    "/etc/pistar-upnp"
    "/etc/pistar-watchdog"
    "/etc/pistar-theme"
    "/etc/pistar-mmdvmcal"
    "/etc/pistar-mmdvmhost"
    "/etc/pistar-mmdvmhost.backup"
    "/etc/pistar-mmdvmhost.factory"
    "/etc/pistar-mmdvmhost.pistar"
)

#---------------------------#
# LOGGING / STATUS HELPERS
#---------------------------#

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
    send_email "FAILURE (code $code)" || true
    exit "$code"
}

STEP_BACKUP="PENDING"
STEP_COMPRESS="PENDING"
STEP_HASH="PENDING"
STEP_UPDATE="PENDING"
STEP_UPLOAD="PENDING"
STEP_RETENTION_LOCAL="PENDING"
STEP_RETENTION_CLOUD="PENDING"
STEP_SELF_UPDATE="PENDING"
STEP_EMAIL="PENDING"

#---------------------------#
# SELF-UPDATE
#---------------------------#

self_update() {
    if [ "$ENABLE_SELF_UPDATE" -ne 1 ]; then
        log "INFO" "Self-update disabled by config"
        STEP_SELF_UPDATE="SKIPPED"
        return 0
    fi

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would self-update from $SCRIPT_URL"
        STEP_SELF_UPDATE="DRYRUN"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log "WARN" "curl not installed — skipping self-update"
        STEP_SELF_UPDATE="SKIPPED"
        return 0
    fi

    log "INFO" "Checking for script updates from $SCRIPT_URL"
    TMP_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_URL" -o "$TMP_FILE"; then
        log "WARN" "Failed to download updated script — keeping current version"
        STEP_SELF_UPDATE="FAILED"
        return 0
    fi

    if cmp -s "$SCRIPT_PATH" "$TMP_FILE"; then
        log "INFO" "Script already up to date"
        rm -f "$TMP_FILE"
        STEP_SELF_UPDATE="OK"
        return 0
    fi

    log "INFO" "Updating script at $SCRIPT_PATH"
    if ! cp "$TMP_FILE" "$SCRIPT_PATH"; then
        rm -f "$TMP_FILE"
        fatal 50 "Failed to replace script during self-update"
    fi

    chmod +x "$SCRIPT_PATH"
    rm -f "$TMP_FILE"
    log "INFO" "Self-update complete"
    STEP_SELF_UPDATE="OK"
}

#---------------------------#
# BACKUP CONFIGS
#---------------------------#

backup_configs() {
    log "INFO" "Starting config backup to $UPLOAD_SOURCE"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would create backup directory $UPLOAD_SOURCE"
    else
        mkdir -p "$UPLOAD_SOURCE" || fatal 10 "Failed to create backup directory $UPLOAD_SOURCE"
    fi

    for path in "${CONFIG_PATHS[@]}"; do
        if [ -e "$path" ]; then
            if [ "$DRYRUN" -eq 1 ]; then
                log "INFO" "[DRY RUN] Would back up: $path"
            else
                cp -r "$path" "$UPLOAD_SOURCE/" 2>>"$LOGFILE" \
                    && log "INFO" "Backed up: $path" \
                    || fatal 10 "Failed to back up $path"
            fi
        else
            log "WARN" "Skipped missing: $path"
        fi
    done

    STEP_BACKUP="OK"
}

#---------------------------#
# COMPRESSION
#---------------------------#

compress_backup() {
    log "INFO" "Compressing backup directory"

    TARFILE="${UPLOAD_SOURCE}.tar.gz"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would compress $UPLOAD_SOURCE to $TARFILE"
    else
        tar -czf "$TARFILE" -C "$BACKUP_DIR/$MACHINE_ID" "$DATE" >>"$LOGFILE" 2>&1 \
            || fatal 15 "Compression failed"
        log "INFO" "Backup compressed to $TARFILE"
        UPLOAD_SOURCE="$TARFILE"
        HASH_FILE="${UPLOAD_SOURCE}.sha256"
    fi

    STEP_COMPRESS="OK"
}

#---------------------------#
# HASHING / INTEGRITY
#---------------------------#

generate_hashes() {
    log "INFO" "Generating SHA256 checksums for backup set"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would generate checksum for $UPLOAD_SOURCE"
        STEP_HASH="DRYRUN"
        return 0
    fi

    sha256sum "$UPLOAD_SOURCE" > "$HASH_FILE" 2>>"$LOGFILE" \
        || fatal 20 "Failed to generate checksums"

    log "INFO" "Checksums written to $HASH_FILE"
    STEP_HASH="OK"
}

verify_hashes() {
    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would verify checksum for $UPLOAD_SOURCE"
        return 0
    fi

    log "INFO" "Verifying checksum"
    sha256sum -c "$HASH_FILE" >>"$LOGFILE" 2>&1 \
        || fatal 20 "Checksum verification failed"

    log "INFO" "Checksum verification OK"
}

#---------------------------#
# PI-STAR UPDATE / UPGRADE
#---------------------------#

run_pistar_update() {
    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would run pistar-update and pistar-upgrade"
        STEP_UPDATE="DRYRUN"
        return 0
    fi

    log "INFO" "Running Pi-Star update"
    sudo pistar-update >>"$LOGFILE" 2>&1 || fatal 30 "pistar-update failed"

    log "INFO" "Running Pi-Star upgrade"
    sudo pistar-upgrade >>"$LOGFILE" 2>&1 || fatal 30 "pistar-upgrade failed"

    STEP_UPDATE="OK"
}

#---------------------------#
# CLOUD UPLOADS
#---------------------------#

upload_s3() {
    if [ "$ENABLE_S3" -ne 1 ]; then
        log "INFO" "S3 upload disabled by config"
        return 0
    fi

    if ! command -v aws >/dev/null 2>&1; then
        log "WARN" "AWS CLI not installed — skipping S3 upload"
        return 0
    fi

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would upload $UPLOAD_SOURCE and $HASH_FILE to $S3_PATH"
        return 0
    fi

    log "INFO" "Uploading backup to Amazon S3: $S3_PATH"
    aws s3 cp "$UPLOAD_SOURCE" "$S3_PATH" >>"$LOGFILE" 2>&1 || return 1
    aws s3 cp "$HASH_FILE" "$S3_PATH" >>"$LOGFILE" 2>&1 || return 1
    log "INFO" "S3 upload complete"
    return 0
}

upload_b2() {
    if [ "$ENABLE_B2" -ne 1 ]; then
        log "INFO" "Backblaze B2 upload disabled by config"
        return 0
    fi

    if ! command -v b2 >/dev/null 2>&1; then
        log "WARN" "Backblaze B2 CLI not installed — skipping B2 upload"
        return 0
    fi

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would upload $UPLOAD_SOURCE and $HASH_FILE to $B2_PATH"
        return 0
    fi

    log "INFO" "Uploading backup to Backblaze B2: $B2_PATH"
    b2 upload-file "$B2_BUCKET" "$UPLOAD_SOURCE" "pi-star/${MACHINE_ID}/${DATE}/$(basename "$UPLOAD_SOURCE")" >>"$LOGFILE" 2>&1 || return 1
    b2 upload-file "$B2_BUCKET" "$HASH_FILE" "pi-star/${MACHINE_ID}/${DATE}/$(basename "$HASH_FILE")" >>"$LOGFILE" 2>&1 || return 1
    log "INFO" "B2 upload complete"
    return 0
}

upload_onedrive() {
    if [ "$ENABLE_ONEDRIVE" -ne 1 ]; then
        log "INFO" "OneDrive upload disabled by config"
        return 0
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        log "WARN" "rclone not installed — skipping OneDrive upload"
        return 0
    fi

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would upload $UPLOAD_SOURCE and $HASH_FILE to $ONEDRIVE_PATH"
        return 0
    fi

    log "INFO" "Uploading backup to OneDrive: $ONEDRIVE_PATH"
    rclone copy "$UPLOAD_SOURCE" "$ONEDRIVE_PATH" >>"$LOGFILE" 2>&1 || return 1
    rclone copy "$HASH_FILE" "$ONEDRIVE_PATH" >>"$LOGFILE" 2>&1 || return 1
    log "INFO" "OneDrive upload complete"
    return 0
}

run_cloud_uploads() {
    log "INFO" "Starting cloud upload phase"

    local upload_failed=0

    upload_s3 || upload_failed=1
    upload_b2 || upload_failed=1
    upload_onedrive || upload_failed=1

    if [ "$upload_failed" -eq 1 ]; then
        STEP_UPLOAD="WARN"
        if [ "$CLOUD_FATAL" -eq 1 ]; then
            fatal 40 "One or more cloud uploads failed and CLOUD_FATAL=1"
        else
            log "WARN" "One or more cloud uploads failed, but continuing (CLOUD_FATAL=0)"
        fi
    else
        STEP_UPLOAD="OK"
    fi
}

#---------------------------#
# RETENTION
#---------------------------#

prune_local_backups() {
    log "INFO" "Applying local retention: keep last $LOCAL_RETENTION_COUNT backups for $MACHINE_ID"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would prune local backups under $BACKUP_DIR/$MACHINE_ID"
        STEP_RETENTION_LOCAL="DRYRUN"
        return 0
    fi

    local base="$BACKUP_DIR/$MACHINE_ID"
    [ -d "$base" ] || { log "INFO" "No local backup directory to prune"; STEP_RETENTION_LOCAL="SKIPPED"; return 0; }

    mapfile -t backups < <(ls -1 "$base" | sort)

    local count=${#backups[@]}
    if [ "$count" -le "$LOCAL_RETENTION_COUNT" ]; then
        log "INFO" "Local backups within retention limit ($count <= $LOCAL_RETENTION_COUNT)"
        STEP_RETENTION_LOCAL="OK"
        return 0
    fi

    local to_delete=$((count - LOCAL_RETENTION_COUNT))
    log "INFO" "Pruning $to_delete old local backups"

    for ((i=0; i<to_delete; i++)); do
        local target="$base/${backups[$i]}"
        log "INFO" "Deleting local backup: $target"
        rm -rf "$target"
    done

    STEP_RETENTION_LOCAL="OK"
}

prune_onedrive_backups() {
    if [ "$ENABLE_ONEDRIVE" -ne 1 ]; then
        STEP_RETENTION_CLOUD="SKIPPED"
        return 0
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        log "WARN" "rclone not installed — skipping OneDrive retention"
        STEP_RETENTION_CLOUD="SKIPPED"
        return 0
    fi

    if [ "$ONEDRIVE_RETENTION_DAYS" -le 0 ]; then
        log "INFO" "OneDrive retention disabled (ONEDRIVE_RETENTION_DAYS <= 0)"
        STEP_RETENTION_CLOUD="SKIPPED"
        return 0
    fi

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would prune OneDrive backups older than $ONEDRIVE_RETENTION_DAYS days under $ONEDRIVE_BASE/$MACHINE_ID"
        STEP_RETENTION_CLOUD="DRYRUN"
        return 0
    fi

    log "INFO" "Pruning OneDrive backups older than $ONEDRIVE_RETENTION_DAYS days"
    rclone delete "$ONEDRIVE_BASE/$MACHINE_ID" --min-age "${ONEDRIVE_RETENTION_DAYS}d" >>"$LOGFILE" 2>&1 || {
        log "WARN" "OneDrive retention pruning encountered errors"
        STEP_RETENTION_CLOUD="WARN"
        return 0
    }

    STEP_RETENTION_CLOUD="OK"
}

#---------------------------#
# REBOOT HANDLING
#---------------------------#

handle_reboot() {
    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would reboot if required"
        return 0
    fi

    if [ -f /tmp/pistar-upgrade-required ]; then
        log "INFO" "Reboot required by Pi-Star. Rebooting now..."
        sudo rm /tmp/pistar-upgrade-required
        sudo reboot
    else
        log "INFO" "No reboot required."
    fi
}

#---------------------------#
# EMAIL NOTIFICATIONS
#---------------------------#

send_email() {
    local status="$1"

    if [ "$ENABLE_EMAIL" -ne 1 ]; then
        STEP_EMAIL="SKIPPED"
        return 0
    fi

    if ! command -v mail >/dev/null 2>&1 && ! command -v mailx >/dev/null 2>&1; then
        log "WARN" "mail/mailx not installed — skipping email notification"
        STEP_EMAIL="SKIPPED"
        return 0
    fi

    local mail_cmd
    if command -v mailx >/dev/null 2>&1; then
        mail_cmd="mailx"
    else
        mail_cmd="mail"
    fi

    local subject="${EMAIL_SUBJECT_PREFIX} ${status} on ${MACHINE_ID}"
    local body_file
    body_file=$(mktemp)

    {
        echo "Pi-Star Maintenance Report"
        echo "Machine: $MACHINE_ID"
        echo "Date:    $DATE"
        echo "Status:  $status"
        echo
        echo "Steps:"
        echo "  Backup:          $STEP_BACKUP"
        echo "  Compression:     $STEP_COMPRESS"
        echo "  Hashing:         $STEP_HASH"
        echo "  Update:          $STEP_UPDATE"
        echo "  Upload:          $STEP_UPLOAD"
        echo "  Local retention: $STEP_RETENTION_LOCAL"
        echo "  Cloud retention: $STEP_RETENTION_CLOUD"
        echo "  Self-update:     $STEP_SELF_UPDATE"
        echo "  Dry run:         $DRYRUN"
        echo
        echo "Log tail:"
        echo "----------"
        tail -n 50 "$LOGFILE" 2>/dev/null || echo "(log not available)"
    } > "$body_file"

    if [ "$DRYRUN" -eq 1 ]; then
        log "INFO" "[DRY RUN] Would send email to $EMAIL_TO with subject: $subject"
        rm -f "$body_file"
        STEP_EMAIL="DRYRUN"
        return 0
    fi

    if ! $mail_cmd -r "$EMAIL_FROM" -s "$subject" "$EMAIL_TO" < "$body_file"; then
        log "WARN" "Failed to send email notification"
        rm -f "$body_file"
        STEP_EMAIL="FAILED"
        return 1
    fi

    rm -f "$body_file"
    log "INFO" "Email notification sent to $EMAIL_TO"
    STEP_EMAIL="OK"
    return 0
}

#---------------------------#
# SUMMARY / EXIT
#---------------------------#

print_summary() {
    log "INFO" "===== RUN SUMMARY ====="
    log "INFO" "Script version:   $SCRIPT_VERSION"
    log "INFO" "Machine ID:       $MACHINE_ID"
    log "INFO" "Backup step:      $STEP_BACKUP"
    log "INFO" "Compression step: $STEP_COMPRESS"
    log "INFO" "Hashing step:     $STEP_HASH"
    log "INFO" "Update step:      $STEP_UPDATE"
    log "INFO" "Upload step:      $STEP_UPLOAD"
    log "INFO" "Local retention:  $STEP_RETENTION_LOCAL"
    log "INFO" "Cloud retention:  $STEP_RETENTION_CLOUD"
    log "INFO" "Self-update:      $STEP_SELF_UPDATE"
    log "INFO" "Email step:       $STEP_EMAIL"
    log "INFO" "Dry run:          $DRYRUN"
    log "INFO" "======================="
}

#---------------------------#
# MAIN
#---------------------------#

log "INFO" "Starting Pi-Star maintenance run at $DATE (DRYRUN=$DRYRUN, VERSION=$SCRIPT_VERSION)"

self_update
backup_configs
compress_backup
generate_hashes
verify_hashes
run_pistar_update
run_cloud_uploads
prune_local_backups
prune_onedrive_backups
print_summary
send_email "SUCCESS" || true
handle_reboot

log "INFO" "Pi-Star maintenance run completed successfully"
exit 0

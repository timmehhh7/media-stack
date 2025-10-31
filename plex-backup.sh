#!/bin/bash

################################################################################
# Plex Backup Script
# 
# This script performs a weekly backup of the Plex configuration directory.
# It stops the Plex container, creates a compressed tar.gz backup, restarts
# Plex, and manages backup retention (keeping only the 8 most recent backups).
#
# Usage: Run via cron at 4am every Monday
# Crontab entry: 0 4 * * 1 /usr/local/bin/plex-backup.sh
# Note: Logging is handled internally to timestamped log files in the backup directory
################################################################################

# Configuration
PLEX_CONFIG_DIR="/home/tim/PlexConfig"
BACKUP_DIR="/mnt/MEDIA/Backups/Plex"
COMPOSE_FILE="/home/tim/media-stack/docker-compose.yml"
PLEX_CONTAINER="plex"
MAX_BACKUPS=8
DATE_FORMAT=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILENAME="plex-backup_${DATE_FORMAT}.tar.gz"
LOG_FILENAME="plex-backup_${DATE_FORMAT}.log"
LOG_FILE="${BACKUP_DIR}/${LOG_FILENAME}"
LOG_PREFIX="[Plex Backup]"

# Colors for output (optional, but helpful for log readability)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

################################################################################
# Functions
################################################################################

ensure_log_file() {
    # Ensure log file exists before writing to it
    if [ ! -f "$LOG_FILE" ] && [ -d "$BACKUP_DIR" ]; then
        touch "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info() {
    ensure_log_file
    local message="${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"
    if [ -f "$LOG_FILE" ]; then
        echo -e "${GREEN}${message}${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${GREEN}${message}${NC}"
    fi
}

log_warn() {
    ensure_log_file
    local message="${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1"
    if [ -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}${message}${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${YELLOW}${message}${NC}"
    fi
}

log_error() {
    ensure_log_file
    local message="${LOG_PREFIX} [$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    if [ -f "$LOG_FILE" ]; then
        echo -e "${RED}${message}${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${RED}${message}${NC}"
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if source directory exists
    if [ ! -d "$PLEX_CONFIG_DIR" ]; then
        log_error "Plex config directory not found: $PLEX_CONFIG_DIR"
        exit 1
    fi
    
    # Create backup directory if it doesn't exist
    if [ ! -d "$BACKUP_DIR" ]; then
        log_warn "Backup directory not found. Creating: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR"
        if [ $? -ne 0 ]; then
            log_error "Failed to create backup directory"
            exit 1
        fi
    fi
    
    # Initialize log file (if not already created by logging functions)
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to create log file: $LOG_FILE" >&2
            exit 1
        fi
        log_info "Log file initialized: $LOG_FILENAME"
    fi
    
    # Check if docker is available
    if ! command -v docker &> /dev/null; then
        log_error "Docker command not found"
        exit 1
    fi
    
    # Check if docker compose is available
    if ! command -v docker compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose command not found"
        exit 1
    fi
    
    # Check if compose file exists
    if [ ! -f "$COMPOSE_FILE" ]; then
        log_error "Docker Compose file not found: $COMPOSE_FILE"
        log_error "Please update COMPOSE_FILE variable in the script"
        exit 1
    fi
    
    # Check if Plex container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER}$"; then
        log_error "Plex container '${PLEX_CONTAINER}' not found"
        exit 1
    fi
    
    log_info "Prerequisites check passed"
}

stop_plex() {
    log_info "Stopping Plex container using Docker Compose..."
    
    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${PLEX_CONTAINER}$"; then
        docker compose -f "$COMPOSE_FILE" stop "$PLEX_CONTAINER"
        if [ $? -ne 0 ]; then
            log_error "Failed to stop Plex container"
            exit 1
        fi
        log_info "Plex container stopped successfully"
        
        # Wait a moment to ensure Plex has fully stopped
        sleep 5
    else
        log_warn "Plex container was not running"
    fi
}

start_plex() {
    log_info "Starting Plex container using Docker Compose..."
    
    docker compose -f "$COMPOSE_FILE" start "$PLEX_CONTAINER"
    if [ $? -ne 0 ]; then
        log_error "Failed to start Plex container"
        exit 1
    fi
    
    log_info "Plex container started successfully"
    
    # Wait for Plex to initialize
    log_info "Waiting for Plex to initialize..."
    sleep 10
}

create_backup() {
    log_info "Creating backup: $BACKUP_FILENAME"
    log_info "Source: $PLEX_CONFIG_DIR"
    log_info "Destination: $BACKUP_DIR/$BACKUP_FILENAME"
    
    # Get the size of the directory to backup
    SOURCE_SIZE=$(du -sh "$PLEX_CONFIG_DIR" | cut -f1)
    log_info "Source directory size: $SOURCE_SIZE"
    
    # Create the backup using tar with gzip compression
    # We cd to the parent directory and tar the directory name to avoid absolute paths
    PARENT_DIR=$(dirname "$PLEX_CONFIG_DIR")
    DIR_NAME=$(basename "$PLEX_CONFIG_DIR")
    
    cd "$PARENT_DIR" || exit 1
    
    # Exclude unnecessary directories that can be regenerated or are temporary
    # Based on actual Plex structure: PlexConfig/Library/Application Support/Plex Media Server/{Cache,Crash Reports,Codecs}
    # Patterns match these directories at various nesting levels for robustness
    log_info "Excluding temporary/cache directories: Cache, Crash Reports, Codecs"
    tar -czf "$BACKUP_DIR/$BACKUP_FILENAME" \
        --exclude="$DIR_NAME/*/Cache" \
        --exclude="$DIR_NAME/*/*/Cache" \
        --exclude="$DIR_NAME/*/*/*/Cache" \
        --exclude="$DIR_NAME/*/*/*/*/Cache" \
        --exclude="$DIR_NAME/*/Crash Reports" \
        --exclude="$DIR_NAME/*/*/Crash Reports" \
        --exclude="$DIR_NAME/*/*/*/Crash Reports" \
        --exclude="$DIR_NAME/*/*/*/*/Crash Reports" \
        --exclude="$DIR_NAME/*/Codecs" \
        --exclude="$DIR_NAME/*/*/Codecs" \
        --exclude="$DIR_NAME/*/*/*/Codecs" \
        --exclude="$DIR_NAME/*/*/*/*/Codecs" \
        "$DIR_NAME" 2>&1 | while read line; do
        log_info "tar: $line"
    done
    
    # Check if backup was successful
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Backup creation failed"
        start_plex  # Make sure Plex is restarted even if backup fails
        exit 1
    fi
    
    # Get the size of the backup file
    if [ -f "$BACKUP_DIR/$BACKUP_FILENAME" ]; then
        BACKUP_SIZE=$(du -sh "$BACKUP_DIR/$BACKUP_FILENAME" | cut -f1)
        log_info "Backup created successfully - Size: $BACKUP_SIZE"
    else
        log_error "Backup file not found after creation"
        start_plex
        exit 1
    fi
}

cleanup_old_backups() {
    log_info "Managing backup retention (keeping ${MAX_BACKUPS} most recent backups)..."
    
    # Count existing backups
    BACKUP_COUNT=$(find "$BACKUP_DIR" -name "plex-backup_*.tar.gz" -type f | wc -l)
    log_info "Current backup count: $BACKUP_COUNT"
    
    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        BACKUPS_TO_DELETE=$((BACKUP_COUNT - MAX_BACKUPS))
        log_info "Removing $BACKUPS_TO_DELETE old backup(s)..."
        
        # Find and delete the oldest backups
        find "$BACKUP_DIR" -name "plex-backup_*.tar.gz" -type f -printf '%T+ %p\n' | \
            sort | \
            head -n "$BACKUPS_TO_DELETE" | \
            cut -d' ' -f2- | \
            while read file; do
                log_info "Deleting old backup: $(basename "$file")"
                rm -f "$file"
                if [ $? -ne 0 ]; then
                    log_warn "Failed to delete: $file"
                fi
            done
    else
        log_info "No old backups to remove (current: $BACKUP_COUNT, max: $MAX_BACKUPS)"
    fi
    
    # List remaining backups
    log_info "Remaining backups:"
    find "$BACKUP_DIR" -name "plex-backup_*.tar.gz" -type f -printf '%T+ %p\n' | \
        sort -r | \
        while read timestamp file; do
            SIZE=$(du -sh "$file" | cut -f1)
            log_info "  - $(basename "$file") (${SIZE})"
        done
    
    # Manage log file retention (same retention policy as backups)
    log_info "Managing log file retention (keeping ${MAX_BACKUPS} most recent logs)..."
    
    # Count existing log files
    LOG_COUNT=$(find "$BACKUP_DIR" -name "plex-backup_*.log" -type f | wc -l)
    log_info "Current log file count: $LOG_COUNT"
    
    if [ "$LOG_COUNT" -gt "$MAX_BACKUPS" ]; then
        LOGS_TO_DELETE=$((LOG_COUNT - MAX_BACKUPS))
        log_info "Removing $LOGS_TO_DELETE old log file(s)..."
        
        # Find and delete the oldest log files
        find "$BACKUP_DIR" -name "plex-backup_*.log" -type f -printf '%T+ %p\n' | \
            sort | \
            head -n "$LOGS_TO_DELETE" | \
            cut -d' ' -f2- | \
            while read file; do
                log_info "Deleting old log file: $(basename "$file")"
                rm -f "$file"
                if [ $? -ne 0 ]; then
                    log_warn "Failed to delete: $file"
                fi
            done
    else
        log_info "No old log files to remove (current: $LOG_COUNT, max: $MAX_BACKUPS)"
    fi
    
    # List remaining log files
    log_info "Remaining log files:"
    find "$BACKUP_DIR" -name "plex-backup_*.log" -type f -printf '%T+ %p\n' | \
        sort -r | \
        while read timestamp file; do
            SIZE=$(du -sh "$file" | cut -f1)
            log_info "  - $(basename "$file") (${SIZE})"
        done
}

################################################################################
# Main Script Execution
################################################################################

log_info "=========================================="
log_info "Plex Backup Script Started"
log_info "=========================================="

# Trap errors to ensure Plex is restarted
trap 'log_error "Script interrupted or failed. Ensuring Plex is restarted..."; start_plex; exit 1' ERR INT TERM

# Execute backup process
check_prerequisites
stop_plex
create_backup
start_plex
cleanup_old_backups

log_info "=========================================="
log_info "Plex Backup Script Completed Successfully"
log_info "=========================================="

exit 0

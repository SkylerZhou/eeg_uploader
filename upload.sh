#!/usr/bin/env bash
# set -euo pipefail


# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
LOG_FILE="upload_log.txt"
RESULTS_FILE="upload_results.csv"

# Initialize results file with header if it doesn't exist
if [[ ! -f "$RESULTS_FILE" ]]; then
    echo "timestamp,dataset_name,status,node_id,manifest_id" > "$RESULTS_FILE"
fi


# --- Helper Functions ---
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $message" | tee -a "$LOG_FILE"
}

record_result() {
    local dataset_name="$1"
    local status="$2"
    local node_id="${3:-}"
    local manifest_id="${4:-}"
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$dataset_name,$status,$node_id,$manifest_id" >> "$RESULTS_FILE"
}


# --- Core Functions ---
run_reorganization() {

    cd "$SCRIPT_DIR"
    if ! python3 reorganize_to_bids.py; then
        log_message "[ERROR]: reorganize_to_bids.py failed"
        exit 1
    fi
    log_message "BIDS reorganization completed"
}

upload_dataset_to_pennsieve() {
    local dataset_folder="$1"
    local dataset_name
    dataset_name=$(basename "$dataset_folder")
    
    log_message ""
    log_message "=================================================="
    log_message "Uploading dataset: $dataset_name"
    log_message "=================================================="
    
    # Create dataset description and tags
    local description="Auto-migrated EEG dataset for $dataset_name from PREVeNT study"
    local tags='["epilepsy.science", "eeg", "PREVeNT", "bids"]'
    
    # === STEP 1: Create Pennsieve dataset ===
    log_message "Creating Pennsieve dataset: $dataset_name"
    local create_output
    
    if ! create_output=$(pennsieve dataset create "$dataset_name" "$description" "$tags" 2>&1); then
        log_message "[ERROR]: Failed to create dataset '$dataset_name'"
        record_result "$dataset_name" "FAILED_CREATION" "" ""
        return 1
    fi
    
    # === STEP 2: Extract dataset NODE ID ===
    local dataset_node_id
    dataset_node_id=$(echo "$create_output" | grep 'NODE ID' | awk -F '|' '{gsub(/ /,"",$3); print $3}')
    
    if [[ -z "$dataset_node_id" ]]; then
        log_message "[ERROR]: Failed to extract dataset NODE ID for '$dataset_name'"
        record_result "$dataset_name" "FAILED_NODE_ID" "" ""
        return 1
    fi
        
    # === STEP 3: Use the dataset ===
    log_message "🎯 Switching to dataset: $dataset_node_id"
    if ! pennsieve dataset use "$dataset_node_id" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "[ERROR]: Failed to switch to dataset '$dataset_name'"
        record_result "$dataset_name" "FAILED_SWITCH" "$dataset_node_id" ""
        return 1
    fi
    
    # === STEP 4: Create manifest ===
    log_message "📦 Creating manifest for: $dataset_folder"
    local manifest_output manifest_id
    
    if ! manifest_output=$(pennsieve manifest create "$dataset_folder" 2>&1); then
        log_message "[ERROR]: Manifest creation failed for '$dataset_name'"
        record_result "$dataset_name" "FAILED_MANIFEST" "$dataset_node_id" ""
        return 1
    fi
    
    # Extract manifest ID
    manifest_id=$(echo "$manifest_output" | grep -oE 'Manifest ID: [^ ]+' | cut -d' ' -f3)
    
    if [[ -z "$manifest_id" ]]; then
        log_message "[ERROR]: Could not extract manifest ID for '$dataset_name'"
        record_result "$dataset_name" "FAILED_MANIFEST_ID" "$dataset_node_id" ""
        return 1
    fi
    
    
    # === STEP 5: Upload manifest with retries ===
    local max_retries=3
    for attempt in $(seq 1 $max_retries); do
        log_message "Upload attempt $attempt/$max_retries for manifest $manifest_id"
        
        # Use timeout and redirect to prevent hanging
        if timeout 1800 pennsieve upload manifest "$manifest_id" </dev/null >>"$LOG_FILE" 2>&1; then
            log_message "Successfully uploaded $dataset_name"
            record_result "$dataset_name" "SUCCESS" "$dataset_node_id" "$manifest_id"
            return 0
        fi
        
        log_message "Upload attempt $attempt failed"
        sleep $((attempt * 10))
    done
    
    log_message "[ERROR]: Failed to upload $dataset_name after $max_retries attempts"
    record_result "$dataset_name" "FAILED_UPLOAD" "$dataset_node_id" "$manifest_id"
    return 1
}

main() {
    # Run BIDS reorganization 
    run_reorganization
    
    # Find all PRV-* folders
    local dataset_folders=()
    while IFS= read -r -d '' folder; do
        dataset_folders+=("$folder")
    done < <(find "$OUTPUT_DIR" -maxdepth 1 -type d -name "PRV-*" -print0 | sort -z)
    
    log_message "Found ${#dataset_folders[@]} datasets to upload:"
    for folder in "${dataset_folders[@]}"; do
        log_message "   - $(basename "$folder")"
    done
    
    # Process each dataset
    local successful_uploads=0
    local failed_uploads=0
    local total_datasets=${#dataset_folders[@]}
    
    for dataset_folder in "${dataset_folders[@]}"; do
        if upload_dataset_to_pennsieve "$dataset_folder"; then
            ((successful_uploads++))
        else
            ((failed_uploads++))
        fi
        
        # Progress update
        local processed=$((successful_uploads + failed_uploads))
        log_message "📊 Progress: $processed/$total_datasets processed (✅ $successful_uploads successful, ❌ $failed_uploads failed)"
    done
    
    
    if [[ $failed_uploads -gt 0 ]]; then
        log_message "[WARNING]: Some uploads failed. Check the logs for details."
        exit 1
    else
        log_message "All uploads completed successfully!"
    fi
}

# Run main function
main "$@"
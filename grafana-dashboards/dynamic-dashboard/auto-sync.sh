#!/usr/bin/env bash
set -euo pipefail

#######################################
# LOAD CONFIGURATION
#######################################

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# Load configuration file
if [[ -f "$CONFIG_FILE" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading configuration from $CONFIG_FILE" >&2
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Configuration file not found: $CONFIG_FILE" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Please create config.env file with required settings" >&2
  exit 1
fi

#######################################
# VALIDATE CONFIGURATION
#######################################

if [[ -z "${GRAFANA_URL:-}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: GRAFANA_URL not set in config.env" >&2
  exit 1
fi

if [[ -z "${GRAFANA_API_KEY:-}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: GRAFANA_API_KEY not set in config.env" >&2
  exit 1
fi

if [[ -z "${PROM_URL:-}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: PROM_URL not set in config.env" >&2
  exit 1
fi

#######################################
# APPLY CONFIGURATION
#######################################

GRAFANA_URL="${GRAFANA_URL%/}"
PROM_URL="${PROM_URL%/}"
API_KEY="$GRAFANA_API_KEY"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
DASHBOARD_DIR="${DASHBOARD_DIR:-dashboards}"
MAX_PARALLEL="${MAX_PARALLEL:-50}"
STATE_FILE="${STATE_FILE:-.grafana_deployed_state}"
ROOT_FOLDER_NAME="${ROOT_FOLDER_NAME:-zos-metrics}"

# Make dashboard directory path absolute if relative
if [[ ! "$DASHBOARD_DIR" = /* ]]; then
  DASHBOARD_DIR="${SCRIPT_DIR}/${DASHBOARD_DIR}"
fi

#######################################
# STATE
#######################################

declare -A DEPLOYED
declare -A FOLDER_CACHE
declare -A FOLDER_PENDING

#######################################
# LOGGING
#######################################

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

#######################################
# UTILS
#######################################

hash12() {
  echo -n "$1" | md5sum | cut -c1-12
}

normalize_name() {
  local raw="$1"
  [[ -z "$raw" || "$raw" == "null" ]] && return 1
  echo "$raw" | cut -d'.' -f1 | tr '[:lower:]' '[:upper:]'
}

#######################################
# SUBSYSTEM DETECTION (STRICT)
#######################################

detect_subsystem() {
  local smf_id
  smf_id=$(echo "$1" | jq -r '.zos_smf_id // empty' | tr '[:lower:]' '[:upper:]')

  case "$smf_id" in
    *DB2* )  echo "DB2" ;;
    *IMS* )  echo "IMS" ;;
    *MQ* )   echo "MQ" ;;
    *CICS* ) echo "CICS" ;;
    * )      echo "UNKNOWN" ;;
  esac
}

#######################################
# TEMPLATE SELECTION
#######################################

template_for_subsystem() {
  case "$1" in
    CICS)    echo "$DASHBOARD_DIR/cics-metrics.json" ;;
    MQ)      echo "$DASHBOARD_DIR/mq-metrics.json" ;;
    IMS)     echo "$DASHBOARD_DIR/ims-metrics.json" ;;
    DB2)     echo "$DASHBOARD_DIR/db2-metrics.json" ;;
    *)       echo "$DASHBOARD_DIR/unknown-metrics.json" ;;
  esac
}

#######################################
# BATCH FOLDER FETCHING
#######################################

fetch_all_folders() {
  log "Fetching all existing folders from Grafana..."
  local response
  response=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/folders?limit=5000" 2>/dev/null || echo "[]")
  
  # Cache all existing folders by hierarchy path
  while read -r folder; do
    local uid title
    uid=$(echo "$folder" | jq -r '.uid')
    title=$(echo "$folder" | jq -r '.title')
    if [[ -n "$uid" && "$uid" != "null" && -n "$title" && "$title" != "null" ]]; then
      FOLDER_CACHE["$title"]="$uid"
    fi
  done < <(echo "$response" | jq -c '.[]?')
  
  log "Cached ${#FOLDER_CACHE[@]} existing folders"
}

#######################################
# OPTIMIZED FOLDER CREATION (SYNCHRONOUS FOR HIERARCHY)
#######################################

get_or_create_folder_fast() {
  local TITLE="$1"
  local PARENT_UID="${2:-}"
  local HIERARCHY_PATH="${3:-}"

  # Check cache first
  if [[ -n "${FOLDER_CACHE[$TITLE]:-}" ]]; then
    echo "${FOLDER_CACHE[$TITLE]}"
    return
  fi

  local FOLDER_UID
  FOLDER_UID=$(hash12 "$HIERARCHY_PATH")

  # Check if folder exists with this UID
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/folders/$FOLDER_UID" 2>/dev/null)

  if [[ "$status" != "200" ]]; then
    # Create folder
    local payload
    if [[ -z "$PARENT_UID" ]]; then
      payload="{\"uid\":\"$FOLDER_UID\",\"title\":\"$TITLE\"}"
    else
      payload="{\"uid\":\"$FOLDER_UID\",\"title\":\"$TITLE\",\"parentUid\":\"$PARENT_UID\"}"
    fi

    local create_response
    create_response=$(curl -s -w "\n%{http_code}" -X POST "$GRAFANA_URL/api/folders" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null)
    
    local create_status
    create_status=$(echo "$create_response" | tail -n1)
    
    if [[ "$create_status" == "409" ]]; then
      # Folder exists, try to find it
      local search_result
      search_result=$(curl -s -H "Authorization: Bearer $API_KEY" \
        "$GRAFANA_URL/api/search?type=dash-folder&query=$TITLE" 2>/dev/null | \
        jq -r ".[] | select(.title == \"$TITLE\") | .uid" | head -1)
      
      if [[ -n "$search_result" && "$search_result" != "null" ]]; then
        FOLDER_UID="$search_result"
      fi
    fi
  fi

  # Cache the result
  FOLDER_CACHE["$TITLE"]="$FOLDER_UID"
  
  echo "$FOLDER_UID"
}

#######################################
# BATCH DASHBOARD DEPLOYMENT
#######################################

deploy_dashboard_batch() {
  local FOLDER_UID="$1"
  local SUBSYS="$2"
  local SUBSYSTEM_ID="$3"

  local TEMPLATE
  TEMPLATE=$(template_for_subsystem "$SUBSYS")

  [[ ! -f "$TEMPLATE" ]] && return

  local DASH_UID
  DASH_UID=$(hash12 "$FOLDER_UID-$SUBSYSTEM_ID")

  # Read template content into variable
  local DASHBOARD_JSON
  DASHBOARD_JSON=$(sed \
    -e "s|\${DASH_UID}|$DASH_UID|g" \
    -e "s|\${DASH_TITLE}|$SUBSYSTEM_ID|g" \
    -e "s|\${SUBSYSTEM_ID}|$SUBSYSTEM_ID|g" \
    "$TEMPLATE")

  # Deploy in background (non-blocking) - use here-doc to avoid temp file issues
  (
    curl -s -X POST "$GRAFANA_URL/api/dashboards/db" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"dashboard\": $DASHBOARD_JSON,
        \"folderUid\": \"$FOLDER_UID\",
        \"overwrite\": true
      }" > /dev/null 2>&1
  ) &
}

#######################################
# PARALLEL JOB CONTROL
#######################################

wait_for_jobs() {
  local max_jobs=$1
  while [ $(jobs -r | wc -l) -ge $max_jobs ]; do
    sleep 0.1
  done
}

#######################################
# PERSISTENT STATE MANAGEMENT
#######################################

load_deployed_state() {
  if [[ -f "$STATE_FILE" ]]; then
    while IFS='|' read -r key; do
      DEPLOYED["$key"]=1
    done < "$STATE_FILE"
    log "Loaded ${#DEPLOYED[@]} previously deployed dashboards from state file"
  else
    log "No previous state file found, starting fresh"
  fi
}

save_deployed_state() {
  > "$STATE_FILE"  # Clear file
  for key in "${!DEPLOYED[@]}"; do
    echo "$key" >> "$STATE_FILE"
  done
  log "Saved ${#DEPLOYED[@]} deployed dashboards to state file"
}

#######################################
# CACHE VALIDATION (DETECT DELETED DASHBOARDS)
#######################################

validate_deployed_cache() {
  local cache_size=${#DEPLOYED[@]}
  
  if [[ $cache_size -eq 0 ]]; then
    log "No cached dashboards to validate"
    return
  fi
  
  log "Validating ${cache_size} cached dashboards against Grafana..."
  
  # Create temporary file for validation results
  local temp_validation="/tmp/grafana_validation_$$"
  > "$temp_validation"
  
  # Validate each cached dashboard in parallel
  local validation_jobs=0
  for key in "${!DEPLOYED[@]}"; do
    (
      # Parse the key: SYSPLEX|SYSTEM|SUBSYS|SERVICE
      IFS='|' read -r SYSPLEX SYSTEM SUBSYS SERVICE <<< "$key"
      
      # Reconstruct the folder path and dashboard UID
      ROOT_PATH="zos-metrics"
      SYSPLEX_PATH="${ROOT_PATH}::${SYSPLEX}"
      SYSTEM_LPAR_PATH="${SYSPLEX_PATH}::${SYSTEM}"
      SUBSYS_PATH="${SYSTEM_LPAR_PATH}::${SUBSYS}"
      
      FOLDER_UID=$(hash12 "$SUBSYS_PATH")
      DASH_UID=$(hash12 "$FOLDER_UID-$SERVICE")
      
      # Check if dashboard exists in Grafana
      local status
      status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        "$GRAFANA_URL/api/dashboards/uid/$DASH_UID" 2>/dev/null)
      
      # If dashboard doesn't exist (404), mark for deletion from cache
      if [[ "$status" == "404" ]]; then
        echo "$key" >> "$temp_validation"
      fi
    ) &
    
    validation_jobs=$((validation_jobs + 1))
    
    # Control parallel jobs
    if [[ $validation_jobs -ge $MAX_PARALLEL ]]; then
      wait -n 2>/dev/null || true
      validation_jobs=$((validation_jobs - 1))
    fi
  done
  
  # Wait for all validation jobs to complete
  wait
  
  # Process validation results
  local deleted_count=0
  if [[ -f "$temp_validation" && -s "$temp_validation" ]]; then
    while IFS= read -r key; do
      if [[ -n "$key" ]]; then
        unset 'DEPLOYED[$key]'
        deleted_count=$((deleted_count + 1))
        log "  ⚠ Dashboard deleted from Grafana: $key"
      fi
    done < "$temp_validation"
  fi
  
  # Cleanup
  rm -f "$temp_validation"
  
  if [[ $deleted_count -gt 0 ]]; then
    log "Removed ${deleted_count} deleted dashboard(s) from cache"
    log "These dashboards will be recreated in the next sync cycle"
    # Save updated state immediately
    save_deployed_state
  else
    log "✓ All ${cache_size} cached dashboards are present in Grafana"
  fi
}

#######################################
# GRAFANA DATASOURCE SETUP (ONE-TIME)
#######################################

setup_grafana_datasource() {
  local DATASOURCE_NAME="prometheusDatasource"
  local DATASOURCE_UID="prometheusDatasource"
  local DATASOURCE_MARKER=".grafana_datasource_created"
  
  log "Checking Grafana datasource setup..."
  
  # Check if datasource already exists in Grafana
  RESPONSE=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/datasources/name/$DATASOURCE_NAME" 2>/dev/null)
  
  if echo "$RESPONSE" | grep -q "\"name\":\"$DATASOURCE_NAME\""; then
    log "✓ Datasource '$DATASOURCE_NAME' already exists in Grafana"
    touch "$DATASOURCE_MARKER"
    return 0
  fi
  
  if [ -f "$DATASOURCE_MARKER" ]; then
    log "⚠ Marker file exists but datasource not found in Grafana"
    rm -f "$DATASOURCE_MARKER"
  fi
  
  log "Creating Prometheus datasource '$DATASOURCE_NAME'..."
  
  PAYLOAD=$(cat <<EOF
{
  "name": "prometheusDatasource",
  "type": "prometheus",
  "uid": "prometheusDatasource",
  "url": "$PROM_URL",
  "access": "proxy",
  "isDefault": true,
  "basicAuth": false,
  "jsonData": {
    "httpMethod": "POST",
    "timeInterval": "15s",
    "queryTimeout": "60s"
  }
}
EOF
)
  
  CREATE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/datasources" \
    -d "$PAYLOAD")
  
  HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -n1)
  
  if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
    log "✓ Datasource created successfully!"
    touch "$DATASOURCE_MARKER"
  else
    log "⚠ Failed to create datasource (HTTP $HTTP_CODE)"
  fi
}

#######################################
# MAIN LOOP
#######################################

log "Starting Grafana hierarchy sync (OPTIMIZED MODE)"

# Setup Grafana datasource (runs only once)
setup_grafana_datasource

while true; do
  START_TIME=$(date +%s)
  
  # Load previously deployed dashboards from state file
  DEPLOYED=()
  load_deployed_state
  
  # Validate cache: detect dashboards that were manually deleted from Grafana
  validate_deployed_cache
  
  FOLDER_CACHE=()
  FOLDER_PENDING=()

  # Fetch all existing folders once
  fetch_all_folders

  log "Fetching metrics from Prometheus..."
  RESPONSE=$(curl -s -G "$PROM_URL/api/v1/series" \
    --data-urlencode 'match[]={zos_smf_id!=""}' \
    --data-urlencode "start=$(date -u -d "$CHECK_INTERVAL seconds ago" +%s)" \
    --data-urlencode "end=$(date -u +%s)")

  # Track unique folder hierarchies
  declare -A ROOT_FOLDER
  declare -A SYSPLEX_FOLDERS
  declare -A SYSTEM_FOLDERS
  declare -A SUBSYS_FOLDERS
  
  log "Processing metrics and building hierarchy..."
  
  # Initialize DASHBOARD_JOBS array BEFORE the loop (prevents unbound variable error)
  DASHBOARD_JOBS=()
  
  # Define root folder
  ROOT_FOLDER["zos-metrics"]="zos-metrics"
  
  # Use jq to extract and deduplicate in one pass (MUCH faster than bash loop)
  while IFS='|' read -r SYSPLEX SYSTEM_OR_LPAR SUBSYS SERVICE_NAME; do
    [[ -z "$SYSPLEX" || -z "$SYSTEM_OR_LPAR" || -z "$SUBSYS" || -z "$SERVICE_NAME" ]] && continue
    
    KEY="$SYSPLEX|$SYSTEM_OR_LPAR|$SUBSYS|$SERVICE_NAME"
    if [[ -n "${DEPLOYED[$KEY]:-}" ]]; then
      continue
    fi
    DEPLOYED[$KEY]=1

    # Build hierarchical paths with root folder
    ROOT_PATH="zos-metrics"
    SYSPLEX_PATH="${ROOT_PATH}::${SYSPLEX}"
    SYSPLEX_TITLE="zos-metrics/${SYSPLEX}"
    SYSTEM_LPAR_PATH="${SYSPLEX_PATH}::${SYSTEM_OR_LPAR}"
    SYSTEM_LPAR_TITLE="zos-metrics/${SYSPLEX}/${SYSTEM_OR_LPAR}"
    SUBSYS_PATH="${SYSTEM_LPAR_PATH}::${SUBSYS}"
    SUBSYS_TITLE="zos-metrics/${SYSPLEX}/${SYSTEM_OR_LPAR}/${SUBSYS}"

    # Track unique folders at each level
    SYSPLEX_FOLDERS["$SYSPLEX_PATH"]="$SYSPLEX_TITLE|$ROOT_PATH"
    SYSTEM_FOLDERS["$SYSTEM_LPAR_PATH"]="$SYSTEM_LPAR_TITLE|$SYSPLEX_PATH"
    SUBSYS_FOLDERS["$SUBSYS_PATH"]="$SUBSYS_TITLE|$SYSTEM_LPAR_PATH"
    
    # Store dashboard deployment info
    DASHBOARD_JOBS+=("$SUBSYS_PATH|$SUBSYS|$SERVICE_NAME")

  done < <(echo "$RESPONSE" | jq -r '
    .data[]? |
    # Use label names with underscores (Prometheus converts dots to underscores)
    select(.zos_sysplex and .zos_sysplex != "null" and .zos_sysplex != "") |
    select(.service_namespace and .service_namespace != "null" and .service_namespace != "") |
    select(.service_name and .service_name != "null" and .service_name != "") |
    select(.zos_smf_id and .zos_smf_id != "null" and .zos_smf_id != "") |
    {
      # Resource attributes converted to labels with underscores
      sysplex: (.zos_sysplex | split(".")[0] | ascii_upcase),
      system_or_lpar: (.service_namespace | split(".")[0] | ascii_upcase),
      subsystem: .service_name,
      zos_smf_id: (.zos_smf_id | ascii_upcase),
      service_name: .service_name,
      subsys_type: (
        if (.zos_smf_id | ascii_upcase | contains("DB2")) then "DB2"
        elif (.zos_smf_id | ascii_upcase | contains("IMS")) then "IMS"
        elif (.zos_smf_id | ascii_upcase | contains("MQ")) then "MQ"
        elif (.zos_smf_id | ascii_upcase | contains("CICS")) then "CICS"
        else "UNKNOWN"
        end
      )
    } |
    "\(.sysplex)|\(.system_or_lpar)|\(.subsys_type)|\(.service_name)"
  ' | sort -u)

  # DASHBOARD_JOBS only contains NEW dashboards (already filtered in loop above)
  if [[ ${#DASHBOARD_JOBS[@]} -eq 0 ]]; then
    NEW_DASHBOARDS=0
  else
    NEW_DASHBOARDS=${#DASHBOARD_JOBS[@]}
  fi
  
  TOTAL_DEPLOYED=${#DEPLOYED[@]}
  PREVIOUSLY_DEPLOYED=$((TOTAL_DEPLOYED - NEW_DASHBOARDS))
  
  log "Found ${NEW_DASHBOARDS} new dashboards to deploy (${PREVIOUSLY_DEPLOYED} already deployed, ${TOTAL_DEPLOYED} total)"
  
  # Skip deployment if no new dashboards
  if [[ $NEW_DASHBOARDS -eq 0 ]]; then
    log "No new dashboards to deploy, skipping..."
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    log "✓ Sync complete in ${ELAPSED}s. No changes needed."
    log "Sleeping ${CHECK_INTERVAL}s..."
    sleep "$CHECK_INTERVAL"
    continue
  fi

  # Create folder hierarchy level by level (ensures parent-child relationships)
  log "Creating root folder (zos-metrics)..."
  ROOT_UID=$(get_or_create_folder_fast "zos-metrics" "" "zos-metrics")
  
  log "Creating SYSPLEX folders..."
  for path in "${!SYSPLEX_FOLDERS[@]}"; do
    IFS='|' read -r title parent_path <<< "${SYSPLEX_FOLDERS[$path]}"
    get_or_create_folder_fast "$title" "$ROOT_UID" "$path" > /dev/null &
    wait_for_jobs $MAX_PARALLEL
  done
  wait  # Wait for all SYSPLEX folders

  log "Creating SYSTEM/LPAR folders..."
  for path in "${!SYSTEM_FOLDERS[@]}"; do
    IFS='|' read -r title parent_path <<< "${SYSTEM_FOLDERS[$path]}"
    parent_uid=$(hash12 "$parent_path")
    get_or_create_folder_fast "$title" "$parent_uid" "$path" > /dev/null &
    wait_for_jobs $MAX_PARALLEL
  done
  wait  # Wait for all SYSTEM folders

  log "Creating SUBSYSTEM folders..."
  for path in "${!SUBSYS_FOLDERS[@]}"; do
    IFS='|' read -r title parent_path <<< "${SUBSYS_FOLDERS[$path]}"
    parent_uid=$(hash12 "$parent_path")
    get_or_create_folder_fast "$title" "$parent_uid" "$path" > /dev/null &
    wait_for_jobs $MAX_PARALLEL
  done
  wait  # Wait for all SUBSYSTEM folders

  # Deploy all dashboards in parallel (with job control)
  log "Deploying ${#DASHBOARD_JOBS[@]} dashboards in parallel..."
  for job in "${DASHBOARD_JOBS[@]}"; do
    IFS='|' read -r SUBSYS_PATH SUBSYS SERVICE_NAME <<< "$job"
    
    FOLDER_UID=$(hash12 "$SUBSYS_PATH")
    deploy_dashboard_batch "$FOLDER_UID" "$SUBSYS" "$SERVICE_NAME"
    
    wait_for_jobs $MAX_PARALLEL
  done

  # Wait for all dashboard deployments to complete
  log "Waiting for dashboard deployment to complete..."
  wait

  # Save state after successful deployment
  save_deployed_state

  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  
  log "✓ Sync complete in ${ELAPSED}s. Deployed ${NEW_DASHBOARDS} new dashboards (${#DEPLOYED[@]} total tracked)."
  log "Sleeping ${CHECK_INTERVAL}s..."
  sleep "$CHECK_INTERVAL"
done
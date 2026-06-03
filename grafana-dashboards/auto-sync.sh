#!/usr/bin/env bash
set -euo pipefail

#######################################
# Grafana Dashboard Mode Switcher
# Supports both static and dynamic dashboard modes
#######################################

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
PID_FILE="${SCRIPT_DIR}/.auto-sync.pid"

#######################################
# LOAD CONFIGURATION
#######################################

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    log "Loading configuration from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
  fi
}

#######################################
# VALIDATE CONFIGURATION
#######################################

validate_config() {
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

  if [[ "${GRAFANA_API_KEY}" == "your-grafana-api-key-here" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: GRAFANA_API_KEY is still set to the placeholder value in config.env" >&2
    exit 1
  fi

  if [[ ! "${GRAFANA_URL}" =~ ^https?:// ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: GRAFANA_URL must start with http:// or https://" >&2
    exit 1
  fi

  if [[ ! "${PROM_URL}" =~ ^https?:// ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: PROM_URL must start with http:// or https://" >&2
    exit 1
  fi

  if [[ -n "${CHECK_INTERVAL:-}" ]] && ! [[ "${CHECK_INTERVAL}" =~ ^[0-9]+$ ]] ; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: CHECK_INTERVAL must be a positive integer" >&2
    exit 1
  fi

  if [[ -n "${CHECK_INTERVAL:-}" ]] && [[ "${CHECK_INTERVAL}" -le 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: CHECK_INTERVAL must be greater than 0" >&2
    exit 1
  fi

  if [[ -n "${MAX_PARALLEL:-}" ]] && ! [[ "${MAX_PARALLEL}" =~ ^[0-9]+$ ]] ; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: MAX_PARALLEL must be a positive integer" >&2
    exit 1
  fi

  if [[ -n "${MAX_PARALLEL:-}" ]] && [[ "${MAX_PARALLEL}" -le 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: MAX_PARALLEL must be greater than 0" >&2
    exit 1
  fi
}

validate_runtime_dependencies() {
  local missing=0

  for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Required command not found: $cmd" >&2
      missing=1
    fi
  done

  if ! command -v md5sum >/dev/null 2>&1 && ! command -v md5 >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Required hash command not found: md5sum or md5" >&2
    missing=1
  fi

  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

validate_paths() {
  local dashboard_dir="${DASHBOARD_DIR:-dashboards}"

  if [[ ! "$dashboard_dir" = /* ]]; then
    dashboard_dir="${SCRIPT_DIR}/${dashboard_dir}"
  fi

  if [[ ! -d "$dashboard_dir" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Dashboard directory not found: $dashboard_dir" >&2
    exit 1
  fi
}

validate_connectivity() {
  local grafana_health_url="${GRAFANA_URL%/}/api/health"
  local prometheus_ready_url="${PROM_URL%/}/-/ready"
  local http_code

  log "Validating Grafana connectivity..."
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$grafana_health_url" 2>/dev/null || true)
  if [[ "$http_code" != "200" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Unable to reach Grafana health endpoint: $grafana_health_url (HTTP ${http_code:-000})" >&2
    exit 1
  fi

  log "Validating Grafana API key..."
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $GRAFANA_API_KEY" \
    "${GRAFANA_URL%/}/api/user" 2>/dev/null || true)
  if [[ "$http_code" != "200" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Grafana API key validation failed at ${GRAFANA_URL%/}/api/user (HTTP ${http_code:-000})" >&2
    exit 1
  fi

  log "Validating Prometheus connectivity..."
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$prometheus_ready_url" 2>/dev/null || true)
  if [[ "$http_code" != "200" ]]; then
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${PROM_URL%/}/api/v1/status/config" 2>/dev/null || true)
    if [[ "$http_code" != "200" ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Unable to reach Prometheus at ${PROM_URL%/} (ready/config check failed, HTTP ${http_code:-000})" >&2
      exit 1
    fi
  fi
}

#######################################
# APPLY CONFIGURATION
#######################################

apply_config() {
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
}

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
# TEMPLATE SELECTION & CONVERSION
#######################################

template_for_subsystem() {
  case "$1" in
    CICS)    echo "$DASHBOARD_DIR/cics-metrics.json" ;;
    MQ)      echo "$DASHBOARD_DIR/mq-metrics.json" ;;
    IMS)     echo "$DASHBOARD_DIR/ims-metrics.json" ;;
    DB2)     echo "$DASHBOARD_DIR/db2-metrics.json" ;;
    *)       return 1 ;;
  esac
}

# Convert static dashboard JSON to dynamic format
convert_dashboard_to_dynamic() {
  local input_json="$1"
  
  # Convert prometheus datasource UID to variable
  # Convert service_name to zos_smf_id in legend format
  echo "$input_json" | \
    sed 's/"uid": "prometheus"/"uid": "prometheusDatasource"/g' | \
    sed 's/{{service_name}}/{{zos_smf_id}}/g'
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
# OPTIMIZED FOLDER CREATION
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

  # Read and convert template
  local DASHBOARD_JSON
  DASHBOARD_JSON=$(cat "$TEMPLATE")
  DASHBOARD_JSON=$(convert_dashboard_to_dynamic "$DASHBOARD_JSON")
  
  # Replace placeholders
  DASHBOARD_JSON=$(echo "$DASHBOARD_JSON" | sed \
    -e "s|\${DASH_UID}|$DASH_UID|g" \
    -e "s|\${DASH_TITLE}|$SUBSYSTEM_ID|g" \
    -e "s|\${SUBSYSTEM_ID}|$SUBSYSTEM_ID|g")

  # Deploy in background
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
# CACHE VALIDATION
#######################################

validate_deployed_cache() {
  local cache_size=${#DEPLOYED[@]}
  
  if [[ $cache_size -eq 0 ]]; then
    return
  fi
  
  log "Validating ${cache_size} cached dashboards against Grafana..."
  
  local temp_validation="/tmp/grafana_validation_$$"
  > "$temp_validation"
  
  local validation_jobs=0
  for key in "${!DEPLOYED[@]}"; do
    (
      IFS='|' read -r SYSPLEX SYSTEM SUBSYS SERVICE <<< "$key"
      
      ROOT_PATH="zos-metrics"
      SYSPLEX_PATH="${ROOT_PATH}::${SYSPLEX}"
      SYSTEM_LPAR_PATH="${SYSPLEX_PATH}::${SYSTEM}"
      SUBSYS_PATH="${SYSTEM_LPAR_PATH}::${SUBSYS}"
      
      FOLDER_UID=$(hash12 "$SUBSYS_PATH")
      DASH_UID=$(hash12 "$FOLDER_UID-$SERVICE")
      
      local status
      status=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        "$GRAFANA_URL/api/dashboards/uid/$DASH_UID" 2>/dev/null)
      
      if [[ "$status" == "404" ]]; then
        echo "$key" >> "$temp_validation"
      fi
    ) &
    
    validation_jobs=$((validation_jobs + 1))
    
    if [[ $validation_jobs -ge $MAX_PARALLEL ]]; then
      wait -n 2>/dev/null || true
      validation_jobs=$((validation_jobs - 1))
    fi
  done
  
  wait
  
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
  
  rm -f "$temp_validation"
  
  if [[ $deleted_count -gt 0 ]]; then
    log "Removed ${deleted_count} deleted dashboard(s) from cache"
    save_deployed_state
  fi
}

#######################################
# GRAFANA DATASOURCE SETUP
#######################################

setup_grafana_datasource() {
  local DATASOURCE_NAME="prometheusDatasource"
  local DATASOURCE_UID="prometheusDatasource"
  
  log "Checking Grafana datasource setup..."
  
  RESPONSE=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/datasources/name/$DATASOURCE_NAME" 2>/dev/null)
  
  if echo "$RESPONSE" | grep -q "\"name\":\"$DATASOURCE_NAME\""; then
    log "✓ Datasource '$DATASOURCE_NAME' already exists in Grafana"
    return 0
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
  else
    log "⚠ Failed to create datasource (HTTP $HTTP_CODE)"
  fi
}

#######################################
# MAIN SYNC LOOP
#######################################

run_sync_loop() {
  log "Starting Grafana hierarchy sync (OPTIMIZED MODE)"
  
  setup_grafana_datasource
  
  while true; do
    START_TIME=$(date +%s)
    
    DEPLOYED=()
    load_deployed_state
    validate_deployed_cache
    
    FOLDER_CACHE=()
    FOLDER_PENDING=()

    fetch_all_folders

    log "Fetching metrics from Prometheus..."
    RESPONSE=$(curl -s -G "$PROM_URL/api/v1/series" \
      --data-urlencode 'match[]={zos_smf_id!=""}' \
      --data-urlencode "start=$(date -u -d "$CHECK_INTERVAL seconds ago" +%s)" \
      --data-urlencode "end=$(date -u +%s)")

    declare -A ROOT_FOLDER
    declare -A SYSPLEX_FOLDERS
    declare -A SYSTEM_FOLDERS
    declare -A SUBSYS_FOLDERS
    
    log "Processing metrics and building hierarchy..."
    
    DASHBOARD_JOBS=()
    ROOT_FOLDER["zos-metrics"]="zos-metrics"
    
    while IFS='|' read -r SYSPLEX SYSTEM_OR_LPAR SUBSYS SERVICE_NAME; do
      [[ -z "$SYSPLEX" || -z "$SYSTEM_OR_LPAR" || -z "$SUBSYS" || -z "$SERVICE_NAME" ]] && continue
      
      KEY="$SYSPLEX|$SYSTEM_OR_LPAR|$SUBSYS|$SERVICE_NAME"
      if [[ -n "${DEPLOYED[$KEY]:-}" ]]; then
        continue
      fi
      DEPLOYED[$KEY]=1

      ROOT_PATH="zos-metrics"
      SYSPLEX_PATH="${ROOT_PATH}::${SYSPLEX}"
      SYSPLEX_TITLE="zos-metrics/${SYSPLEX}"
      SYSTEM_LPAR_PATH="${SYSPLEX_PATH}::${SYSTEM_OR_LPAR}"
      SYSTEM_LPAR_TITLE="zos-metrics/${SYSPLEX}/${SYSTEM_OR_LPAR}"
      SUBSYS_PATH="${SYSTEM_LPAR_PATH}::${SUBSYS}"
      SUBSYS_TITLE="zos-metrics/${SYSPLEX}/${SYSTEM_OR_LPAR}/${SUBSYS}"

      SYSPLEX_FOLDERS["$SYSPLEX_PATH"]="$SYSPLEX_TITLE|$ROOT_PATH"
      SYSTEM_FOLDERS["$SYSTEM_LPAR_PATH"]="$SYSTEM_LPAR_TITLE|$SYSPLEX_PATH"
      SUBSYS_FOLDERS["$SUBSYS_PATH"]="$SUBSYS_TITLE|$SYSTEM_LPAR_PATH"
      
      DASHBOARD_JOBS+=("$SUBSYS_PATH|$SUBSYS|$SERVICE_NAME")

    done < <(echo "$RESPONSE" | jq -r '
      .data[]? |
      select(.zos_sysplex and .zos_sysplex != "null" and .zos_sysplex != "") |
      select(.service_namespace and .service_namespace != "null" and .service_namespace != "") |
      select(.service_name and .service_name != "null" and .service_name != "") |
      select(.zos_smf_id and .zos_smf_id != "null" and .zos_smf_id != "") |
      {
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

    if [[ ${#DASHBOARD_JOBS[@]} -eq 0 ]]; then
      NEW_DASHBOARDS=0
    else
      NEW_DASHBOARDS=${#DASHBOARD_JOBS[@]}
    fi
    
    TOTAL_DEPLOYED=${#DEPLOYED[@]}
    PREVIOUSLY_DEPLOYED=$((TOTAL_DEPLOYED - NEW_DASHBOARDS))
    
    log "Found ${NEW_DASHBOARDS} new dashboards to deploy (${PREVIOUSLY_DEPLOYED} already deployed, ${TOTAL_DEPLOYED} total)"
    
    if [[ $NEW_DASHBOARDS -eq 0 ]]; then
      log "No new dashboards to deploy, skipping..."
      END_TIME=$(date +%s)
      ELAPSED=$((END_TIME - START_TIME))
      log "✓ Sync complete in ${ELAPSED}s. No changes needed."
      log "Sleeping ${CHECK_INTERVAL}s..."
      sleep "$CHECK_INTERVAL"
      continue
    fi

    log "Creating root folder (zos-metrics)..."
    ROOT_UID=$(get_or_create_folder_fast "zos-metrics" "" "zos-metrics")
    
    log "Creating SYSPLEX folders..."
    for path in "${!SYSPLEX_FOLDERS[@]}"; do
      IFS='|' read -r title parent_path <<< "${SYSPLEX_FOLDERS[$path]}"
      get_or_create_folder_fast "$title" "$ROOT_UID" "$path" > /dev/null &
      wait_for_jobs $MAX_PARALLEL
    done
    wait

    log "Creating SYSTEM/LPAR folders..."
    for path in "${!SYSTEM_FOLDERS[@]}"; do
      IFS='|' read -r title parent_path <<< "${SYSTEM_FOLDERS[$path]}"
      parent_uid=$(hash12 "$parent_path")
      get_or_create_folder_fast "$title" "$parent_uid" "$path" > /dev/null &
      wait_for_jobs $MAX_PARALLEL
    done
    wait

    log "Creating SUBSYSTEM folders..."
    for path in "${!SUBSYS_FOLDERS[@]}"; do
      IFS='|' read -r title parent_path <<< "${SUBSYS_FOLDERS[$path]}"
      parent_uid=$(hash12 "$parent_path")
      get_or_create_folder_fast "$title" "$parent_uid" "$path" > /dev/null &
      wait_for_jobs $MAX_PARALLEL
    done
    wait

    log "Deploying ${#DASHBOARD_JOBS[@]} dashboards in parallel..."
    for job in "${DASHBOARD_JOBS[@]}"; do
      IFS='|' read -r SUBSYS_PATH SUBSYS SERVICE_NAME <<< "$job"
      
      FOLDER_UID=$(hash12 "$SUBSYS_PATH")
      deploy_dashboard_batch "$FOLDER_UID" "$SUBSYS" "$SERVICE_NAME"
      
      wait_for_jobs $MAX_PARALLEL
    done

    log "Waiting for dashboard deployment to complete..."
    wait

    save_deployed_state

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    
    log "✓ Sync complete in ${ELAPSED}s. Deployed ${NEW_DASHBOARDS} new dashboards (${#DEPLOYED[@]} total tracked)."
    log "Sleeping ${CHECK_INTERVAL}s..."
    sleep "$CHECK_INTERVAL"
  done
}

#######################################
# MODE MANAGEMENT
#######################################

update_dynamic_mode() {
  local new_mode="$1"
  if [[ -f "$CONFIG_FILE" ]]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s/^DYNAMIC_MODE=.*/DYNAMIC_MODE=$new_mode/" "$CONFIG_FILE"
    else
      sed -i "s/^DYNAMIC_MODE=.*/DYNAMIC_MODE=$new_mode/" "$CONFIG_FILE"
    fi
    log "Updated DYNAMIC_MODE=$new_mode in config.env"
  fi
}

delete_static_dashboards() {
  log "Deleting static dashboards from Grafana..."
  
  local dashboard_names=("cics-metrics" "db2-metrics" "ims-metrics" "mq-metrics" "cics-msgusr-logs" "internal-logs" "syslog-logs")
  
  for dash_name in "${dashboard_names[@]}"; do
    local dash_uid=$(curl -s -H "Authorization: Bearer $API_KEY" \
      "$GRAFANA_URL/api/search?query=$dash_name" | \
      jq -r ".[] | select(.title == \"$dash_name\") | .uid" | head -1)
    
    if [[ -n "$dash_uid" && "$dash_uid" != "null" ]]; then
      curl -s -X DELETE -H "Authorization: Bearer $API_KEY" \
        "$GRAFANA_URL/api/dashboards/uid/$dash_uid" > /dev/null
      log "  ✓ Deleted static dashboard: $dash_name"
    fi
  done
}

delete_dynamic_dashboards() {
  log "Deleting dynamic dashboards from Grafana..."
  
  # Test Grafana connectivity first
  local health_status=$(curl -s -o /dev/null -w "%{http_code}" "$GRAFANA_URL/api/health" 2>/dev/null)
  if [[ "$health_status" != "200" ]]; then
    log "  ⚠ WARNING: Cannot connect to Grafana at $GRAFANA_URL (HTTP $health_status)"
    log "  ⚠ Dynamic dashboards may still exist in Grafana"
    log "  ⚠ Please verify Grafana URL and manually delete the '$ROOT_FOLDER_NAME' folder if needed"
    return 1
  fi
  
  # Test API key
  local auth_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/user" 2>/dev/null)
  if [[ "$auth_status" != "200" ]]; then
    log "  ⚠ WARNING: Grafana API key is invalid or expired (HTTP $auth_status)"
    log "  ⚠ Cannot delete dynamic dashboards automatically"
    log "  ⚠ Please update GRAFANA_API_KEY in config.env and manually delete the '$ROOT_FOLDER_NAME' folder"
    return 1
  fi
  
  local root_folder_uid=$(curl -s -H "Authorization: Bearer $API_KEY" \
    "$GRAFANA_URL/api/folders" 2>/dev/null | \
    jq -r ".[] | select(.title == \"$ROOT_FOLDER_NAME\") | .uid" 2>/dev/null | head -1)
  
  if [[ -n "$root_folder_uid" && "$root_folder_uid" != "null" ]]; then
    local delete_response=$(curl -s -w "\n%{http_code}" -X DELETE \
      -H "Authorization: Bearer $API_KEY" \
      "$GRAFANA_URL/api/folders/$root_folder_uid?forceDeleteRules=true" 2>/dev/null)
    local delete_status=$(echo "$delete_response" | tail -n1)
    
    if [[ "$delete_status" == "200" ]]; then
      log "  ✓ Deleted dynamic dashboard folder: $ROOT_FOLDER_NAME"
    else
      log "  ⚠ WARNING: Failed to delete folder '$ROOT_FOLDER_NAME' (HTTP $delete_status)"
      log "  ⚠ You may need to manually delete it from Grafana UI"
    fi
  else
    log "  ℹ No dynamic dashboard folder found (already deleted or never created)"
  fi
  
  rm -f "$STATE_FILE"
  log "  ✓ Cleaned up state file"
  return 0
}

#######################################
# COMMAND HANDLERS
#######################################

cmd_start() {
  load_config
  validate_config
  validate_runtime_dependencies
  apply_config
  validate_paths
  validate_connectivity
  
  if [[ -f "$PID_FILE" ]] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    log "ERROR: Dynamic mode is already running (PID: $(cat "$PID_FILE"))"
    exit 1
  fi
  
  log "Starting dynamic dashboard mode..."
  
  delete_static_dashboards
  update_dynamic_mode "true"
  
  nohup "$0" _run_sync > "${SCRIPT_DIR}/auto-sync.log" 2>&1 &
  echo $! > "$PID_FILE"
  
  log "✓ Dynamic mode started (PID: $(cat "$PID_FILE"))"
  log "  Log file: ${SCRIPT_DIR}/auto-sync.log"
  log "  Use './auto-sync.sh status' to check status"
  log "  Use './auto-sync.sh stop' to switch back to static mode"
}

cmd_stop() {
  load_config
  apply_config
  
  log "Stopping dynamic dashboard mode..."
  
  if [[ -f "$PID_FILE" ]]; then
    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      log "  ✓ Stopped background process (PID: $pid)"
    fi
    rm -f "$PID_FILE"
  else
    log "  ⚠ No running process found"
  fi
  
  delete_dynamic_dashboards
  update_dynamic_mode "false"
  
  log "✓ Switched back to static dashboard mode"
  log "  Static dashboards will be re-provisioned automatically"
  log "  If they don't appear, restart Grafana: docker-compose restart grafana"
}

cmd_status() {
  load_config
  
  echo "========================================="
  echo "Grafana Dashboard Mode Status"
  echo "========================================="
  echo "Current Mode: ${DYNAMIC_MODE:-false}"
  echo ""
  
  if [[ -f "$PID_FILE" ]]; then
    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Dynamic Sync Process: Running (PID: $pid)"
      echo "Log File: ${SCRIPT_DIR}/auto-sync.log"
      
      if [[ -f "$STATE_FILE" ]]; then
        local count=$(wc -l < "$STATE_FILE" 2>/dev/null || echo "0")
        echo "Deployed Dashboards: $count"
      fi
    else
      echo "Dynamic Sync Process: Not running (stale PID file)"
    fi
  else
    echo "Dynamic Sync Process: Not running"
  fi
  
  echo "========================================="
}

cmd_run_sync() {
  load_config
  validate_config
  validate_runtime_dependencies
  apply_config
  validate_paths
  run_sync_loop
}

#######################################
# MAIN
#######################################

main() {
  local command="${1:-}"
  
  case "$command" in
    start)
      cmd_start
      ;;
    stop)
      cmd_stop
      ;;
    status)
      cmd_status
      ;;
    _run_sync)
      cmd_run_sync
      ;;
    *)
      echo "Usage: $0 {start|stop|status}"
      echo ""
      echo "Commands:"
      echo "  start   - Switch to dynamic dashboard mode"
      echo "  stop    - Switch back to static dashboard mode"
      echo "  status  - Show current mode and process status"
      echo ""
      echo "Examples:"
      echo "  $0 start    # Enable dynamic dashboards"
      echo "  $0 stop     # Disable dynamic dashboards"
      echo "  $0 status   # Check current status"
      exit 1
      ;;
  esac
}

main "$@"

# Made with Bob

#!/usr/bin/env bash
#
# VPS Bandwidth Carry-Over Manager
# Refactored for modern practices and parallel processing.
#
# Original Author: LivingGOD
# Refactored by: Jules

set -euo pipefail

# Resolve script directory for default report file path.
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_SOURCE=$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || echo "$SCRIPT_SOURCE")
fi
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# --- Configuration & Constants ---
CONFIG_FILE="${CONFIG_FILE:-/etc/vps_manager.conf}"
CRON_TAG="# vps-bandwidth-reset-cron"
# DIAG_DIR default to /root, can be overridden
DIAG_DIR="${DIAG_DIR:-/root}"
LOG_FILE="${DIAG_DIR}/reset_band.log"
CHANGE_LOG="${DIAG_DIR}/reset_band_changes.log"
TEMP_DIR="/tmp/vps_manager_$(date +%s)_$$"
REPORT_FILE="${REPORT_FILE:-${SCRIPT_DIR}/vps_report.txt}"

# Default configuration values
DEFAULT_JOBS=5
CURL_INSECURE="${CURL_INSECURE:-0}"
LOG_API_RESPONSES="${LOG_API_RESPONSES:-1}"
LOG_API_MAX_CHARS="${LOG_API_MAX_CHARS:-2000}"

# --- Dependencies Check ---
check_dependencies() {
    local deps=(whiptail curl jq)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: Command '$dep' is not installed." >&2
            exit 1
        fi
    done
}

# --- Cleanup ---
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# --- Logging ---
# Main process logs to stderr so it doesn't interfere with captured stdout (e.g. JSON fetching)
log_info() {
    echo "$(date '+%F %T') [INFO]  $*" >&2
}
log_error() {
    echo "$(date '+%F %T') [ERROR] $*" >&2
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

mask_api_url() {
    local url="$1"
    echo "$url" | sed -E 's/(adminapikey=)[^&]*/\1REDACTED/g; s/(adminapipass=)[^&]*/\1REDACTED/g'
}

log_payload() {
    local label="$1"
    local payload="${2:-}"
    local max="${LOG_API_MAX_CHARS:-2000}"
    local len=${#payload}

    if (( len == 0 )); then
        log_info "$label (empty)"
        return 0
    fi

    if (( len > max )); then
        log_info "$label (truncated, ${len} chars)"
        payload="${payload:0:max}"
    else
        log_info "$label (${len} chars)"
    fi

    while IFS= read -r line; do
        echo "$(date '+%F %T') [INFO]  $line" >&2
    done <<< "$payload"
}

curl_insecure_flag() {
    if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
        printf '%s' "--insecure"
    fi
    return 0
}

# --- Config Management ---
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    source "$CONFIG_FILE"
    PARALLEL_JOBS="${PARALLEL_JOBS:-$DEFAULT_JOBS}"
    if [[ "${CURL_INSECURE:-0}" != "1" ]]; then
        CURL_INSECURE=0
    fi
    if [[ "${LOG_API_RESPONSES:-1}" != "1" ]]; then
        LOG_API_RESPONSES=0
    fi
    if [[ -z "${REPORT_FILE:-}" ]]; then
        REPORT_FILE="${SCRIPT_DIR}/vps_report.txt"
    fi
    LOG_API_MAX_CHARS="${LOG_API_MAX_CHARS:-2000}"
    export CURL_INSECURE LOG_API_RESPONSES LOG_API_MAX_CHARS REPORT_FILE
    return 0
}

create_default_config() {
    if [[ -f "$CONFIG_FILE" ]]; then return; fi
    cat > "$CONFIG_FILE" <<EOF
HOST=""
KEY=""
PASS=""
# Optional: full API base URL override
API_BASE=""
# Number of parallel processes for resetting
PARALLEL_JOBS=5
# Optional: set to 1 to disable TLS cert verification (not recommended)
CURL_INSECURE=0
# Optional: set to 1 to log API responses (can be verbose)
LOG_API_RESPONSES=1
# Optional: path to report file for manual reset
REPORT_FILE=""
EOF
}

configure_script_ui() {
    local current_host="${HOST:-}"
    local current_key="${KEY:-}"
    local current_pass="${PASS:-}"
    local current_jobs="${PARALLEL_JOBS:-$DEFAULT_JOBS}"
    local current_insecure="${CURL_INSECURE:-0}"
    local current_log_api="${LOG_API_RESPONSES:-1}"
    local current_report_file="${REPORT_FILE:-${SCRIPT_DIR}/vps_report.txt}"

    local new_host new_key new_pass new_jobs new_insecure new_log_api new_report_file
    new_host=$(whiptail --title "Configure Host" --inputbox "Virtualizor Host IP:" 8 78 "$current_host" 3>&1 1>&2 2>&3) || return 0
    new_key=$(whiptail --title "Configure API Key" --inputbox "API Key:" 8 78 "$current_key" 3>&1 1>&2 2>&3) || return 0
    new_pass=$(whiptail --title "Configure API Pass" --inputbox "API Password:" 8 78 "$current_pass" 3>&1 1>&2 2>&3) || return 0
    new_jobs=$(whiptail --title "Parallel Jobs" --inputbox "Number of parallel jobs:" 8 78 "$current_jobs" 3>&1 1>&2 2>&3) || return 0
    new_insecure=$(whiptail --title "TLS Verification" --inputbox "Disable TLS verification? (0 or 1):" 8 78 "$current_insecure" 3>&1 1>&2 2>&3) || return 0
    new_log_api=$(whiptail --title "API Logging" --inputbox "Log API responses? (0 or 1):" 8 78 "$current_log_api" 3>&1 1>&2 2>&3) || return 0
    new_report_file=$(whiptail --title "Report File" --inputbox "Path to vps_report.txt (blank = default):" 8 78 "$current_report_file" 3>&1 1>&2 2>&3) || return 0

    cat > "$CONFIG_FILE" <<EOF
HOST="$new_host"
KEY="$new_key"
PASS="$new_pass"
API_BASE=""
PARALLEL_JOBS=$new_jobs
CURL_INSECURE=$new_insecure
LOG_API_RESPONSES=$new_log_api
REPORT_FILE="$new_report_file"
EOF
    whiptail --msgbox "Configuration saved to $CONFIG_FILE" 8 78
}

# --- API Helpers ---
get_api_base() {
    local host_clean="${HOST#http://}"
    host_clean="${host_clean#https://}"
    host_clean="${host_clean%%/}"

    if [[ -n "${API_BASE:-}" ]]; then
        echo "$API_BASE"
    elif [[ "$host_clean" == *:* ]]; then
        echo "https://${host_clean}/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
    else
        echo "https://${host_clean}:4085/index.php?adminapikey=${KEY}&adminapipass=${PASS}"
    fi
}

api_request() {
    local url="$1"
    local post_data="${2:-}"
    local method="GET"
    local safe_url
    safe_url=$(mask_api_url "$url")

    if [[ -n "$post_data" ]]; then
        method="POST"
        log_info "API $method $safe_url"
        if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
            log_info "API POST data: $post_data"
        fi
    else
        log_info "API $method $safe_url"
    fi

    local curl_out curl_status
    set +e
    if [[ -n "$post_data" ]]; then
        curl_out=$(curl -sS -L --max-redirs 5 --retry 3 $(curl_insecure_flag) -d "$post_data" "$url" 2>&1)
    else
        curl_out=$(curl -sS -L --max-redirs 5 --retry 3 $(curl_insecure_flag) "$url" 2>&1)
    fi
    curl_status=$?
    set -e

    if (( curl_status == 60 )) && [[ "${CURL_INSECURE:-0}" != "1" ]]; then
        log_error "SSL verification failed; retrying with --insecure."
        set +e
        if [[ -n "$post_data" ]]; then
            curl_out=$(curl -sS -L --max-redirs 5 --retry 3 --insecure -d "$post_data" "$url" 2>&1)
        else
            curl_out=$(curl -sS -L --max-redirs 5 --retry 3 --insecure "$url" 2>&1)
        fi
        curl_status=$?
        set -e
        if (( curl_status == 0 )); then
            CURL_INSECURE=1
            export CURL_INSECURE
            log_info "TLS verification disabled for this run (CURL_INSECURE=1)."
        fi
    fi

    if (( curl_status != 0 )); then
        log_error "API $method failed (curl exit $curl_status)."
        log_payload "API error response for $safe_url" "$curl_out"
        return $curl_status
    fi

    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        log_payload "API response for $safe_url" "$curl_out"
    fi

    printf '%s' "$curl_out"
}

build_report_map() {
    local report_file="$1"
    local map_file="$2"
    local map_dir

    if [[ ! -f "$report_file" ]]; then
        log_error "Report file not found: $report_file"
        return 1
    fi

    map_dir="$(dirname "$map_file")"
    mkdir -p "$map_dir"
    : > "$map_file"
    local line ips_part remaining_raw
    local count=0

    while IFS= read -r line; do
        [[ "$line" == *"|"* ]] || continue
        [[ "$line" == *"- "* ]] || continue

        local after_dash="${line#*- }"
        ips_part="${after_dash%%|*}"
        ips_part="$(trim "$ips_part")"
        [[ -z "$ips_part" ]] && continue

        local last_field="${line##*|}"
        remaining_raw="${last_field#*:}"
        remaining_raw="${remaining_raw%%GB*}"
        remaining_raw="$(trim "$remaining_raw")"
        [[ -z "$remaining_raw" ]] && continue

        local ip
        local ip_list
        IFS=',' read -ra ip_list <<< "$ips_part"
        for ip in "${ip_list[@]}"; do
            ip="$(trim "$ip")"
            [[ -z "$ip" ]] && continue
            printf "%s|%s\n" "$ip" "$remaining_raw" >> "$map_file"
            ((count++))
        done
    done < "$report_file"

    if (( count == 0 )); then
        log_error "No report entries found in $report_file"
        return 1
    fi

    log_info "Report map loaded: $count IP entries from $report_file"
    return 0
}

# --- VPS Data Fetching ---
fetch_vps_data() {
    local api_base="$1"
    # Try fetching all at once
    local res
    res=$(api_request "${api_base}&act=vs&api=json&reslen=0")

    if [[ -z "$res" ]]; then
        log_error "API returned empty response"
        return 1
    fi

    # Check validity
    if ! echo "$res" | jq -e '.vs' >/dev/null 2>&1; then
        # Could be server list or error
        log_error "API response missing 'vs' field"
        return 1
    fi

    # Check count. If small, might need paging (Virtualizor default 50)
    local count
    count=$(echo "$res" | jq -r '.vs | length')

    if (( count <= 50 )); then
        log_info "Small result set ($count), attempting pagination to ensure all VPS are retrieved..."
        # Paging strategy: Try 0-based and 1-based, merge everything.
        local pages_dir="${TEMP_DIR}/pages"
        mkdir -p "$pages_dir"

        # We will fetch until we get an empty page.
        # We start at 0, go up to reasonable limit or empty
        local page=0
        local empty_streak=0

        while (( empty_streak < 2 )); do
             local p_url="${api_base}&act=vs&api=json&reslen=50&page=${page}"
             local p_file="${pages_dir}/page_${page}.json"
             api_request "$p_url" > "$p_file"

             local p_len
             p_len=$(jq -r '.vs | length' "$p_file" 2>/dev/null || echo 0)

             if (( p_len == 0 )); then
                 rm "$p_file"
                 ((empty_streak++))
             else
                 empty_streak=0
             fi
             ((page++))
             # Safety break
             if (( page > 1000 )); then break; fi
        done

        # Merge all pages
        if ls "${pages_dir}"/*.json >/dev/null 2>&1; then
            # Merge logic: array to object if needed
            jq -s 'map(.vs | if type=="array" then (map( if has("vpsid") then { ( (.vpsid|tostring) ): . } else {} end ) | add) else . end) | add | {vs: .}' "${pages_dir}"/*.json
            return 0
        fi
    fi

    # Return initial result if no paging needed or paging failed to find more
    echo "$res"
}

# --- Worker Logic ---
process_vps_worker() {
    local vpsid="$1"
    local limit_raw="$2"
    local used_raw="$3"
    local plid="$4"
    local api_base="$5"
    local change_log_file="$6"
    local curl_insecure=""

    wlog_info() {
        echo "$(date '+%F %T') [INFO]  $*" >&2
    }
    wlog_error() {
        echo "$(date '+%F %T') [ERROR] $*" >&2
    }
    wlog_payload() {
        local label="$1"
        local payload="${2:-}"
        local max="${LOG_API_MAX_CHARS:-2000}"
        local len=${#payload}

        if (( len == 0 )); then
            wlog_info "$label (empty)"
            return 0
        fi

        if (( len > max )); then
            wlog_info "$label (truncated, ${len} chars)"
            payload="${payload:0:max}"
        else
            wlog_info "$label (${len} chars)"
        fi

        while IFS= read -r line; do
            wlog_info "$line"
        done <<< "$payload"
    }
    wlog_mask_url() {
        echo "$1" | sed -E 's/(adminapikey=)[^&]*/\1REDACTED/g; s/(adminapipass=)[^&]*/\1REDACTED/g'
    }
    wcurl() {
        local url="$1"
        shift
        local out status

        set +e
        out=$(curl -sS $curl_insecure "$@" "$url" 2>&1)
        status=$?
        set -e

        if (( status == 60 )) && [[ "$curl_insecure" != "--insecure" ]]; then
            wlog_error "SSL verification failed; retrying with --insecure."
            set +e
            out=$(curl -sS --insecure "$@" "$url" 2>&1)
            status=$?
            set -e
            if (( status == 0 )); then
                curl_insecure="--insecure"
                wlog_info "TLS verification disabled for this worker."
            fi
        fi

        printf '%s' "$out"
        return $status
    }
    normalize_bw_int() {
        local raw="$1"
        local label="$2"
        local val

        if [[ -z "$raw" || "$raw" == "null" ]]; then
            raw="0"
        fi

        if [[ ! "$raw" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            wlog_error "$label value '$raw' is not numeric; defaulting to 0"
            echo 0
            return 0
        fi

        val=$(awk -v v="$raw" 'BEGIN{iv=int(v); if (v<0 && v!=iv) iv=iv-1; printf "%d", iv}')
        if [[ "$raw" == *.* && "$raw" != "$val" ]]; then
            wlog_info "$label normalized: $raw -> $val (truncated decimals)"
        fi

        echo "$val"
    }

    if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
        curl_insecure="--insecure"
    fi

    wlog_info "─ VPS $vpsid"
    local limit used
    limit=$(normalize_bw_int "$limit_raw" "limit")
    used=$(normalize_bw_int "$used_raw" "used")

    # Logic
    if (( limit == 0 )); then
        wlog_info "$vpsid → unlimited plan. Resetting usage only."
        local res curl_status
        set +e
        local reset_url="${api_base}&act=vs&bwreset=${vpsid}&api=json"
        wlog_info "$vpsid → reset request: $(wlog_mask_url "$reset_url")"
        res=$(wcurl "$reset_url" -X POST)
        curl_status=$?
        set -e
        if (( curl_status != 0 )); then
            wlog_error "$vpsid → reset failed (curl exit $curl_status)"
            wlog_payload "$vpsid → reset error response" "$res"
            return 1
        fi
        if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
            wlog_payload "$vpsid → reset response" "$res"
        fi
        if echo "$res" | jq -e '.done // 0' | grep -q 1; then
            wlog_info "$vpsid → usage reset OK"
        else
            wlog_error "$vpsid → reset failed: $res"
            return 1
        fi
        return 0
    fi

    if (( limit > 0 )) && (( used > limit )); then
        wlog_info "$vpsid : used ($used) > limit ($limit) — skipping"
        local date_str
        date_str=$(date '+%F %T')
        printf "%s  VPS %s  SKIPPED used=%d limit=%d (plan %d)\n" "$date_str" "$vpsid" "$used" "$limit" "$plid" >> "$change_log_file"
        return 0
    fi

    local new_limit
    if (( limit < 0 )); then
        new_limit=$(( limit + used ))
    else
        new_limit=$(( limit - used ))
    fi

    wlog_info "$vpsid : ${used}/${limit} GB → 0/${new_limit} GB"

    # Reset
    local res curl_status
    set +e
    local reset_url="${api_base}&act=vs&bwreset=${vpsid}&api=json"
    wlog_info "$vpsid → reset request: $(wlog_mask_url "$reset_url")"
    res=$(wcurl "$reset_url" -X POST)
    curl_status=$?
    set -e
    if (( curl_status != 0 )); then
        wlog_error "$vpsid → reset failed (curl exit $curl_status)"
        wlog_payload "$vpsid → reset error response" "$res"
        return 1
    fi
    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        wlog_payload "$vpsid → reset response" "$res"
    fi
    if ! echo "$res" | jq -e '.done // 0' | grep -q 1; then
        wlog_error "$vpsid → reset failed: $res"
        return 1
    fi

    # Update
    local u_res
    set +e
    local update_url="${api_base}&act=managevps&vpsid=${vpsid}&api=json"
    local update_payload="editvps=1 bandwidth=$new_limit plid=$plid"
    wlog_info "$vpsid → update request: $(wlog_mask_url "$update_url") payload: $update_payload"
    u_res=$(wcurl "$update_url" -d "editvps=1" -d "bandwidth=$new_limit" -d "plid=${plid}")
    curl_status=$?
    set -e
    if (( curl_status != 0 )); then
        wlog_error "$vpsid → update failed (curl exit $curl_status)"
        wlog_payload "$vpsid → update error response" "$u_res"
        return 1
    fi
    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        wlog_payload "$vpsid → update response" "$u_res"
    fi

    if echo "$u_res" | jq -e '.done.done // false' | grep -q true; then
        wlog_info "Limit updated (plan $plid preserved)"
        local date_str
        date_str=$(date '+%F %T')
        printf "%s  VPS %s  %d/%d => 0/%d (plan %d)\n" "$date_str" "$vpsid" "$used" "$limit" "$new_limit" "$plid" >> "$change_log_file"
    else
        wlog_error "$vpsid → update failed: $u_res"
        return 1
    fi
}

process_vps_worker_report() {
    local vpsid="$1"
    local limit_raw="$2"
    local plid="$3"
    local iplist="$4"
    local api_base="$5"
    local report_map_file="$6"
    local change_log_file="$7"
    local curl_insecure=""

    wlog_info() {
        echo "$(date '+%F %T') [INFO]  $*" >&2
    }
    wlog_error() {
        echo "$(date '+%F %T') [ERROR] $*" >&2
    }
    wlog_payload() {
        local label="$1"
        local payload="${2:-}"
        local max="${LOG_API_MAX_CHARS:-2000}"
        local len=${#payload}

        if (( len == 0 )); then
            wlog_info "$label (empty)"
            return 0
        fi

        if (( len > max )); then
            wlog_info "$label (truncated, ${len} chars)"
            payload="${payload:0:max}"
        else
            wlog_info "$label (${len} chars)"
        fi

        while IFS= read -r line; do
            wlog_info "$line"
        done <<< "$payload"
    }
    wlog_mask_url() {
        echo "$1" | sed -E 's/(adminapikey=)[^&]*/\1REDACTED/g; s/(adminapipass=)[^&]*/\1REDACTED/g'
    }
    wtrim() {
        local s="$1"
        s="${s#"${s%%[![:space:]]*}"}"
        s="${s%"${s##*[![:space:]]}"}"
        echo "$s"
    }
    wcurl() {
        local url="$1"
        shift
        local out status

        set +e
        out=$(curl -sS $curl_insecure "$@" "$url" 2>&1)
        status=$?
        set -e

        if (( status == 60 )) && [[ "$curl_insecure" != "--insecure" ]]; then
            wlog_error "SSL verification failed; retrying with --insecure."
            set +e
            out=$(curl -sS --insecure "$@" "$url" 2>&1)
            status=$?
            set -e
            if (( status == 0 )); then
                curl_insecure="--insecure"
                wlog_info "TLS verification disabled for this worker."
            fi
        fi

        printf '%s' "$out"
        return $status
    }
    normalize_int() {
        local raw="$1"
        local label="$2"
        local val

        if [[ -z "$raw" || "$raw" == "null" ]]; then
            raw="0"
        fi

        if [[ ! "$raw" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            wlog_error "$label value '$raw' is not numeric; defaulting to 0"
            echo 0
            return 0
        fi

        val=$(awk -v v="$raw" 'BEGIN{iv=int(v); if (v<0 && v!=iv) iv=iv-1; printf "%d", iv}')
        if [[ "$raw" == *.* && "$raw" != "$val" ]]; then
            wlog_info "$label normalized: $raw -> $val (truncated decimals)"
        fi

        echo "$val"
    }
    normalize_remaining() {
        local raw="$1"
        local val lt1

        raw="$(wtrim "$raw")"
        if [[ "$raw" == "نامحدود" ]]; then
            echo "unlimited"
            return 0
        fi
        if [[ ! "$raw" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
            wlog_error "remaining value '$raw' is not numeric"
            return 1
        fi

        read -r val lt1 < <(awk -v v="$raw" 'BEGIN{iv=int(v); if (v<0 && v!=iv) iv=iv-1; lt1=(v>0 && v<1)?1:0; printf "%d %d", iv, lt1}')
        if [[ "$raw" == *.* && "$raw" != "$val" ]]; then
            wlog_info "remaining normalized: $raw -> $val (truncated decimals)"
        fi
        if (( lt1 == 1 )); then
            wlog_info "remaining < 1 GB; using 1 GB to avoid unlimited"
            val=1
        fi
        if (( val <= 0 )); then
            wlog_info "remaining <= 0 GB; using 1 GB to avoid unlimited"
            val=1
        fi
        echo "$val"
    }
    lookup_report_remaining() {
        local ips="$1"
        local map_file="$2"
        local ip rem

        IFS=',' read -ra ip_list <<< "$ips"
        for ip in "${ip_list[@]}"; do
            ip="$(wtrim "$ip")"
            [[ -z "$ip" ]] && continue
            rem=$(awk -F'|' -v ip="$ip" '$1==ip {print $2; exit}' "$map_file")
            if [[ -n "$rem" ]]; then
                echo "${ip}|${rem}"
                return 0
            fi
        done
        return 1
    }

    if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
        curl_insecure="--insecure"
    fi

    wlog_info "─ VPS $vpsid"
    if [[ ! -f "$report_map_file" ]]; then
        wlog_error "Report map missing: $report_map_file"
        return 1
    fi
    if [[ -z "$iplist" ]]; then
        wlog_error "No IPs found for VPS $vpsid"
        return 1
    fi

    local limit
    limit=$(normalize_int "$limit_raw" "limit")

    local match_ip=""
    local remaining_raw=""
    local match
    if match=$(lookup_report_remaining "$iplist" "$report_map_file"); then
        match_ip="${match%%|*}"
        remaining_raw="${match#*|}"
        wlog_info "$vpsid → report match: $match_ip remaining=$remaining_raw"
    else
        if (( limit == 0 )); then
            wlog_info "$vpsid → no report entry for IPs ($iplist); continuing with reset only"
        else
            wlog_error "$vpsid → no report entry for IPs ($iplist)"
            return 1
        fi
    fi

    if (( limit == 0 )); then
        wlog_info "$vpsid → unlimited plan (limit=0). Resetting usage only."
        local res curl_status
        set +e
        local reset_url="${api_base}&act=vs&bwreset=${vpsid}&api=json"
        wlog_info "$vpsid → reset request: $(wlog_mask_url "$reset_url")"
        res=$(wcurl "$reset_url" -X POST)
        curl_status=$?
        set -e
        if (( curl_status != 0 )); then
            wlog_error "$vpsid → reset failed (curl exit $curl_status)"
            wlog_payload "$vpsid → reset error response" "$res"
            return 1
        fi
        if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
            wlog_payload "$vpsid → reset response" "$res"
        fi
        if echo "$res" | jq -e '.done // 0' | grep -q 1; then
            wlog_info "$vpsid → usage reset OK"
        else
            wlog_error "$vpsid → reset failed: $res"
            return 1
        fi
        return 0
    fi

    if [[ -z "$remaining_raw" || "$remaining_raw" == "نامحدود" ]]; then
        wlog_error "$vpsid → report remaining is unlimited or missing; refusing to set limit"
        return 1
    fi

    local remaining
    remaining=$(normalize_remaining "$remaining_raw") || return 1
    wlog_info "$vpsid → setting limit to remaining: $remaining GB"

    # Reset
    local res curl_status
    set +e
    local reset_url="${api_base}&act=vs&bwreset=${vpsid}&api=json"
    wlog_info "$vpsid → reset request: $(wlog_mask_url "$reset_url")"
    res=$(wcurl "$reset_url" -X POST)
    curl_status=$?
    set -e
    if (( curl_status != 0 )); then
        wlog_error "$vpsid → reset failed (curl exit $curl_status)"
        wlog_payload "$vpsid → reset error response" "$res"
        return 1
    fi
    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        wlog_payload "$vpsid → reset response" "$res"
    fi
    if ! echo "$res" | jq -e '.done // 0' | grep -q 1; then
        wlog_error "$vpsid → reset failed: $res"
        return 1
    fi

    # Update
    local u_res
    set +e
    local update_url="${api_base}&act=managevps&vpsid=${vpsid}&api=json"
    local update_payload="editvps=1 bandwidth=$remaining plid=$plid"
    wlog_info "$vpsid → update request: $(wlog_mask_url "$update_url") payload: $update_payload"
    u_res=$(wcurl "$update_url" -d "editvps=1" -d "bandwidth=$remaining" -d "plid=${plid}")
    curl_status=$?
    set -e
    if (( curl_status != 0 )); then
        wlog_error "$vpsid → update failed (curl exit $curl_status)"
        wlog_payload "$vpsid → update error response" "$u_res"
        return 1
    fi
    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        wlog_payload "$vpsid → update response" "$u_res"
    fi

    if echo "$u_res" | jq -e '.done.done // false' | grep -q true; then
        wlog_info "Limit updated (plan $plid preserved)"
        local date_str
        date_str=$(date '+%F %T')
        printf "%s  VPS %s  => 0/%d (plan %d)\n" "$date_str" "$vpsid" "$remaining" "$plid" >> "$change_log_file"
    else
        wlog_error "$vpsid → update failed: $u_res"
        return 1
    fi
}
export -f process_vps_worker process_vps_worker_report

worker_wrapper() {
    # Unpack line: "101 1000 500 1"
    read -r vpsid limit used plid <<< "$1"
    local logs_dir="${LOGS_DIR:-}"
    local change_logs_dir="${CHANGE_LOGS_DIR:-}"

    if [[ -z "$vpsid" ]]; then
        echo "$(date '+%F %T') [ERROR] Invalid worklist line: '$1'"
        return 1
    fi
    if [[ -z "$logs_dir" || -z "$change_logs_dir" ]]; then
        echo "$(date '+%F %T') [ERROR] LOGS_DIR/CHANGE_LOGS_DIR not set."
        return 1
    fi

    local log_file="${logs_dir}/${vpsid}.log"
    local change_log_file="${change_logs_dir}/${vpsid}.log"

    {
        echo "$(date '+%F %T') [INFO]  Worker start: vpsid=$vpsid limit=$limit used=$used plid=$plid"
        set +e
        process_vps_worker "$vpsid" "$limit" "$used" "$plid" "$API_BASE_VAL" "$change_log_file"
        local status=$?
        set -e
        if (( status != 0 )); then
            echo "$(date '+%F %T') [ERROR] WORKER_EXIT=$status"
        else
            echo "$(date '+%F %T') [INFO]  WORKER_EXIT=0"
        fi
        exit $status
    } > "$log_file" 2>&1
}
export -f worker_wrapper

report_worker_wrapper() {
    # Unpack line: "101 1000 1 89.235.118.201"
    read -r vpsid limit plid iplist <<< "$1"
    local logs_dir="${LOGS_DIR:-}"
    local change_logs_dir="${CHANGE_LOGS_DIR:-}"

    if [[ -z "$vpsid" ]]; then
        echo "$(date '+%F %T') [ERROR] Invalid worklist line: '$1'"
        return 1
    fi
    if [[ -z "$logs_dir" || -z "$change_logs_dir" ]]; then
        echo "$(date '+%F %T') [ERROR] LOGS_DIR/CHANGE_LOGS_DIR not set."
        return 1
    fi

    local log_file="${logs_dir}/${vpsid}.log"
    local change_log_file="${change_logs_dir}/${vpsid}.log"

    {
        echo "$(date '+%F %T') [INFO]  Worker start: vpsid=$vpsid limit=$limit plid=$plid ips=$iplist"
        echo "$(date '+%F %T') [INFO]  Panel IPs: $iplist"
        set +e
        process_vps_worker_report "$vpsid" "$limit" "$plid" "$iplist" "$API_BASE_VAL" "$REPORT_MAP_FILE" "$change_log_file"
        local status=$?
        set -e
        if (( status != 0 )); then
            echo "$(date '+%F %T') [ERROR] WORKER_EXIT=$status"
        else
            echo "$(date '+%F %T') [INFO]  WORKER_EXIT=0"
        fi
        exit $status
    } > "$log_file" 2>&1
}
export -f report_worker_wrapper

# --- Main Reset Orchestrator ---
run_reset() {
    local target="$1" # "all" or vpsid
    local api_base
    api_base=$(get_api_base)

    log_info "API base: $(mask_api_url "$api_base")"
    if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
        log_info "TLS verification disabled (CURL_INSECURE=1)."
    fi
    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        log_info "API response logging enabled."
    fi

    log_info "Fetching VPS data..."
    local vs_json
    vs_json=$(fetch_vps_data "$api_base") || return 1

    mkdir -p "$TEMP_DIR"
    local worklist="${TEMP_DIR}/worklist.txt"

    if [[ "$target" == "all" ]]; then
        echo "$vs_json" | jq -r '.vs[] | "\(.vpsid) \(.bandwidth//0) \(.used_bandwidth//0) \(.plid//0)"' > "$worklist"
    else
        echo "$vs_json" | jq -r --arg id "$target" '.vs[$id] | "\(.vpsid) \(.bandwidth//0) \(.used_bandwidth//0) \(.plid//0)"' > "$worklist"
        if grep -q "null" "$worklist" || [[ ! -s "$worklist" ]]; then
             # Try finding in suspended/unsuspended lists if not found (Diagnostic feature from original)
             # For brevity, in this clean impl, we will trust the full fetch (which does paging).
             # If fetch_vps_data works correctly, it gets everything.
             log_error "VPS $target not found in list."
             return 1
        fi
    fi

    local count
    count=$(wc -l < "$worklist")
    if (( count == 0 )); then
        log_info "No VPS to process."
        return 0
    fi

    log_info "Processing $count VPS(s) with $PARALLEL_JOBS jobs..."

    # Setup log dirs
    export LOGS_DIR="${TEMP_DIR}/logs"
    export CHANGE_LOGS_DIR="${TEMP_DIR}/changelogs"
    export API_BASE_VAL="$api_base"
    mkdir -p "$LOGS_DIR" "$CHANGE_LOGS_DIR"

    # Execute
    # We strip trailing empty lines to avoid issues with read
    local xargs_status=0
    local xargs_err="${TEMP_DIR}/xargs.err"
    : > "$xargs_err"
    set +e
    grep -v '^$' "$worklist" | xargs -P "$PARALLEL_JOBS" -I {} bash -c 'worker_wrapper "$1"' _ "{}" 2> "$xargs_err"
    xargs_status=$?
    set -e
    if (( xargs_status != 0 )); then
        log_error "One or more VPS operations failed (xargs exit $xargs_status)."
    fi
    if [[ -s "$xargs_err" ]]; then
        log_payload "xargs stderr" "$(cat "$xargs_err")"
    fi

    local success_count=0
    local skipped_count=0
    local failed_count=0
    local vps_log
    if compgen -G "$LOGS_DIR/*.log" > /dev/null; then
        for vps_log in "$LOGS_DIR"/*.log; do
            if [[ ! -s "$vps_log" ]]; then
                ((failed_count++))
                continue
            fi

            local worker_exit
            worker_exit=$(awk -F= '/WORKER_EXIT=/ {print $2; exit}' "$vps_log")
            if [[ -z "$worker_exit" ]]; then
                ((failed_count++))
                continue
            fi

            if (( worker_exit != 0 )); then
                ((failed_count++))
            elif grep -q "SKIPPED" "$vps_log" || grep -q "skipping" "$vps_log"; then
                ((skipped_count++))
            else
                ((success_count++))
            fi
        done
    else
        log_error "No per-VPS logs were generated."
        failed_count=$count
    fi

    # Aggregate logs
    log_info "Aggregating logs..."
    if ls "$LOGS_DIR"/*.log >/dev/null 2>&1; then
        cat "$LOGS_DIR"/*.log >> "$LOG_FILE"
    fi
    if ls "$CHANGE_LOGS_DIR"/*.log >/dev/null 2>&1; then
        cat "$CHANGE_LOGS_DIR"/*.log >> "$CHANGE_LOG"
    fi

    log_info "Summary: total=$count success=$success_count skipped=$skipped_count failed=$failed_count"
    if (( failed_count > 0 )); then
        log_error "Run completed with failures. Check $LOG_FILE for details."
    elif (( xargs_status != 0 )); then
        log_error "xargs reported a failure, but no failed workers were detected."
    fi

    log_info "Done."
    if (( failed_count > 0 )) || (( xargs_status != 0 )); then
        return 1
    fi
    return 0
}

run_manual_reset_report() {
    local target="$1" # "all" or vpsid
    local api_base
    api_base=$(get_api_base)

    log_info "API base: $(mask_api_url "$api_base")"
    log_info "Manual reset using report file: $REPORT_FILE"
    if [[ "${LOG_API_RESPONSES:-1}" == "1" ]]; then
        log_info "API response logging enabled."
    fi

    mkdir -p "$TEMP_DIR"
    local report_map="${TEMP_DIR}/report_map.txt"
    if ! build_report_map "$REPORT_FILE" "$report_map"; then
        return 1
    fi

    log_info "Fetching VPS data..."
    local vs_json
    vs_json=$(fetch_vps_data "$api_base") || return 1

    mkdir -p "$TEMP_DIR"
    local worklist="${TEMP_DIR}/worklist.txt"
    local jq_iplist='def ip_re: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$";
        def clean_ips(a):
        a | map(tostring) | map(gsub("\\s+";"")) | map(select(test(ip_re)));
        def ips_from_ip:
        clean_ips([.ip]);
        def ips_from_ips:
        if (.ips // empty | type) == "object" then
            clean_ips( [(.ips | keys[]?)] + [(.ips | .. | strings)] )
        else
            clean_ips( [(.ips // empty | .. | strings)] )
        end;
        def iplist: (ips_from_ip + ips_from_ips) | unique | join(",");'

    if [[ "$target" == "all" ]]; then
        echo "$vs_json" | jq -r "${jq_iplist} .vs[] | \"\\(.vpsid) \\(.bandwidth//0) \\(.plid//0) \\(iplist)\"" > "$worklist"
    else
        echo "$vs_json" | jq -r --arg id "$target" "${jq_iplist} .vs[\$id] | \"\\(.vpsid) \\(.bandwidth//0) \\(.plid//0) \\(iplist)\"" > "$worklist"
        if grep -q "null" "$worklist" || [[ ! -s "$worklist" ]]; then
             log_error "VPS $target not found in list."
             return 1
        fi
        log_payload "VPS $target IP fields" "$(echo "$vs_json" | jq -c --arg id "$target" '.vs[$id] | with_entries(select(.key|test("ip")) )')"
    fi

    local count
    count=$(wc -l < "$worklist")
    if (( count == 0 )); then
        log_info "No VPS to process."
        return 0
    fi

    log_info "Processing $count VPS(s) with $PARALLEL_JOBS jobs..."

    # Setup log dirs
    export LOGS_DIR="${TEMP_DIR}/logs"
    export CHANGE_LOGS_DIR="${TEMP_DIR}/changelogs"
    export API_BASE_VAL="$api_base"
    export REPORT_MAP_FILE="$report_map"
    mkdir -p "$LOGS_DIR" "$CHANGE_LOGS_DIR"

    # Execute
    # We strip trailing empty lines to avoid issues with read
    local xargs_status=0
    local xargs_err="${TEMP_DIR}/xargs.err"
    : > "$xargs_err"
    set +e
    grep -v '^$' "$worklist" | xargs -P "$PARALLEL_JOBS" -I {} bash -c 'report_worker_wrapper "$1"' _ "{}" 2> "$xargs_err"
    xargs_status=$?
    set -e
    if (( xargs_status != 0 )); then
        log_error "One or more VPS operations failed (xargs exit $xargs_status)."
    fi
    if [[ -s "$xargs_err" ]]; then
        log_payload "xargs stderr" "$(cat "$xargs_err")"
    fi

    local success_count=0
    local skipped_count=0
    local failed_count=0
    local vps_log
    if compgen -G "$LOGS_DIR/*.log" > /dev/null; then
        for vps_log in "$LOGS_DIR"/*.log; do
            if [[ ! -s "$vps_log" ]]; then
                ((failed_count++))
                continue
            fi

            local worker_exit
            worker_exit=$(awk -F= '/WORKER_EXIT=/ {print $2; exit}' "$vps_log")
            if [[ -z "$worker_exit" ]]; then
                ((failed_count++))
                continue
            fi

            if (( worker_exit != 0 )); then
                ((failed_count++))
            elif grep -q "SKIPPED" "$vps_log" || grep -q "skipping" "$vps_log"; then
                ((skipped_count++))
            else
                ((success_count++))
            fi
        done
    else
        log_error "No per-VPS logs were generated."
        failed_count=$count
    fi

    # Aggregate logs
    log_info "Aggregating logs..."
    if ls "$LOGS_DIR"/*.log >/dev/null 2>&1; then
        cat "$LOGS_DIR"/*.log >> "$LOG_FILE"
    fi
    if ls "$CHANGE_LOGS_DIR"/*.log >/dev/null 2>&1; then
        cat "$CHANGE_LOGS_DIR"/*.log >> "$CHANGE_LOG"
    fi

    log_info "Summary: total=$count success=$success_count skipped=$skipped_count failed=$failed_count"
    if (( failed_count > 0 )); then
        log_error "Run completed with failures. Check $LOG_FILE for details."
    elif (( xargs_status != 0 )); then
        log_error "xargs reported a failure, but no failed workers were detected."
    fi

    log_info "Done."
    if (( failed_count > 0 )) || (( xargs_status != 0 )); then
        return 1
    fi
    return 0
}

run_manual_reset() {
    local target="$1"
    local label="$2"

    log_info "Manual reset started: $label"
    if run_manual_reset_report "$target"; then
        log_info "Manual reset completed: $label"
        return 0
    fi

    log_error "Manual reset failed: $label"
    return 1
}

whiptail_supports_programbox() {
    local help_out
    help_out=$(whiptail --help 2>&1 || true)
    if echo "$help_out" | grep -q -- '--programbox'; then
        return 0
    fi
    return 1
}

run_manual_reset_ui() {
    local target="$1"
    local label="$2"

    if whiptail_supports_programbox; then
        {
            run_manual_reset "$target" "$label" && echo "Success" || echo "Failed"
        } 2>&1 | tee -a "$LOG_FILE" | whiptail --programbox "Running..." 20 78 || true
        return 0
    fi

    log_info "whiptail lacks --programbox; falling back to console output."
    {
        run_manual_reset "$target" "$label" && echo "Success" || echo "Failed"
    } 2>&1 | tee -a "$LOG_FILE" || true
    whiptail --msgbox "Done. See $LOG_FILE for details." 8 78
    return 0
}

# --- Menus ---
menu_manual() {
    local choice
    choice=$(whiptail --title "Manual Reset" --menu "Select Option" 15 60 2 \
        "1" "Reset ALL VPSs" \
        "2" "Reset Specific VPS" 3>&1 1>&2 2>&3) || return

    case "$choice" in
        1)
            if whiptail --yesno "Reset ALL VPS bandwidth?" 8 78; then
                > "$LOG_FILE"
                run_manual_reset_ui "all" "all VPSs"
            fi
            ;;
        2)
            local vid
            vid=$(whiptail --inputbox "Enter VPS ID:" 8 78 3>&1 1>&2 2>&3) || return
            if [[ -n "$vid" ]]; then
                > "$LOG_FILE"
                run_manual_reset_ui "$vid" "VPS $vid"
            fi
            ;;
    esac
}

menu_automation() {
    local script_path
    script_path=$(realpath "$0")
    local choice
    choice=$(whiptail --title "Automation" --menu "Manage Cron" 18 78 5 \
        "1" "Enable Daily (00:00)" \
        "2" "Enable Monthly (1st, 02:00)" \
        "3" "Enable Last Day (23:30)" \
        "4" "Disable All" \
        "5" "Edit Crontab" 3>&1 1>&2 2>&3) || return

    local cron_cmd="/usr/bin/bash $script_path --cron"
    local current_cron
    current_cron=$(crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true)

    case "$choice" in
        1)
            printf "%s\n0 0 * * * %s %s\n" "$current_cron" "$cron_cmd" "$CRON_TAG" | crontab -
            whiptail --msgbox "Daily cron enabled." 8 78
            ;;
        2)
            printf "%s\n0 2 1 * * %s %s\n" "$current_cron" "$cron_cmd" "$CRON_TAG" | crontab -
            whiptail --msgbox "Monthly cron enabled." 8 78
            ;;
        3)
            local ld_cmd="30 23 * * * [ \"\$(date +\\%d -d tomorrow)\" == \"01\" ] && $cron_cmd $CRON_TAG"
            printf "%s\n%s\n" "$current_cron" "$ld_cmd" | crontab -
            whiptail --msgbox "Last day cron enabled." 8 78
            ;;
        4)
            echo "$current_cron" | crontab -
            whiptail --msgbox "Automation disabled." 8 78
            ;;
        5)
            EDITOR=nano crontab -e
            ;;
    esac
}

# --- Entry Point ---

# Check dependencies first (except if just checking version/help?)
check_dependencies

if [[ "${1:-}" == "--cron" ]]; then
    if ! load_config; then
        log_error "Config not found at $CONFIG_FILE"
        exit 1
    fi
    # Redirect stdout/stderr to logfile in cron mode
    exec >> "$LOG_FILE" 2>&1
    run_reset "all"
    exit 0
fi

# Diagnostic / CLI modes
if [[ "${1:-}" == "--list-vps" ]]; then
    if ! load_config; then echo "Config missing."; exit 1; fi
    api_base=$(get_api_base)
    echo "Fetching VPS list..."
    res=$(fetch_vps_data "$api_base")
    echo "$res" | jq -r '.vs[] | "VPS \(.vpsid): \(.vps_name) (\(.hostname))"'
    exit 0
fi

# Interactive Mode
if ! load_config; then
    create_default_config
    whiptail --msgbox "Created default config at $CONFIG_FILE. Please configure." 8 78
fi

while true; do
    choice=$(whiptail --title "VPS Manager" --menu "Main Menu" 15 60 4 \
        "1" "Configure" \
        "2" "Manual Reset" \
        "3" "Automation" \
        "4" "Exit" 3>&1 1>&2 2>&3) || exit 0

    case "$choice" in
        1) configure_script_ui; load_config ;;
        2) menu_manual ;;
        3) menu_automation ;;
        4) exit 0 ;;
    esac
done

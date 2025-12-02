#!/bin/bash

# --- Configuration ---
# Path to the Wallpaper Engine workshop content folder
WALLPAPER_DIR="~/.steam/steam/steamapps/workshop/content/431960"
# Temporary directory for unpacking
TMP_DIR="/tmp/hyprpaper-we"

# Configuration file for multi-monitor settings
CONFIG_FILE="$HOME/.config/hyprpaper-we/config"
# Directory to store PID files (one per monitor)
PID_DIR="/tmp/hyprpaper-we-pids"
# Lock file to prevent race conditions
LOCK_FILE="/tmp/hyprpaper-we.lock"

# Create PID directory if it doesn't exist
mkdir -p "$PID_DIR"

# --- Functions ---

# Function to get all connected monitors
get_monitors() {
    hyprctl monitors -j | jq -r '.[].name'
}

# Function to write PID with lock protection (now monitor-specific)
write_pid() {
    local monitor=$1
    local pid=$2
    local pid_file="$PID_DIR/$monitor.pid"
    (
        flock -x 200
        echo $pid > "$pid_file"
        echo "New PID for $monitor: $pid"
        # Verify PID file was created and readable
        if [ -f "$pid_file" ] && [ -r "$pid_file" ]; then
            echo "PID file created successfully at $pid_file"
            echo "Stored PID: $(cat "$pid_file")"
        else
            echo "Warning: Failed to create or read PID file"
        fi
    ) 200>"$LOCK_FILE"
}

# Function to read PID with lock protection (now monitor-specific)
read_pid() {
    local monitor=$1
    local pid_file="$PID_DIR/$monitor.pid"
    local pid=""
    if [ -f "$pid_file" ]; then
        (
            flock -s 200
            pid=$(cat "$pid_file" 2>/dev/null)
        ) 200>"$LOCK_FILE"
    fi
    echo "$pid"
}

# Function to stop wallpaper on a specific monitor
stop_wallpaper_monitor() {
    local monitor=$1
    local killed=false
    local pid_file="$PID_DIR/$monitor.pid"
    
    echo "[DEBUG] Checking PID file for $monitor: $pid_file"
    
    # Try to use PID file first with lock protection
    if [ -f "$pid_file" ]; then
        local pid_to_kill=$(read_pid "$monitor")
        
        if [ -z "$pid_to_kill" ]; then
            echo "[DEBUG] PID file exists but is empty for $monitor"
            rm -f "$pid_file"
        else
            echo "[DEBUG] Found PID in file for $monitor: $pid_to_kill"
            
            # More robust process check
            if kill -0 $pid_to_kill 2>/dev/null; then
                echo "Stopping wallpaper process for $monitor with PID: $pid_to_kill"
                # Use SIGTERM first, then SIGKILL if needed
                kill $pid_to_kill
                sleep 0.5
                if kill -0 $pid_to_kill 2>/dev/null; then
                    echo "Process still running, sending SIGKILL..."
                    kill -9 $pid_to_kill
                fi
                rm -f "$pid_file"
                killed=true
            else
                echo "Process with PID $pid_to_kill not found. Removing stale PID file."
                rm -f "$pid_file"
            fi
        fi
    else
        echo "[DEBUG] PID file not found for $monitor"
    fi
    
    # If PID file method failed, try to find processes by name
    if [ "$killed" = false ]; then
        echo "PID file not found or invalid for $monitor. Searching for wallpaper processes..."
        
        # Find and kill mpvpaper processes for this monitor
        local mpv_pids=$(pgrep -f "mpvpaper.*$monitor")
        if [ -n "$mpv_pids" ]; then
            echo "Found mpvpaper processes for $monitor: $mpv_pids"
            for pid in $mpv_pids; do
                echo "Killing mpvpaper process: $pid"
                kill $pid
                sleep 0.2
                if kill -0 $pid 2>/dev/null; then
                    kill -9 $pid
                fi
                killed=true
            done
        fi
        
        # Find and kill web_viewer processes for this monitor
        local web_pids=$(pgrep -f "web_viewer.py.*$monitor")
        if [ -n "$web_pids" ]; then
            echo "Found web_viewer processes for $monitor: $web_pids"
            for pid in $web_pids; do
                echo "Killing web_viewer process: $pid"
                kill $pid
                sleep 0.2
                if kill -0 $pid 2>/dev/null; then
                    kill -9 $pid
                fi
                killed=true
            done
        fi
        
        if [ "$killed" = false ]; then
            echo "No active wallpaper processes found for $monitor."
        fi
    fi
}

# Function to stop all wallpapers on all monitors
stop_wallpaper() {
    echo "Stopping wallpapers on all monitors..."
    
    # Stop all monitors that have PID files
    if [ -d "$PID_DIR" ]; then
        for pid_file in "$PID_DIR"/*.pid; do
            if [ -f "$pid_file" ]; then
                local monitor=$(basename "$pid_file" .pid)
                echo "Stopping wallpaper on $monitor"
                stop_wallpaper_monitor "$monitor"
            fi
        done
    fi
    
    # Also try to kill any remaining processes by name
    local mpv_pids=$(pgrep -f "mpvpaper")
    if [ -n "$mpv_pids" ]; then
        echo "Found remaining mpvpaper processes: $mpv_pids"
        for pid in $mpv_pids; do
            kill $pid 2>/dev/null
            sleep 0.2
            kill -9 $pid 2>/dev/null
        done
    fi
    
    local web_pids=$(pgrep -f "web_viewer.py")
    if [ -n "$web_pids" ]; then
        echo "Found remaining web_viewer processes: $web_pids"
        for pid in $web_pids; do
            kill $pid 2>/dev/null
            sleep 0.2
            kill -9 $pid 2>/dev/null
        done
    fi
    
    # Clean up
    rm -f "$PID_DIR"/*.pid
    rm -f "$LOCK_FILE"
    
    echo "All wallpapers stopped."
}

# Function to set a wallpaper on a specific monitor
set_wallpaper_on_monitor() {
    local wallpaper_id=$1
    local monitor=$2
    local wallpaper_path="$(eval echo $WALLPAPER_DIR)/$wallpaper_id"
    local pkg_file=""
    
    # Stop wallpaper on this specific monitor first
    stop_wallpaper_monitor "$monitor"

    local project_json_path="$wallpaper_path/project.json"
    if [ ! -f "$project_json_path" ]; then
        echo "Error: project.json not found in $wallpaper_path"
        return 1
    fi

    # Get basic info from project.json
    local type=$(jq -r '.type | ascii_downcase' "$project_json_path")
    local file=$(jq -r '.file' "$project_json_path")
    echo "Detected wallpaper type: $type, main file: $file"

    # --- Logic to determine content source ---
    local content_root=""
    local properties_source_json=""

    # Check if the files are unpacked
    if [ -f "$wallpaper_path/$file" ]; then
        echo "Found unpacked wallpaper."
        content_root="$wallpaper_path"
        properties_source_json="$project_json_path" # Use the external project.json
    else
        # If not, look for a .pkg file to unpack
        echo "Wallpaper is packed. Searching for .pkg file..."
        local pkg_file=""
        if [ -f "$wallpaper_path/project.pkg" ]; then
            pkg_file="$wallpaper_path/project.pkg"
        elif [ -f "$wallpaper_path/preview.pkg" ]; then
            pkg_file="$wallpaper_path/preview.pkg"
        else
            echo "Error: .pkg file not found and main file '$file' is missing."
            return 1
        fi
        
        echo "Found PKG file: $pkg_file"
        content_root="$TMP_DIR/$wallpaper_id"
        properties_source_json="$content_root/project.json" # Use the internal project.json
        
        python "$(dirname "$0")/unpacker.py" "$pkg_file" "$content_root"
        if [ ! -f "$properties_source_json" ]; then
            echo "Error: Could not unpack or find the internal project.json"
            return 1
        fi
    fi
    # --- End of content source logic ---

    # --- Start the player based on type ---
    if [ "$type" == "video" ]; then
        local video_path="$content_root/$file"
        if [ -f "$video_path" ]; then
            echo "Launching mpvpaper for $video_path on $monitor"
            mpvpaper -o "--loop-file=inf --no-audio" "$monitor" "$video_path" &
            LAST_PID=$!
            write_pid "$monitor" $LAST_PID
        else
            echo "Error: Video file not found at $video_path"
        fi

    elif [ "$type" == "web" ]; then
        local html_path="$content_root/$file"
        if [ -f "$html_path" ]; then
            echo "Launching web_viewer for $html_path on $monitor"
            # Launch the player in the background. Hyprland rules will handle the rest.
            LD_PRELOAD=/usr/lib/libgtk4-layer-shell.so python "$(dirname "$0")/web_viewer.py" "$html_path" "$monitor" &
            LAST_PID=$!
            write_pid "$monitor" $LAST_PID
        else
            echo "Error: HTML file not found at $html_path"
        fi

    elif [ "$type" == "scene" ]; then
        echo "Error: 'scene' type wallpapers are not supported yet."
        return 1
    else
        echo "Unsupported wallpaper type: $type"
        return 1
    fi
}

# Function to load configuration
load_config() {
    local mode="clone"  # Default mode
    local monitor_wallpapers=""
    
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    echo "$mode"
}

# Function to save configuration
save_config() {
    local mode=$1
    shift
    local monitors_config="$@"
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << EOF
# HyprPaper-WE Configuration
# Mode can be: clone, per-monitor, stretch
mode="$mode"

# For per-monitor mode, define wallpapers for each monitor
# Format: MONITOR_NAME=WALLPAPER_ID
$monitors_config
EOF
}

# Function to set wallpaper in clone mode (same wallpaper on all monitors)
set_wallpaper_clone() {
    local wallpaper_id=$1
    local monitors=$(get_monitors)
    
    echo "Setting wallpaper $wallpaper_id in CLONE mode on all monitors"
    
    for monitor in $monitors; do
        echo "Setting wallpaper on $monitor"
        set_wallpaper_on_monitor "$wallpaper_id" "$monitor"
    done
    
    save_config "clone" "wallpaper_id=\"$wallpaper_id\""
}

# Function to set wallpaper in per-monitor mode
set_wallpaper_per_monitor() {
    shift  # Remove the 'per-monitor' argument
    local monitors=$(get_monitors)
    local config_lines=""
    
    echo "Setting wallpapers in PER-MONITOR mode"
    
    # Parse monitor:wallpaper pairs
    for arg in "$@"; do
        if [[ "$arg" == *":"* ]]; then
            local monitor="${arg%%:*}"
            local wallpaper_id="${arg##*:}"
            echo "Setting wallpaper $wallpaper_id on $monitor"
            set_wallpaper_on_monitor "$wallpaper_id" "$monitor"
            config_lines="$config_lines\nmonitor_$monitor=\"$wallpaper_id\""
        fi
    done
    
    save_config "per-monitor" "$config_lines"
}

# Function to set wallpaper in stretch mode (single wallpaper across all monitors)
set_wallpaper_stretch() {
    local wallpaper_id=$1
    local monitors=$(get_monitors)
    local monitor_array=($monitors)
    local num_monitors=${#monitor_array[@]}
    
    echo "Setting wallpaper $wallpaper_id in STRETCH mode across $num_monitors monitors"
    
    if [ $num_monitors -eq 0 ]; then
        echo "Error: No monitors detected"
        return 1
    fi
    
    # Get monitor geometries
    local monitor_info=$(hyprctl monitors -j | jq -r '.[] | "\(.name)|\(.x)|\(.y)|\(.width)|\(.height)"')
    
    # For stretch mode, we'll use the first monitor as primary
    # Note: This is a simplified implementation - true stretch would require
    # custom handling per wallpaper type
    local primary_monitor="${monitor_array[0]}"
    echo "Using $primary_monitor as primary display for stretched wallpaper"
    
    set_wallpaper_on_monitor "$wallpaper_id" "$primary_monitor"
    
    save_config "stretch" "wallpaper_id=\"$wallpaper_id\"\nprimary_monitor=\"$primary_monitor\""
    
    echo "Note: Stretch mode currently displays on primary monitor only."
    echo "Full multi-monitor stretch requires wallpaper-specific implementation."
}

# --- Main Logic ---

# Argument Handling
case "$1" in
    stop)
        stop_wallpaper
        exit 0
        ;;
    clone)
        if [ -z "$2" ]; then
            echo "Error: Wallpaper ID required for clone mode"
            echo "Usage: ./hyprpaper-we.sh clone <WALLPAPER_ID>"
            exit 1
        fi
        if ! command -v jq &> /dev/null || ! command -v python &> /dev/null; then
            echo "Error: jq and/or python are not installed. Please install them."
            exit 1
        fi
        set_wallpaper_clone "$2"
        ;;
    per-monitor)
        if [ -z "$2" ]; then
            echo "Error: Monitor:Wallpaper pairs required for per-monitor mode"
            echo "Usage: ./hyprpaper-we.sh per-monitor MONITOR1:ID1 MONITOR2:ID2 ..."
            echo "Example: ./hyprpaper-we.sh per-monitor DP-1:123456 DP-2:789012"
            exit 1
        fi
        if ! command -v jq &> /dev/null || ! command -v python &> /dev/null; then
            echo "Error: jq and/or python are not installed. Please install them."
            exit 1
        fi
        set_wallpaper_per_monitor "$@"
        ;;
    stretch)
        if [ -z "$2" ]; then
            echo "Error: Wallpaper ID required for stretch mode"
            echo "Usage: ./hyprpaper-we.sh stretch <WALLPAPER_ID>"
            exit 1
        fi
        if ! command -v jq &> /dev/null || ! command -v python &> /dev/null; then
            echo "Error: jq and/or python are not installed. Please install them."
            exit 1
        fi
        set_wallpaper_stretch "$2"
        ;;
    list-monitors)
        echo "Available monitors:"
        get_monitors
        exit 0
        ;;
    ""|--help|-h)
        echo "HyprPaper-WE - Multi-Monitor Wallpaper Manager"
        echo ""
        echo "Usage:"
        echo "  ./hyprpaper-we.sh clone <WALLPAPER_ID>"
        echo "      Set the same wallpaper on all monitors"
        echo ""
        echo "  ./hyprpaper-we.sh per-monitor MONITOR1:ID1 MONITOR2:ID2 ..."
        echo "      Set different wallpapers for each monitor"
        echo "      Example: ./hyprpaper-we.sh per-monitor DP-1:123456 DP-2:789012"
        echo ""
        echo "  ./hyprpaper-we.sh stretch <WALLPAPER_ID>"
        echo "      Stretch a single wallpaper across all monitors"
        echo ""
        echo "  ./hyprpaper-we.sh list-monitors"
        echo "      Show available monitors"
        echo ""
        echo "  ./hyprpaper-we.sh stop"
        echo "      Stop all wallpapers"
        echo ""
        echo "  ./hyprpaper-we.sh <WALLPAPER_ID>"
        echo "      Legacy mode: set wallpaper on all monitors (same as 'clone')"
        exit 0
        ;;
    *)
        # Legacy mode: treat single ID as clone mode
        if ! command -v jq &> /dev/null || ! command -v python &> /dev/null; then
            echo "Error: jq and/or python are not installed. Please install them."
            exit 1
        fi
        echo "Using legacy mode (clone). Consider using 'clone' explicitly."
        set_wallpaper_clone "$1"
        ;;
esac

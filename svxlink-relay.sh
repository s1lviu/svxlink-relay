#!/bin/bash

# SVXLink Reflector Relay
# Relays TCP control and UDP audio packets between client and reflector server

# Configuration
LISTEN_PORT=5300           # Port to listen on (change if needed)
TARGET_HOST=""             # Target reflector server IP/hostname (MUST BE SET)
TARGET_PORT=5300           # Target reflector server port
LOG_FILE="/var/log/svxlink-relay.log"
PID_FILE="/var/run/svxlink-relay.pid"

# Function to log with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to cleanup on exit
cleanup() {
    log_message "Shutting down SVXLink relay..."
    
    # Kill socat processes
    if [[ -n "$TCP_PID" ]]; then
        kill "$TCP_PID" 2>/dev/null
        wait "$TCP_PID" 2>/dev/null
    fi
    
    if [[ -n "$UDP_PID" ]]; then
        kill "$UDP_PID" 2>/dev/null
        wait "$UDP_PID" 2>/dev/null
    fi
    
    # Remove PID file
    rm -f "$PID_FILE"
    
    log_message "SVXLink relay stopped"
    exit 0
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -t, --target HOST      Target reflector server IP/hostname (required)"
    echo "  -p, --port PORT        Listen port (default: 5300)"
    echo "  -r, --remote-port PORT Target server port (default: 5300)"
    echo "  -l, --log-file FILE    Log file path (default: /var/log/svxlink-relay.log)"
    echo "  -d, --daemon           Run as daemon"
    echo "  -h, --help             Show this help"
    echo ""
    echo "Example:"
    echo "  $0 --target 192.168.1.100 --port 5300"
    exit 1
}

# Parse command line arguments
DAEMON_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--target)
            TARGET_HOST="$2"
            shift 2
            ;;
        -p|--port)
            LISTEN_PORT="$2"
            shift 2
            ;;
        -r|--remote-port)
            TARGET_PORT="$2"
            shift 2
            ;;
        -l|--log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        -d|--daemon)
            DAEMON_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if target host is provided
if [[ -z "$TARGET_HOST" ]]; then
    echo "Error: Target host must be specified with -t or --target"
    usage
fi

# Check if socat is installed
if ! command -v socat &> /dev/null; then
    echo "Error: socat is not installed. Please install it first:"
    echo "  Ubuntu/Debian: sudo apt install socat"
    echo "  CentOS/RHEL:   sudo yum install socat"
    echo "  Fedora:        sudo dnf install socat"
    exit 1
fi

# Check if running as root for privileged ports
if [[ "$LISTEN_PORT" -lt 1024 ]] && [[ $EUID -ne 0 ]]; then
    echo "Error: Root privileges required for privileged ports (<1024)"
    exit 1
fi

# Create log directory if it doesn't exist
LOG_DIR=$(dirname "$LOG_FILE")
mkdir -p "$LOG_DIR"

# Set up signal handlers
trap cleanup SIGTERM SIGINT SIGQUIT

# Function to start forwarder
start_forwarder() {
    log_message "Starting SVXLink relay"
    log_message "Listen port: $LISTEN_PORT"
    log_message "Target: $TARGET_HOST:$TARGET_PORT"
    
    # Test connectivity to target server
    if ! timeout 5 bash -c "</dev/tcp/$TARGET_HOST/$TARGET_PORT" 2>/dev/null; then
        log_message "WARNING: Cannot connect to target server $TARGET_HOST:$TARGET_PORT"
        log_message "Relay will start anyway, but connections may fail"
    else
        log_message "Target server connectivity verified"
    fi
    
    # Start TCP relay
    log_message "Starting TCP relay on port $LISTEN_PORT"
    socat -d -d TCP4-LISTEN:$LISTEN_PORT,fork,reuseaddr TCP4:$TARGET_HOST:$TARGET_PORT 2>> "$LOG_FILE" &
    TCP_PID=$!
    
    # Give TCP forwarder time to start
    sleep 1
    
    # Check if TCP relay started successfully
    if ! kill -0 "$TCP_PID" 2>/dev/null; then
        log_message "ERROR: Failed to start TCP relay"
        exit 1
    fi
    
    # Start UDP relay
    log_message "Starting UDP relay on port $LISTEN_PORT"
    socat -d -d UDP4-LISTEN:$LISTEN_PORT,fork,reuseaddr UDP4:$TARGET_HOST:$TARGET_PORT 2>> "$LOG_FILE" &
    UDP_PID=$!
    
    # Give UDP forwarder time to start
    sleep 1
    
    # Check if UDP relay started successfully
    if ! kill -0 "$UDP_PID" 2>/dev/null; then
        log_message "ERROR: Failed to start UDP relay"
        kill "$TCP_PID" 2>/dev/null
        exit 1
    fi
    
    # Write PID file
    echo "$$" > "$PID_FILE"
    
    log_message "SVXLink relay started successfully"
    log_message "TCP PID: $TCP_PID, UDP PID: $UDP_PID"
    
    # Monitor child processes
    while true; do
        # Check if TCP relay process is still running
        if ! kill -0 "$TCP_PID" 2>/dev/null; then
            log_message "ERROR: TCP relay process died, restarting..."
            socat -d -d TCP4-LISTEN:$LISTEN_PORT,fork,reuseaddr TCP4:$TARGET_HOST:$TARGET_PORT 2>> "$LOG_FILE" &
            TCP_PID=$!
        fi
        
        # Check if UDP relay process is still running
        if ! kill -0 "$UDP_PID" 2>/dev/null; then
            log_message "ERROR: UDP relay process died, restarting..."
            socat -d -d UDP4-LISTEN:$LISTEN_PORT,fork,reuseaddr UDP4:$TARGET_HOST:$TARGET_PORT 2>> "$LOG_FILE" &
            UDP_PID=$!
        fi
        
        sleep 10
    done
}

# Run as daemon if requested
if [[ "$DAEMON_MODE" == "true" ]]; then
    log_message "Starting in daemon mode"
    nohup "$0" --target "$TARGET_HOST" --port "$LISTEN_PORT" --remote-port "$TARGET_PORT" --log-file "$LOG_FILE" > /dev/null 2>&1 &
    echo "SVXLink relay started as daemon (PID: $!)"
    exit 0
fi

# Start the forwarder
start_forwarder
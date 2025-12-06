#!/bin/bash
# watch-logs.sh
# Opens multiple terminal windows to watch different log streams

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔍 Starting Log Monitoring"
echo "=========================="
echo ""
echo "This script will display logs from multiple sources."
echo "Press Ctrl+C to exit."
echo ""

# Function to display logs with header
show_logs() {
    local title=$1
    local namespace=$2
    local selector_or_pod=$3
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 $title"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Check if tmux is available for better display
if command -v tmux &> /dev/null; then
    echo "Using tmux for better log viewing experience..."
    echo ""
    
    # Create a new tmux session with multiple panes
    SESSION_NAME="fluent-bit-logs"
    
    # Kill session if it exists
    tmux kill-session -t $SESSION_NAME 2>/dev/null || true
    
    # Create new session
    tmux new-session -d -s $SESSION_NAME
    
    # Split into panes
    tmux split-window -h -t $SESSION_NAME
    tmux split-window -v -t $SESSION_NAME:0.0
    tmux split-window -v -t $SESSION_NAME:0.2
    
    # Pane 0: Fluent Bit logs
    tmux send-keys -t $SESSION_NAME:0.0 'kubectl logs -f -n logging -l app=fluent-bit --tail=50' C-m
    tmux select-pane -t $SESSION_NAME:0.0 -T "Fluent Bit Logs"
    
    # Pane 1: Mock Splunk Consumer logs
    tmux send-keys -t $SESSION_NAME:0.1 'kubectl logs -f -n splunk-mock -l app=mock-splunk-consumer --tail=50' C-m
    tmux select-pane -t $SESSION_NAME:0.1 -T "Mock Splunk Consumer"
    
    # Pane 2: team-alpha logs
    tmux send-keys -t $SESSION_NAME:0.2 'kubectl logs -f test-app-alpha -n team-alpha --tail=20' C-m
    tmux select-pane -t $SESSION_NAME:0.2 -T "Team Alpha App"
    
    # Pane 3: team-beta logs
    tmux send-keys -t $SESSION_NAME:0.3 'kubectl logs -f test-app-beta -n team-beta --tail=20' C-m
    tmux select-pane -t $SESSION_NAME:0.3 -T "Team Beta App"
    
    # Attach to session
    echo "✅ Tmux session created!"
    echo ""
    echo "Layout:"
    echo "  ┌─────────────────────┬─────────────────────┐"
    echo "  │  Fluent Bit Logs    │  Mock Splunk Logs   │"
    echo "  ├─────────────────────┼─────────────────────┤"
    echo "  │  Team Alpha App     │  Team Beta App      │"
    echo "  └─────────────────────┴─────────────────────┘"
    echo ""
    echo "Commands:"
    echo "  - Switch panes: Ctrl+B then arrow keys"
    echo "  - Detach: Ctrl+B then D"
    echo "  - Reattach: tmux attach -t $SESSION_NAME"
    echo "  - Kill session: tmux kill-session -t $SESSION_NAME"
    echo ""
    
    tmux attach -t $SESSION_NAME
    
else
    echo "⚠️  tmux not found. Showing logs sequentially..."
    echo "   Install tmux for better experience: sudo apt-get install tmux"
    echo ""
    echo "Select which logs to watch:"
    echo "  1) Fluent Bit logs"
    echo "  2) Mock Splunk Consumer logs (consumer-logs)"
    echo "  3) Mock Splunk Infrastructure logs (tdp-infra)"
    echo "  4) Team Alpha application logs"
    echo "  5) Team Beta application logs"
    echo "  6) Team Gamma application logs"
    echo "  7) All namespaces pods status"
    echo ""
    read -p "Enter choice (1-7): " choice

    case $choice in
        1)
            show_logs "Fluent Bit Logs" "logging" "fluent-bit"
            kubectl logs -f -n logging -l app=fluent-bit --tail=100
            ;;
        2)
            show_logs "Mock Splunk Consumer - Received Events" "splunk-mock" "mock-splunk-consumer"
            kubectl logs -f -n splunk-mock -l app=mock-splunk-consumer --tail=100
            ;;
        3)
            show_logs "Mock Splunk Infrastructure - Received Events" "splunk-mock" "mock-splunk-infra"
            kubectl logs -f -n splunk-mock -l app=mock-splunk-infra --tail=100
            ;;
        4)
            show_logs "Team Alpha Application" "team-alpha" "test-app-alpha"
            kubectl logs -f test-app-alpha -n team-alpha --tail=50
            ;;
        5)
            show_logs "Team Beta Application" "team-beta" "test-app-beta"
            kubectl logs -f test-app-beta -n team-beta --tail=50
            ;;
        6)
            show_logs "Team Gamma Application" "team-gamma" "test-app-gamma"
            kubectl logs -f test-app-gamma -n team-gamma --tail=50
            ;;
        7)
            watch -n 2 'kubectl get pods -n logging,team-alpha,team-beta,team-gamma,splunk-mock'
            ;;
        *)
            echo "Invalid choice"
            exit 1
            ;;
    esac
fi

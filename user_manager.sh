#!/bin/bash
# User Management Script - Database Version
# Uses Flask REST API instead of text files

# Configuration
PANEL_URL="http://localhost:54321"  # Internal Flask app URL (Gunicorn)
API_TOKEN="c4db08c06f1b28356fe90edb687dca23269241662779b778f9dce5ee3150c340"  # From .env ADMIN_API_TOKEN

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

create_user() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        print_error "Usage: $0 create USERNAME EXPIRY_DAYS [EMAIL] [MAX_CONNECTIONS]"
        exit 1
    fi

    USERNAME="$1"
    DAYS="$2"
    EMAIL="${3:-}"
    MAX_CONNECTIONS="${4:-2}"

    print_info "Creating user via Flask API..."
    echo ""

    # Generate random password (API will generate if not provided, but we generate to display)
    PASSWORD=$(/usr/bin/openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)

    # Create JSON payload
    JSON_PAYLOAD=$(cat <<EOF
{
    "username": "$USERNAME",
    "password": "$PASSWORD",
    "email": "$EMAIL",
    "days": $DAYS,
    "max_connections": $MAX_CONNECTIONS,
    "notes": "Created via user_manager.sh on $(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
)

    # Make API request
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$PANEL_URL/api/users" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD")

    # Split response body and status code
    HTTP_BODY=$(echo "$RESPONSE" | head -n -1)
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

    # Check response
    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "User created successfully!"
        echo ""

        # Parse response (basic parsing, could use jq for better handling)
        TOKEN=$(echo "$HTTP_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
        M3U_URL=$(echo "$HTTP_BODY" | grep -o '"m3u_url":"[^"]*"' | cut -d'"' -f4 | sed 's/\\//g')
        STREAM_URL=$(echo "$HTTP_BODY" | grep -o '"streaming_playlist_url":"[^"]*"' | cut -d'"' -f4 | sed 's/\\//g')
        USER_ID=$(echo "$HTTP_BODY" | grep -o '"user_id":[0-9]*' | cut -d':' -f2)

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📋 USER DETAILS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_info "User ID:      $USER_ID"
        print_info "Username:     $USERNAME"
        print_info "Password:     $PASSWORD"
        print_info "Token:        $TOKEN"
        print_info "Email:        ${EMAIL:-N/A}"
        print_info "Max Streams:  $MAX_CONNECTIONS"
        print_info "Expires:      $DAYS days from now"
        echo ""

        if [ -n "$M3U_URL" ]; then
            print_success "Panel Playlist URL:"
            echo "   $M3U_URL"
        else
            print_warning "Panel playlist URL not available in response"
        fi

        if [ -n "$STREAM_URL" ]; then
            print_info "Direct streaming URL:"
            echo "   $STREAM_URL"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    else
        print_error "Failed to create user (HTTP $HTTP_CODE)"
        echo ""
        print_error "Response:"
        echo "$HTTP_BODY" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "$HTTP_BODY"
        exit 1
    fi
}

list_users() {
    print_info "Fetching users from database..."
    echo ""

    # Use Python to query database directly
    cd /opt/streamapp/IptvPannel/local_panel
    source venv/bin/activate

    python3 <<'PYTHON_SCRIPT'
import sys
sys.path.insert(0, '/opt/streamapp/IptvPannel/local_panel')

from app import app, db
from database.models import User
from datetime import datetime

with app.app_context():
    users = User.query.order_by(User.created_at.desc()).all()

    if not users:
        print("⚠️  No users found in database")
        sys.exit(0)

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"{'ID':<5} {'Username':<25} {'Email':<30} {'Status':<10} {'Expires':<12} {'Conn':<5}")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

    for user in users:
        status = "🟢 Active" if user.is_active and not user.is_expired() else ("🔴 Expired" if user.is_expired() else "⚫ Disabled")
        expires = user.expiry_date.strftime('%Y-%m-%d') if user.expiry_date else 'N/A'
        email_display = (user.email or '')[:28] + '..' if user.email and len(user.email) > 30 else (user.email or '')
        username_display = user.username[:23] + '..' if len(user.username) > 25 else user.username

        print(f"{user.id:<5} {username_display:<25} {email_display:<30} {status:<10} {expires:<12} {user.max_connections:<5}")

    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(f"\n📊 Total users: {len(users)}")
PYTHON_SCRIPT
}

show_help() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📖 IPTV User Manager - Database Edition"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Usage:"
    echo "  $0 create USERNAME DAYS [EMAIL] [MAX_CONNECTIONS]"
    echo "  $0 list"
    echo "  $0 help"
    echo ""
    echo "Examples:"
    echo "  $0 create john123 30"
    echo "  $0 create jane@email.com 60 jane@email.com 3"
    echo "  $0 list"
    echo ""
    echo "Notes:"
    echo "  - All users are stored in PostgreSQL database"
    echo "  - Automatically syncs with streaming server"
    echo "  - Default max_connections: 2"
    echo "  - Password is auto-generated if not provided"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Main script logic
case "$1" in
    create)
        create_user "$2" "$3" "$4" "$5"
        ;;
    list)
        list_users
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        print_error "Invalid command"
        show_help
        exit 1
        ;;
esac

#!/usr/bin/env python3
"""
Migration Script: Import users from users.txt to PostgreSQL database
Safely migrates text-file users to database while avoiding duplicates
"""

import os
import sys
from datetime import datetime, timedelta
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(__file__))

from app import app, db
from database.models import User

# Configuration
USERS_TXT_PATH = '/opt/streamapp/IptvPannel/local_panel/users.txt'
DEFAULT_EXPIRY_DAYS = 30  # Default expiry for users without dates


def parse_users_txt():
    """Parse users.txt file and return list of user data"""
    users_data = []

    if not os.path.exists(USERS_TXT_PATH):
        print(f"❌ File not found: {USERS_TXT_PATH}")
        return users_data

    print(f"📖 Reading users from: {USERS_TXT_PATH}\n")

    with open(USERS_TXT_PATH, 'r') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()

            # Skip empty lines
            if not line:
                print(f"   Line {line_num}: [EMPTY] - Skipped")
                continue

            # Parse pipe-delimited format: username|password|token|expiry
            parts = line.split('|')

            if len(parts) < 4:
                print(f"   Line {line_num}: [INVALID FORMAT] - Skipped")
                continue

            username = parts[0].strip()
            password = parts[1].strip()
            token = parts[2].strip()
            expiry_str = parts[3].strip() if len(parts) > 3 else ''

            # Validate required fields
            if not username or not password or not token:
                print(f"   Line {line_num}: [MISSING DATA] {username} - Skipped")
                continue

            # Parse expiry date or use default
            if expiry_str:
                try:
                    expiry_date = datetime.strptime(expiry_str, '%Y-%m-%d')
                except ValueError:
                    print(f"   Line {line_num}: Invalid date format for {username}, using default")
                    expiry_date = datetime.utcnow() + timedelta(days=DEFAULT_EXPIRY_DAYS)
            else:
                expiry_date = datetime.utcnow() + timedelta(days=DEFAULT_EXPIRY_DAYS)

            # Determine email (some usernames are emails)
            email = username if '@' in username else ''

            users_data.append({
                'line_num': line_num,
                'username': username,
                'password': password,
                'token': token,
                'expiry_date': expiry_date,
                'email': email
            })

            print(f"   Line {line_num}: ✓ {username} (expires: {expiry_date.strftime('%Y-%m-%d')})")

    return users_data


def migrate_to_database(users_data):
    """Migrate parsed users to PostgreSQL database"""

    print(f"\n📊 Migration Summary:")
    print(f"   Total users to migrate: {len(users_data)}\n")

    if not users_data:
        print("⚠️  No users to migrate!")
        return

    with app.app_context():
        stats = {
            'created': 0,
            'skipped_duplicate_username': 0,
            'skipped_duplicate_token': 0,
            'errors': 0
        }

        for user_data in users_data:
            try:
                username = user_data['username']
                token = user_data['token']

                # Check for existing username
                existing_user = User.query.filter_by(username=username).first()
                if existing_user:
                    print(f"   ⚠️  Skipped: {username} (username already exists in database)")
                    stats['skipped_duplicate_username'] += 1
                    continue

                # Check for existing token
                existing_token = User.query.filter_by(token=token).first()
                if existing_token:
                    print(f"   ⚠️  Skipped: {username} (token already exists in database)")
                    stats['skipped_duplicate_token'] += 1
                    continue

                # Create new user
                new_user = User(
                    username=username,
                    password=user_data['password'],
                    email=user_data['email'],
                    token=token,
                    expiry_date=user_data['expiry_date'],
                    is_active=True,
                    max_connections=2,  # Default value
                    notes=f"Migrated from users.txt on {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')}"
                )

                db.session.add(new_user)
                db.session.commit()

                print(f"   ✅ Created: {username} (ID: {new_user.id})")
                stats['created'] += 1

            except Exception as e:
                print(f"   ❌ Error migrating {user_data['username']}: {str(e)}")
                stats['errors'] += 1
                db.session.rollback()

        # Print final statistics
        print(f"\n{'='*60}")
        print(f"🎉 MIGRATION COMPLETED")
        print(f"{'='*60}")
        print(f"   ✅ Successfully created: {stats['created']}")
        print(f"   ⚠️  Skipped (duplicate username): {stats['skipped_duplicate_username']}")
        print(f"   ⚠️  Skipped (duplicate token): {stats['skipped_duplicate_token']}")
        print(f"   ❌ Errors: {stats['errors']}")
        print(f"{'='*60}\n")

        # Verify database state
        total_users_db = User.query.count()
        print(f"📈 Total users in database: {total_users_db}")


def main():
    """Main migration process"""
    print("\n" + "="*60)
    print("🔄 USER MIGRATION: users.txt → PostgreSQL Database")
    print("="*60 + "\n")

    # Parse users.txt
    users_data = parse_users_txt()

    if not users_data:
        print("\n⚠️  No valid users found to migrate. Exiting.")
        return

    # Ask for confirmation
    print(f"\n⚠️  About to migrate {len(users_data)} users to the database.")
    print("   Duplicate usernames/tokens will be skipped automatically.")

    response = input("\n   Continue with migration? (yes/no): ").strip().lower()

    if response not in ['yes', 'y']:
        print("\n❌ Migration cancelled by user.")
        return

    # Perform migration
    migrate_to_database(users_data)

    print("\n✅ Migration process complete!\n")


if __name__ == '__main__':
    main()

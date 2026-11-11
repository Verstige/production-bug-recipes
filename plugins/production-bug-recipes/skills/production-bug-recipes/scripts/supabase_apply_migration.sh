#!/usr/bin/env bash
#
# supabase_apply_migration.sh
#
# Aug 26 2026 — apply a Supabase migration from a sandboxed agent.
#
# Sandbox restriction: the agent can't reach Postgres directly
# (db.<ref>.supabase.co is IPv6-only and the sandbox blocks
# IPv6 outbound — see Recipe #24 in the SKILL.md).
#
# Workaround: use the Supabase CLI with --dns-resolver https. The
# CLI routes DNS lookups through Cloudflare's HTTPS endpoint so
# native DNS doesn't matter, and it opens its own HTTPS connection
# to api.supabase.com which the sandbox allows.
#
# Usage:
#   ./scripts/supabase_apply_migration.sh <path/to/migration.sql>
#
# The CLI auto-detects the linked project from the current working
# directory's supabase/ folder. Link first if needed:
#   supabase link --project-ref <ref>
#
# Prereq: supabase CLI installed and logged in (supabase projects list
# should work without auth prompts).

set -euo pipefail

MIGRATION_FILE="${1:?Usage: $0 <migration.sql path>}"

if [ ! -f "$MIGRATION_FILE" ]; then
    echo "❌ Migration file not found: $MIGRATION_FILE"
    exit 1
fi

# Verify the file matches the supabase CLI pattern (timestamp_name.sql)
FILENAME=$(basename "$MIGRATION_FILE")
if ! echo "$FILENAME" | grep -qE "^[0-9]{12}_.+\.sql$"; then
    echo "⚠ Filename must match pattern YYYYMMDDXXXX_name.sql"
    echo "  Got: $FILENAME"
    echo "  See supabase CLI requirements"
    exit 1
fi

# Dry-run first to surface duplicate-version conflicts before applying
echo "▶ Dry run..."
supabase db push --include-all --dns-resolver https --dry-run

# Wait for user confirmation before the real push
read -p "Apply? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "▶ Applying..."
supabase db push --include-all --dns-resolver https

echo "✓ Done. Verify the migration took effect:"
echo "  - Query the affected tables/columns in the Supabase dashboard"
echo "  - For RPCs, call them via /rest/v1/rpc/<fn_name>"

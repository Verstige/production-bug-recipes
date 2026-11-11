#!/usr/bin/env node
import { randomBytes as privacyRandomBytes } from 'node:crypto';
/**
 * scripts/smoke_onboarding.mjs
 *
 * Aug 24 2026 — Pre-launch readiness recommendation #3.
 *
 * Runs the full onboarding flow end-to-end against the live site,
 * exactly as a brand-new Supabase auth signup would experience it:
 *
 *   1. POST /auth/v1/signup   (fresh email + password)
 *   2. Confirm the handle_new_user trigger created a user_accounts row
 *   3. GET  /api/onboarding/lifecycle   (expect 1/7 — accent_theme auto)
 *   4. PUT  /auth/v1/admin/users/:id    (set theme_accent + theme_mode)
 *   5. PATCH user_accounts                (full_name, avatar_url)
 *   6. POST /api/onboarding/complete-step × 7
 *   7. GET  /api/onboarding/lifecycle   (expect 7/7, onboarding_complete=true)
 *   8. GET  /dashboard/trading          (expect 200, gate flipped)
 *
 * Verifies:
 *   - The trigger fires on real auth signup (not just programmatic INSERT)
 *   - The 7-step wizard completes successfully
 *   - The trigger flips onboarding_complete=true
 *   - The page-level gate allows the user through
 *
 * Run:  node scripts/smoke_onboarding.mjs
 *
 * Exits non-zero on any failed step. Prints a checklist at the end.
 */

import { createClient } from '@supabase/supabase-js'
import { randomUUID, randomBytes } from 'node:crypto'

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'https://<project-ref>.supabase.co'
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ''
const APP_URL      = process.env.APP_URL ?? 'https://www.yourdomain.com'

if (!SERVICE_KEY) {
    console.error('Set SUPABASE_SERVICE_ROLE_KEY before running this script')
    process.exit(2)
}

const svc = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
})

const results = []
function pass(name, detail) {
    results.push({ ok: true, name, detail })
    console.log(`✓ ${name}${detail ? ' — ' + detail : ''}`)
}
function fail(name, detail) {
    results.push({ ok: false, name, detail })
    console.log(`✗ ${name} — ${detail}`)
}
function info(msg) { console.log(`  ${msg}`) }

async function http(method, path, body, token) {
    const url = `${APP_URL}${path}`
    const headers = { 'Content-Type': 'application/json' }
    if (token) headers['Authorization'] = `Bearer ${token}`
    let res
    try {
        res = await fetch(url, {
            method,
            headers,
            body: body ? JSON.stringify(body) : undefined,
            cache: 'no-store',
        })
    } catch (e) {
        return { status: 0, json: null, text: `network_error: ${e.message ?? e}` }
    }
    const text = await res.text().catch(() => '')
    let json = null
    try { json = JSON.parse(text) } catch { /* leave null */ }
    return { status: res.status, json, text }
}

async function adminPatchUser(userId, body) {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
        method: 'PUT',
        headers: {
            'apikey': SERVICE_KEY,
            'Authorization': `Bearer ${SERVICE_KEY}`,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
    })
    if (!res.ok) {
        const t = await res.text()
        throw new Error(`admin update failed: ${res.status} ${t}`)
    }
}

async function patchPublic(userId, body) {
    const res = await fetch(
        `${SUPABASE_URL}/rest/v1/user_accounts?id=eq.${userId}`,
        {
            method: 'PATCH',
            headers: {
                'apikey': SERVICE_KEY,
                'Authorization': `Bearer ${SERVICE_KEY}`,
                'Content-Type': 'application/json',
                'Prefer': 'return=minimal',
            },
            body: JSON.stringify(body),
        },
    )
    if (!res.ok) {
        const t = await res.text()
        throw new Error(`user_accounts PATCH failed: ${res.status} ${t}`)
    }
}

async function insertPushSub(userId) {
    const sub = {
        user_id: userId,
        endpoint: `https://fcm.googleapis.com/fcm/send/smoke-${randomUUID()}`,
        p256dh: 'BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7CI5ntP6j0WfT8',
        auth: privacyRandomBytes(16).toString('base64url'),
        is_active: true,
    }
    const res = await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions`, {
        method: 'POST',
        headers: {
            'apikey': SERVICE_KEY,
            'Authorization': `Bearer ${SERVICE_KEY}`,
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
        },
        body: JSON.stringify(sub),
    })
    if (!res.ok && res.status !== 409) {
        const t = await res.text()
        throw new Error(`push_subscriptions INSERT failed: ${res.status} ${t}`)
    }
}

async function main() {
    const stamp = randomBytes(4).toString('hex').slice(0, 8)
    const email = `smoke-${stamp}@yourdomain.com`
    const password = `SmokePass${stamp}!`

    console.log(`Smoke test target: ${APP_URL}`)
    console.log(`Creating fresh user: ${email}\n`)

    // ── 1. Signup ────────────────────────────────────────────────────
    const signupRes = await fetch(`${SUPABASE_URL}/auth/v1/signup`, {
        method: 'POST',
        headers: {
            'apikey': SERVICE_KEY,
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({ email, password }),
    })
    if (!signupRes.ok) {
        let t = ''
        try { t = await signupRes.text() } catch {}
        fail('1. signup', `status ${signupRes.status} ${t ? t.slice(0, 200) : '(no body)'}`)
        process.exit(1)
    }
    const signup = await signupRes.json()
    if (!signup?.user?.id) {
        fail('1. signup', `no user.id in response: ${JSON.stringify(signup).slice(0, 200)}`)
        process.exit(1)
    }
    const userId = signup.user.id
    const accessToken = signup.access_token
    pass('1. signup', `user_id=${userId}`)

    // Wait for trigger
    await new Promise(r => setTimeout(r, 1500))

    // ── 2. Trigger created user_accounts? ──────────────────────────
    const pubRes = await fetch(
        `${SUPABASE_URL}/rest/v1/user_accounts?id=eq.${userId}&select=id,email`,
        {
            headers: {
                'apikey': SERVICE_KEY,
                'Authorization': `Bearer ${SERVICE_KEY}`,
            },
        },
    )
    const pubRows = await pubRes.json()
    if (pubRows.length === 1) pass('2. handle_new_user trigger fired', `user_accounts row exists`)
    else { fail('2. handle_new_user trigger', `expected 1 user_accounts row, got ${pubRows.length}`); return }

    // ── 3. GET lifecycle ────────────────────────────────────────────
    let lc = (await http('GET', '/api/onboarding/lifecycle', null, accessToken)).json
    if (lc?.onboarding_complete === false && lc?.completed_count === 1) {
        pass('3. lifecycle initial state', `1/7 complete, accent_theme auto`)
    } else {
        fail('3. lifecycle initial state', JSON.stringify(lc).slice(0, 200))
    }

    // ── 4. Set user_metadata for accent_theme ──────────────────────
    try {
        await adminPatchUser(userId, {
            user_metadata: {
                theme_accent: 'emerald',
                theme_mode: 'dark',
            },
        })
        pass('4. user_metadata set', 'theme_accent + theme_mode')
    } catch (e) {
        fail('4. user_metadata', e.message)
    }

    // ── 5. Set user_accounts profile + risk ─────────────────────────
    try {
        await patchPublic(userId, {
            full_name: 'Smoke Test',
            avatar_url: 'https://example.com/avatar.jpg',
            risk_acknowledged_at: new Date().toISOString(),
            broker_connection_status: 'connected',
            broker_platform: 'broker',
        })
        pass('5. user_accounts ready', 'avatar, full_name, risk, broker')
    } catch (e) {
        fail('5. user_accounts', e.message)
    }

    // ── 5b. Insert push subscription ──────────────────────────────
    try {
        await insertPushSub(userId)
        pass('5b. push_subscriptions', 'row inserted')
    } catch (e) {
        fail('5b. push_subscriptions', e.message)
    }

    // ── 6. POST complete-step × 7 ──────────────────────────────────
    const steps = ['profile_basics', 'accent_theme', 'risk_disclaimer',
                   'connect_broker', 'link_broker', 'enable_push', 'walkthrough']
    for (const step of steps) {
        const r = await http('POST', '/api/onboarding/complete-step', { step_key: step }, accessToken)
        if (r.json?.ok === true) pass(`6.${step}`, r.json.points_awarded?.amount
            ? `+${r.json.points_awarded.amount} pts` : 'completed')
        else fail(`6.${step}`, JSON.stringify(r.json).slice(0, 200))
    }

    // ── 7. Final lifecycle ─────────────────────────────────────────
    lc = (await http('GET', '/api/onboarding/lifecycle', null, accessToken)).json
    if (lc?.onboarding_complete === true && lc?.completed_count === 7) {
        pass('7. trigger fired', `7/7, partner_status=${lc.partner_status?.pill}`)
    } else {
        fail('7. trigger', JSON.stringify(lc).slice(0, 200))
    }

    // ── 8. /dashboard/trading accessible ───────────────────────────
    const dash = await http('GET', '/dashboard/trading', null, accessToken)
    if (dash.status === 200) pass('8. /dashboard/trading', '200 — gate flipped')
    else fail('8. /dashboard/trading', `status ${dash.status}`)

    // Cleanup — delete the test user (best-effort)
    try {
        await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
            method: 'DELETE',
            headers: {
                'apikey': SERVICE_KEY,
                'Authorization': `Bearer ${SERVICE_KEY}`,
            },
        })
        info(`cleaned up: ${email}`)
    } catch (e) {
        info(`cleanup skipped: ${e.message}`)
    }

    // Summary
    console.log('\n' + '═'.repeat(60))
    const passed = results.filter(r => r.ok).length
    const failed = results.filter(r => !r.ok).length
    console.log(`  ${passed} passed, ${failed} failed (${results.length} total)`)
    if (failed > 0) {
        console.log(`\n  ${'='.repeat(56)}`)
        console.log('  FAILURES:')
        for (const r of results.filter(r => !r.ok)) {
            console.log(`  - ${r.name}: ${r.detail}`)
        }
        process.exit(1)
    }
    console.log('\n  ✓ Smoke test PASSED — onboarding is ready for new users.')
}

main().catch(err => {
    console.error('FATAL:', err)
    process.exit(1)
})
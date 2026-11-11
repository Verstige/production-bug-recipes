# Multi-Cause "Page Won't Load" Diagnosis — Sep 5 2026

**CLASS-LEVEL METHODOLOGY**, not session-specific notes. Read this
whenever the user reports "the page won't load / shows an error / is
broken" on the platform without an obvious cause. The single symptom
"Application error" or "page doesn't load" can have FOUR
independent root causes — fix one and the user might still see the
exact same symptom. You have to chase every layer.

---

## TL;DR — the four-layer checklist

When the platform shows "Application error" or "page won't load", check
in this order. **All four need to be true for the app to render
correctly.** A fix in only one layer is not enough.

1. **Layer 1 — Runtime is alive.** Node server must start. Check
   Railway deploy status + look at runtime logs for `node server.js`
   starting. If the container crashed, see "Railway startCommand
   override" below.
2. **Layer 2 — Static assets serve.** CSS chunks, JS chunks, logos,
   icons. All must 200. If 404, the page tree mismatches hydration
   and React errors out. See "Asset 404 → hydration #418".
3. **Layer 3 — No render-time randomness.** Components must not call
   `Math.random()`, `Date.now()`, or `crypto.randomUUID()` during
   render. Server renders one set, client hydrates with different
   set → React detects tree mismatch. See "Hydration #418 = inline
   Math.random()".
4. **Layer 4 — Build-time env vars inlined correctly.** All
   `NEXT_PUBLIC_*` env vars must be present at build time (Railway
   injects them into the Docker build context). If missing, Next
   inlines the empty string or the build-time placeholder, and
   client-side fetches go to `https://stub.invalid` or similar
   garbage. See "stub.invalid baked-in URLs".

---

## The exact symptom chain on Sep 5 2026

User report: *"I can't get yourdomain.com to load on my phone — I cleared
cookies + cache multiple times."*

We pushed 3 fixes and the user STILL saw the same error each time.
Each fix was necessary but none was sufficient:

| Fix | Root cause addressed | Did it work? |
|---|---|---|
| `sw.js` CACHE_VERSION v107→v108 | PWA app shell serving old HTML | ✓ for new browser sessions |
| Dockerfile `startCommand=""` | Railway dashboard setting overriding CMD `node server.js` → crash loop | ✓ container now stays up |
| Un-ignore `public/logos/` | Logo PNG was 404 (gitignored) → hydration mismatch | ✓ navbar logo loads |
| Hero.tsx: move `Math.random()` to `useEffect` | Code-rain rendered different values server vs client | ✓ hydration passes |
| Dockerfile: `ARG NEXT_PUBLIC_SUPABASE_URL` instead of hardcoded stub | `stub.invalid` baked into JS bundle → all Supabase fetches fail | ✓ finally everything works |

The user was correctly told "run an audit, make no mistakes" before
any of this got diagnosed end-to-end. The lesson: **don't ship a
single-cause fix in response to a "page won't load" report**. Walk
through all four layers.

---

## Recipe A — Railway startCommand override (Layer 1)

**Symptom:** Container logs show `sh: 1: next: not found` or any
`npm run start` failure. Crash loop.

**Root cause:** Railway's service settings have a `startCommand`
field that overrides the Dockerfile's `CMD`. If the saved value is
`npm start` (set when the service was originally Nixpacks-built),
the Dockerfile's `["node", "server.js"]` is silently ignored.

**Diagnose:**
```bash
# Get the deployment metadata as JSON
railway deployment list --limit 1 --json
# Look for: meta.serviceManifest.deploy.startCommand = "npm start"
# If it's anything except "" or "node server.js", the override is active
```

**Fix option A — Dashboard:** Settings → Deploy → Start Command →
clear it.

**Fix option B — railway.toml override (deployable in code):**
```toml
[deploy]
startCommand = ""
# Empty string forces Railway to fall back to Dockerfile's CMD
restartPolicyType = "ON_FAILURE"
restartPolicyMaxRetries = 3
```
Per Railway docs: *"Configuration defined in code will always
override values from the dashboard."*

**Verify post-deploy:**
```bash
railway logs --deployment <id> --tail 30 | grep -E "Ready|Error"
# Expected: "✓ Ready in 151ms" — NO npm/start output
```

---

## Recipe B — Asset 404 → hydration mismatch (Layer 2)

**Symptom:** `<img>` or `<link>` tags reference files that return
404. Hydration crashes. Console shows React error #418 if you can
capture it.

**Diagnose:**
```bash
# For every asset referenced in the rendered HTML:
for path in /logos/app-logo-white.png /icons/icon-192.png \
            /brand/app.png /images/foo.png /favicon.ico; do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 8 "https://www.yourdomain.com$path")
    echo "$path: $code"
done
# Any non-200 is broken.
```

**Two common root causes:**

### B1 — File is .gitignore'd
The file exists in working tree but wasn't committed to git, so
Railway's build context (built from git) doesn't have it.

```bash
git check-ignore -v public/logos/app-logo-white.png
# If it prints ".gitignore:52:public/logos/" — that's the cause

# Fix: remove from .gitignore, then force-add the file
sed -i '/^public\/logos\/$/d' .gitignore
git add -f public/logos/*.png
git commit -m "fix(assets): un-ignore public/logos/"
```

### B2 — Dockerfile doesn't COPY it from the builder
If the file IS committed but still 404s, check `Dockerfile`:

```dockerfile
# Must have all three:
COPY --from=builder --chown=nextjs:nodejs /app/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
```
The standalone-only pattern doesn't get public/ — you need the
explicit `COPY /app/public`.

**Verify:**
```bash
docker run --rm -it <image> ls -la /app/public/logos/
# If empty/missing in the container, COPY didn't run.
```

---

## Recipe C — Hydration #418 = inline Math.random() (Layer 3)

**Symptom:** User sees "Application error: a client-side exception
has occurred." Console shows:
`Uncaught Error: Minified React error #418` from chunk `*.js`

`#418` = React docs: *"Hydration failed because the server
rendered HTML didn't match the client."*

**Primary cause:** A `"use client"` component calls `Math.random()`,
`Date.now()`, or `crypto.randomUUID()` during render (not inside
`useEffect`). Server renders with one set of values, client
hydrates with a different set, React detects mismatch, crashes.

**Diagnose:**
```bash
# Find every "use client" component with render-time Math.random
for f in src/components/*.tsx src/components/*.ts; do
    if grep -q "use client" "$f"; then
        if grep -q "Math.random\|Date.now\|new Date\|randomUUID" "$f"; then
            echo "=== $f ==="
            grep -n "Math.random\|Date.now\|new Date\|randomUUID" "$f"
        fi
    fi
done
# Manually verify each occurrence is inside useEffect or an event
# handler — if it's inline in JSX render, that's the bug.
```

**In minified production chunks, find the pattern:**
```bash
# Search deployed chunks for the most likely smell:
curl -s https://www.yourdomain.com/_next/static/chunks/XYZ.js | \
  grep -o '.map(.*Math\.random.*).{0,200}' | head -3
# If you see ".map(() => Math.random()", that's render-time.
```

**Fix — move random into useEffect:**
```tsx
// BEFORE (hydration killer):
const CodeRain = () => {
    return (
        <div>
            {Array.from({length: 30}).map((_, col) => {
                const delay = Math.random() * -10;  // ← RUNS ON SERVER
                return <div style={{animationDelay: `${delay}s`}} />;
            })}
        </div>
    );
};

// AFTER (safe):
const CodeRain = () => {
    const [cols, setCols] = useState<any[] | null>(null);
    useEffect(() => {
        const arr = Array.from({length: 30}, () => ({
            delay: Math.random() * -10,
        }));
        setCols(arr);
    }, []);
    return (
        <div>
            {cols?.map((c, i) => (
                <div key={i} style={{animationDelay: `${c.delay}s`}} />
            ))}
        </div>
    );
};
```
The initial server render has `cols = null` → no children. After
mount, `useEffect` populates with random values. SSR + first client
render are identical → no mismatch.

**Verify:** Browser console no longer shows error #418.

---

## Recipe D — stub.invalid baked-in env var (Layer 4)

**The root cause that bit us Sep 5:** the deployed JS bundle had
`https://stub.invalid` hardcoded as the Supabase URL. Every
Supabase fetch in the browser (auth.getSession(), queries,
realtime WebSocket, cron routes) failed with
`getaddrinfo ENOTFOUND stub.invalid`. User saw "Application
error" + green error toasts on every page.

**Why this happens:** Next.js inlines `NEXT_PUBLIC_*` env vars
into the JS bundle at build time. They CANNOT be replaced at
runtime via process.env on the client. If the Docker build
process doesn't have the real values, the bundle gets whatever
placeholder was there.

**Diagnose:**
```bash
# Check the deployed bundle for placeholder URLs:
curl -s https://www.yourdomain.com/_next/static/chunks/XYZ.js | \
  grep -o 'https://stub.invalid\|NEXT_PUBLIC_SUPABASE_URL.*=.\?"[^"]*"' | head -5

# Check Railway runtime logs for DNS errors:
railway logs --tail 30 | grep -i "stub.invalid\|ENOTFOUND"
# If you see "getaddrinfo ENOTFOUND stub.invalid" — that's this bug.
```

**Fix — Dockerfile ARG → ENV chain:**

```dockerfile
# WRONG: hardcoded stub (overrides Railway's NEXT_PUBLIC_*)
ENV NEXT_PUBLIC_SUPABASE_URL=https://stub.invalid
ENV NEXT_PUBLIC_SUPABASE_ANON_KEY=stub-key

# RIGHT: accept via build args, Railway injects them automatically
ARG NEXT_PUBLIC_SUPABASE_URL=https://stub.invalid
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY=stub-key
ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL}
ENV NEXT_PUBLIC_SUPABASE_ANON_KEY=${NEXT_PUBLIC_SUPABASE_ANON_KEY}
```

Railway docs: *"all service variables are available during both
the build step and at runtime"* — so service-level
NEXT_PUBLIC_SUPABASE_URL gets injected into the Docker build
context, picked up by ARG, then exported as ENV.

**Verify:**
```bash
# Re-fetch the deployed chunk:
curl -s https://www.yourdomain.com/_next/static/chunks/XYZ.js | \
  grep -c "stub.invalid"
# Expected: 0 (or just inside a GitHub URL string)

# Verify real URL is there:
curl -s https://www.yourdomain.com/_next/static/chunks/XYZ.js | \
  grep -o "https://<project-ref>\.supabase\.co" | head -1
# Expected: the real Supabase URL
```

---

## Recipe E — iOS PWA cache stale HTML

**Symptom:** After deploying a JS/CSS-only fix, iOS PWA users still
see old HTML referencing old chunk hashes → those chunks 404 →
React hydration fails → "Application error". Even clearing site
data + cookies does NOT clear PWA's SW cache.

**Why:** iOS Safari treats the installed PWA as a separate
context — `localStorage.clear()` and clearing cookies only
work in the browser tab, not the PWA.

**Fix:** bump `CACHE_VERSION` in `public/sw.js`:

```js
// Bump on every content-only release (iOS doesn't auto-revalidate)
const CACHE_VERSION = 'app-v108';  // was v107
```

When CACHE_VERSION changes:
1. Browser sees new sw.js
2. New SW `install()` event fires
3. New SW `activate()` event deletes ALL old static-* and runtime-*
   caches
4. Next page load → fresh from network → new HTML → new chunks

**Verify:**
```bash
curl -sL https://www.yourdomain.com/sw.js | grep "CACHE_VERSION ="
# Should show the new version you just pushed
```

**Pair with:** Recipe #17 (already in SKILL.md) about CACHE_VERSION
bumps. The Sep 5 session bumped v107 → v108 specifically to fix
the Hero.tsx hydration issue that desktop saw immediately but PWA
cached the old HTML for.

---

## Diagnostic procedure (full)

When the user says *"X is broken"* with no obvious cause:

```bash
# 1. Layer 1 — server alive?
curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 https://www.yourdomain.com/
# Expected: 200 (after a deploy succeeds)
# If 502, the proxy is up but the upstream is dead → check Railway
# If 000, total connection failure → DNS or host down
# If 404 from a path the user IS hitting, that's a routing issue

# 2. Layer 1.5 — what's Railway saying?
railway deployment list --limit 1
# Look for SUCCESS vs CRASHED vs BUILDING

railway logs --deployment <latest-id> --tail 50
# Look for: "✓ Ready in 151ms" (good) or "sh: 1: next: not found"
# (startCommand override) or "getaddrinfo ENOTFOUND stub.invalid"
# (env var bug) or "Module not found" (build broken)

# 3. Layer 2 — assets serve?
for path in / /favicon.ico /icons/icon-192.png /logos/app-logo-white.png /manifest.json /sw.js; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
        https://www.yourdomain.com$path)
    echo "$path: $code"
done
# Any non-200 = broken chain.

# 4. Layer 3 — hydration issues in source?
grep -rln "Math.random\|Date.now\|new Date()" src/ \
  | head -10 | while read f; do
    if grep -q "use client" "$f" || echo "$f" | grep -q ".tsx"; then
        echo "=== $f ==="
        grep -n "Math.random\|Date.now\|new Date" "$f" | head -3
    fi
done
# Manually verify each occurrence is inside useEffect.

# 5. Layer 3.5 — rendered output shape
python3 << 'PYEOF'
import subprocess, re
r = subprocess.run(['curl', '-s', 'https://www.yourdomain.com/'],
    capture_output=True, text=True, timeout=30)
html = r.stdout
chunks = set(re.findall(r'/_next/static/chunks/([^"]+\.js)', html))
for chunk in sorted(chunks):
    rc = subprocess.run(['curl', '-s',
        f'https://www.yourdomain.com/_next/static/chunks/{chunk}'],
        capture_output=True, text=True, timeout=15)
    text = rc.stdout
    # Look for inline Math.random() at render position
    pat = re.compile(r'\.map\([^)]*=>\s*\{[^}]{0,100}Math\.random[^}]{0,100}\}')
    if pat.search(text):
        print(f'  ✗ {chunk}: render-time Math.random()')
    if 'stub.invalid' in text:
        print(f'  ✗ {chunk}: stub.invalid reference')
PYEOF

# 6. Layer 4 — env vars inlined correctly?
for chunk in $(curl -s https://www.yourdomain.com/ | \
              grep -oE '/_next/static/chunks/[^"]+\.js' | head -16); do
    curl -s "https://www.yourdomain.com$chunk" | \
        grep -c "stub.invalid" > /tmp/cnt
    if [ "$(cat /tmp/cnt)" -gt 0 ]; then
        echo "✗ $chunk: $(cat /tmp/cnt) stub.invalid refs"
    fi
done
# Expected: 0 chunks with stub.invalid references
```

**Don't ship a single fix.** If the symptom persists after Layer 1
is healthy, run Layers 2-6 and fix each one before declaring done.
A single deploy with "just the iOS PWA cache bump" or "just the
hydration fix" left the user seeing the same error each time we
thought we were done.

---

## Pairs with other recipes

- **Recipe #17** (in SKILL.md) — PWA CACHE_VERSION bumping. The
  operational details of this file's Recipe E come from that
  recipe; this file covers when to apply it.
- **Recipe #45** (Aug 26 admin inbox) — iOS PWA + auth + render
  exception chain, three-layer cache fix.
- **Sep 5 white-label broker IB reference** — broker-integrated multi-account
  state changes that can also cause "page won't load" symptoms.

---

**Filed:** Sep 5 2026
**Trigger phrases:** "page won't load", "Application error",
"nothing is loading", "I cleared cookies and it still won't load",
"the error doesn't go away", "make no mistakes, audit the
session", "same error after my fix shipped".

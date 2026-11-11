# Partner Portal Styling — Pure Black + White (Sep 10, 2026)

## The Pattern

The the platform partner portal (`/dashboard/partners/*`) uses a **pure black + subtle white** aesthetic. No cyan glow, no gold/violet/emerald gradients, no bright accent colors. The user explicitly requested this after seeing a "too glowy" early draft with strong cyan/indigo gradients on the active states and badges.

The pattern across the 6 partner components:

```css
/* Background */
background: #000000;
border: 1px solid rgba(255, 255, 255, 0.06 - 0.12);

/* Text */
color: white;                       /* primary */
color: rgba(255, 255, 255, 0.85);  /* secondary */
color: rgba(255, 255, 255, 0.6);   /* tertiary / labels */
color: rgba(255, 255, 255, 0.5);   /* eyebrow / micro-labels */

/* Active state (instead of cyan glow) */
background: rgba(255, 255, 255, 0.06);
color: white;
box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.12);

/* Accent bar / strip (instead of solid color) */
background: rgba(255, 255, 255, 0.1);  /* default */
background: rgba(34, 211, 238, 0.15);  /* brand tint OK at low alpha */
```

## What Goes Wrong

1. **Cyan-glow active state on nav** — the temptation to make `.active` pop with `box-shadow: 0 0 12px rgba(34, 211, 238, 0.4)` or `background: rgba(34, 211, 238, 0.12)`. Both are too bright. The user said the "buttons inside the hero should only be going towards the section that's supposed to be on the existing homepage" — meaning calm, consistent, not "neon."
2. **Cyan→indigo gradient on badges** — `background: linear-gradient(135deg, #22d3ee, #6366f1)`. The gradient reads as "neon sticker" and breaks the black-on-black calm. Use `rgba(255, 255, 255, 0.1)` instead.
3. **Cyan borders on tutorial cards** — `border: 1px solid rgba(34, 211, 238, 0.16)` and matching `background: rgba(34, 211, 238, 0.05)`. The 0.16 alpha border is still too saturated. Drop to `rgba(255, 255, 255, 0.08)`.
4. **Left accent bars on KPI tiles at 0.4 alpha** — `rgba(34, 211, 238, 0.4)` reads as a colored tab/marker. Drop to 0.15 alpha max for any tinted accent, or 0.1 for the brand strip.
5. **Cyan brand subtitle** — `color: #22d3ee` on the "PARTNER PORTAL" eyebrow subtitle draws the eye to the wrong place. Use `rgba(255, 255, 255, 0.55)`.

## When It's OK to Use Color

The white-label broker activity feed uses `box-shadow: 0 0 6px rgba(34, 197, 94, 0.6)` on a green whitelabel dot. That's a status indicator (live/inactive), not a chrome accent. **Status colors are fine. UI chrome colors are not.**

The KPI tiles have cyan/gold/emerald/violet variants (`--cyan`, `--gold`, `--emerald`, `--violet`). These tint the **left accent strip and icon background**, never the value text. Keep the value text white. The tinting exists to differentiate metric categories (revenue vs. trades vs. referrals) at a glance — that's a category signal, not decoration.

## The Six Files

| File | Status (Sep 10, 2026) |
|---|---|
| `PartnerHero.css` | Pure black, no changes needed |
| `PartnerPerformanceChart.css` | Pure black, no changes needed |
| `PartnerActivityFeed.css` | Pure black, no changes needed |
| `white-label brokerNotConnectedBanner.css` | Pure black, no changes needed |
| `PartnerKPIGrid.css` | Tone down accent bars 0.4 → 0.15 alpha, icon bg 0.08 → 0.04 |
| `PartnerSidebar.css` | Replace cyan with white-frosted: brand subtitle, toggle active, nav badge, tutorial card, tutorial button |

## Review Checklist for New Partner Components

When adding a new component to `/dashboard/partners/`:

- [ ] Background is `#000000`
- [ ] Border is `rgba(255, 255, 255, 0.06-0.12)`
- [ ] No `box-shadow: 0 0 Npx rgba(<color>, 0.4+)` glow effects
- [ ] No `linear-gradient` with two non-white colors
- [ ] No solid `#22d3ee` / `#fbbf24` / `#a855f7` text on chrome
- [ ] Active states use white-frosted (`rgba(255, 255, 255, 0.06-0.12)`)
- [ ] Status colors (green whitelabel, red errors) OK at any alpha
- [ ] Category accents (cyan/gold/emerald/violet) on KPI tiles OK at ≤0.15 alpha

## Why This Matters

The user has stated multiple times that the partner portal is "still got the wrong design" and "I'm not seeing any of the previous partners sections that was there before." The partner portal needs to read as **calm, serious, and focused on data** — not a neon gaming dashboard. Pure black + white reads as "Bloomberg terminal for partners," which matches the audience (introducers reviewing downline performance and commissions).

# asw-app Page-to-Page Latency Investigation Plan

A staged plan to find and fix why `asw-app` takes 1.5-2.5s to respond to
ordinary page requests — noticed as "the app feels slow to go from page
to another page" while poking around Grafana during
`plans/07-k3s-production-cutover-plan.md`'s monitoring follow-on. Not
urgent (no real users yet), but worth understanding properly rather than
leaving as an unexplained characteristic, especially before any future
real-traffic milestone.

**Where the investigation already got to, before this plan existed:**
ruled out network/Cloudflare Tunnel (same latency hitting the cluster
directly), DB query volume (`/about`, near-static, is just as slow as
`/`), Redis (8ms round-trip), missing config/route cache (was actually
missing, cached it, no measurable improvement), raw PHP/Laravel bootstrap
(`php artisan --version`: 0.17s), CPU core starvation (doubled
`linux-k3s` from 1→2 physical cores live, no improvement), and DNS
resolution (instant). The one real lead: Laravel's built-in `/up` route
(bypasses the `web` middleware group entirely — no session, no CSRF, no
Livewire) responds in 0.35-0.55s, while every normal page takes 3-5x
longer. Something in the `web` middleware stack, session/CSRF handling,
or Livewire's per-request boot cost is the remaining suspect, but
guessing further from outside the request lifecycle isn't productive —
needs real request-level profiling.

This plan touches the sibling repo `Animal-Shelter-Workshop` (app code,
possibly `composer.json` for a temporary profiling package) — not this
repo's code directly.

---

## Flow

```
┌────────────────────────────────────┐
│   ASW-APP LATENCY INVESTIGATION    │▏
└────────────────────────────────────┘▔▔

┌────────────────────────────────┐     Laravel Telescope (temporary,
│ 1. Get real request-level         │▏    dev dependency) or manual
│    profiling data                 │▏    timing middleware — whichever
└────────────────────────────────┘▔▔    is faster to wire up safely
              │
              ▼
┌────────────────────────────────┐     find where the ~1-2s gap
│ 2. Identify the actual bottleneck │▏    between /up and a normal page
└────────────────────────────────┘▔▔    actually goes
              │
              ▼
┌────────────────────────────────┐     scoped to whatever Stage 2
│ 3. Fix it                         │▏    actually finds — no fix
└────────────────────────────────┘▔▔    guessed at in advance
              │
              ▼
┌────────────────────────────────┐     same before/after measurement
│ 4. Verify with real numbers       │▏    method already used (curl
└────────────────────────────────┘▔▔    -w time_starttransfer)
              │
              ▼
┌────────────────────────────────┐     Telescope (if used) has its own
│ 5. Remove profiling instrumentation│▏  real overhead and attack
└────────────────────────────────┘▔▔    surface — doesn't stay
```

---

## Why each stage is there

**Stage 1 — real profiling, not more outside guessing.** Everything
ruled out so far was tested from *outside* the request lifecycle (curl
timing, raw Redis pings, bare CLI boots). The remaining lead (`web`
middleware group overhead) can only be pinned down with visibility
*inside* a real request — which middleware/service provider/query is
actually consuming the time. Laravel Telescope is the standard tool for
this (per-request timeline, queries, cache calls, all in one view);
manual timing middleware (a few `microtime(true)` calls bracketing
suspect middleware) is the fallback if Telescope itself turns out to add
too much of its own overhead to trust the numbers on a resource-tight
node.

**Stage 2 — identify before fixing.** No fix gets attempted blind.
Given the `/up` vs. normal-page gap, the top suspects worth checking
first: session start/read (Redis-backed, already proven fast in
isolation, but worth confirming under real request context), CSRF token
generation/verification, Livewire's `ServiceProvider::boot()` (component
auto-discovery scanning the filesystem is a known real Livewire
performance trap when its manifest isn't cached), and Blade view
compilation/rendering (131 compiled views already exist in
`storage/framework/views`, so compilation itself is probably not it, but
rendering cost for a Livewire-heavy page could still be real).

**Stage 3 — fix scoped to the actual finding.** Deliberately not
pre-committing to a specific fix here (e.g. "cache Livewire components")
since that's a guess dressed up as a plan — Stage 2's real data decides
what Stage 3 actually does.

**Stage 4 — verify with the same method already proven to work.** The
`curl -w` timing approach already used throughout the investigation
(`time_starttransfer`) is simple, repeatable, and already has real
before numbers to compare against (1.5-2.5s baseline, `/up` at
0.35-0.55s as the floor).

**Stage 5 — don't leave profiling tooling running.** Telescope records
every request's queries/params/session data into its own DB table
indefinitely by default — real overhead and a real place secrets could
leak if left on. Whatever gets added in Stage 1 gets removed once
Stage 4 confirms the fix, same "temporary means temporary" discipline as
the rest of this homelab's practice.

---

## Verification

- Stage 1: profiling tool installed and capturing real request data for
  at least one normal page load (`/` or `/about`).
- Stage 2: a specific middleware/provider/call identified as the
  dominant cost, not just "the web middleware group in general."
- Stage 3: the fix applied, scoped to what Stage 2 found.
- Stage 4: `curl -s -o /dev/null -w "ttfb=%{time_starttransfer}s\n"`
  against `/` and `/about` shows latency meaningfully closer to `/up`'s
  0.35-0.55s floor than the 1.5-2.5s baseline — real before/after
  numbers recorded, not just "feels faster."
- Stage 5: profiling package/middleware removed, `composer.json` back to
  its pre-investigation state, confirmed via `git diff`.

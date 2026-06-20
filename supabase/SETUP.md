# Multi-tenant backend (Supabase) — setup

This is **Phase 1** of turning the ABC Tracker into a multi-school app. It does
**not** affect the live pilot (which stays on the current single-school build).

## The plan (phases)
1. **Foundation (this step):** database schema + per-school isolation (RLS). ← you run the SQL.
2. **App auth + data:** add login/signup to the Flutter app; read/write logs, roster, and dashboard from Supabase (scoped to the user's school). ← I build it; I'll need your project URL + anon key.
3. **Admin + roster UI:** manage students/staff/periods/behaviors, invite users, roles.
4. **SSO + polish:** Google/Microsoft sign-in, onboarding, data migration.
5. **FERPA:** Supabase DPA + data region, de-identification, retention. (Separate track, right after.)

## What you do now (Supabase dashboard)
1. Create a free account at **supabase.com** → **New project** (pick a name, a strong DB password, and a region — for a US school choose a US region).
2. Open the project → **SQL Editor** → paste the contents of `supabase/schema.sql` → **Run**. (Safe to re-run.)
3. **Authentication → Providers**: leave **Email** enabled for now (we'll add Google/Microsoft in Phase 4).
4. **Project Settings → API**: copy two values and send them to me (these are safe to share — the anon key is meant for client apps and is protected by the RLS policies):
   - **Project URL** (e.g. `https://abcdxyz.supabase.co`)
   - **anon public key**
   - Do **NOT** share the `service_role` key — keep that secret.

That's it for Phase 1. Once you send the URL + anon key, I'll wire the app's
login and data layer (Phase 2) on `dev`.

## How isolation works (why this is safe)
Every table has Row-Level Security. A user only ever sees rows where
`school_id` = their own school (resolved from their profile). A teacher at
School A literally cannot query School B's data — the database refuses it, even
if the app had a bug. Admins (coordinators) additionally can edit the roster and
invite users.

## Onboarding model
- A new user signs up, then either **creates a school** (becomes its admin) via
  the `create_school()` function, or **joins** a school whose admin invited their
  email via `accept_invite()`.
- Phase 3 adds the UI for this; the database functions already exist.

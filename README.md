# Qashflow

Qashflow contains a member-facing site and a separate administrator interface.

## Files

- `index.html` — member portal
- `admin.html` — separate administrator interface
- `supabase/schema.sql` — initial database tables and row-level security policies
- `.env.example` — environment variable names for a future backend integration

## Current status

The two HTML files provide the visual interface. They are not yet connected to authenticated Supabase data or production payment processing. Do not accept deposits or enable withdrawals until authentication, server-side financial workflows, access policies, audit logging, and reconciliation have been implemented and tested.

## Supabase setup

1. Create a Supabase project.
2. Open the SQL Editor and run `supabase/schema.sql`.
3. Keep the service-role key private. Never place it in HTML or browser JavaScript.
4. Configure an authenticated administrator through a trusted server-side process. Do not let users set their own role.
5. Configure and test Row Level Security before exposing user data.

## Next development stages

1. Add sign-up, sign-in, password recovery, and protected sessions.
2. Connect the member portal to profile, plans, deposit requests, withdrawals, rewards, and transaction history.
3. Add server-side functions for financial updates and append-only audit records.
4. Connect the administrator interface to role-checked admin functions.
5. Add integrations such as email, WhatsApp, Telegram, and customer support after the core system is secure.

## Deployment

Host `index.html` as the member entry point. Keep `admin.html` as a separate route/page, but remember that hiding a URL is not access control: administrator data and actions must be protected by authentication, server-side role checks, and database policies.


## Supabase backend
See `SUPABASE_SETUP.md` for the exact database setup and admin account steps. Run `supabase/schema.sql` in the Supabase SQL Editor before testing the connected buttons.

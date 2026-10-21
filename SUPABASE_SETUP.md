# Qashflow — Supabase backend setup

## 1. Run the database schema

Open the Supabase Dashboard for the project already used by Qashflow, then open **SQL Editor**.

Open `supabase/schema.sql`, copy the complete file, paste it into a new SQL query, and click **Run**.

This creates the tables, Row Level Security policies, authentication profile trigger, and secure server-side RPC functions used by the website.

## 2. Authentication

In Supabase Dashboard go to **Authentication → Providers → Email** and make sure Email/password sign-in is enabled.

For easiest testing, email confirmation can be disabled temporarily. If confirmation stays enabled, a new member must confirm their email before signing in.

## 3. Create the first admin

Create a normal account from the Qashflow member website first. Then, in Supabase SQL Editor, replace the email below with the admin email and run:

```sql
update public.profiles
set role = 'admin', account_status = 'active', updated_at = now()
where id = (select id from auth.users where email = 'YOUR_ADMIN_EMAIL');
```

Never put a service-role/secret key in the website.

## 4. Website credentials

The supplied project already contains the Supabase project URL and publishable browser key. The publishable key is safe to use in browser code when RLS is correctly configured. Do not replace it with a service-role key.

## 5. Main connected actions

Member side:
- Sign up / sign in / sign out
- Referral code assignment
- Dashboard balance/earnings/team data
- Deposit request creation and history
- Withdrawal request creation with server-side balance validation
- Plan activation
- Plan history
- Transaction ledger
- Team counts and commissions
- Reward claims
- Profile update
- Support ticket submission

Admin side:
- Protected admin login
- Live deposit requests
- Live withdrawal requests
- Approve/reject deposit requests
- Approve/reject withdrawals
- Member status changes
- Audited balance adjustments
- Ledger viewing
- Plan/package saving
- Commission/reward setting persistence
- Maintenance setting persistence
- Admin audit records

## Important

Run the SQL schema before testing the buttons. The frontend is now wired to Supabase, but the database schema/functions must exist in the Supabase project for the actions to work.

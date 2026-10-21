-- Qashflow initial schema. Run in the Supabase SQL editor.
-- Admin privileges must be assigned only through a trusted process.

create extension if not exists pgcrypto;

create type public.app_role as enum ('member', 'admin');
create type public.request_status as enum ('pending', 'approved', 'rejected', 'cancelled');
create type public.ledger_entry_type as enum (
  'deposit', 'plan_purchase', 'mining_earning', 'referral_commission',
  'bonus', 'reward', 'reinvest', 'withdrawal', 'refund', 'admin_adjustment', 'correction'
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  display_name text,
  referral_code text unique,
  referred_by uuid references public.profiles(id) on delete set null,
  role public.app_role not null default 'member',
  account_status text not null default 'active' check (account_status in ('active','suspended','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Create a member profile automatically when an auth user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, referral_code)
  values (
    new.id,
    nullif(new.raw_user_meta_data ->> 'display_name', ''),
    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  min_amount numeric(18,2) not null check (min_amount > 0),
  max_amount numeric(18,2) not null check (max_amount >= min_amount),
  duration_days integer not null default 120 check (duration_days > 0),
  daily_rate_min numeric(7,5) not null default 0.015 check (daily_rate_min >= 0),
  daily_rate_max numeric(7,5) not null default 0.020 check (daily_rate_max >= daily_rate_min),
  is_active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.deposit_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  currency text not null default 'USD',
  payment_method text not null,
  wallet_address text,
  transaction_hash text,
  proof_storage_path text,
  status public.request_status not null default 'pending',
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now(),
  unique (payment_method, transaction_hash)
);

create table public.plan_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  plan_id uuid not null references public.plans(id) on delete restrict,
  principal_amount numeric(18,2) not null check (principal_amount > 0),
  status text not null default 'pending_funding' check (status in ('pending_funding','active','expired','cancelled')),
  activated_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  check ((status <> 'active') or (activated_at is not null and expires_at is not null))
);

create table public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  amount numeric(18,2) not null check (amount >= 5),
  currency text not null default 'USD',
  destination_address text not null,
  status public.request_status not null default 'pending',
  transaction_hash text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);

-- Append-only financial ledger. Writes should be performed by trusted server-side functions.
create table public.transaction_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  entry_type public.ledger_entry_type not null,
  amount numeric(18,2) not null,
  currency text not null default 'USD',
  reference_type text,
  reference_id uuid,
  idempotency_key text unique,
  description text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.referral_commissions (
  id uuid primary key default gen_random_uuid(),
  beneficiary_user_id uuid not null references public.profiles(id) on delete restrict,
  source_user_id uuid not null references public.profiles(id) on delete restrict,
  source_subscription_id uuid references public.plan_subscriptions(id) on delete restrict,
  level smallint not null check (level between 1 and 3),
  rate numeric(7,5) not null check (rate >= 0),
  amount numeric(18,2) not null check (amount >= 0),
  ledger_entry_id uuid unique references public.transaction_ledger(id),
  created_at timestamptz not null default now()
);

create table public.rewards (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  required_active_members integer not null check (required_active_members > 0),
  reward_amount numeric(18,2) not null check (reward_amount >= 0),
  currency text not null default 'USD',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reward_claims (
  id uuid primary key default gen_random_uuid(),
  reward_id uuid not null references public.rewards(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  ledger_entry_id uuid unique references public.transaction_ledger(id),
  status public.request_status not null default 'pending',
  claimed_at timestamptz not null default now(),
  unique (reward_id, user_id)
);

create table public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references public.profiles(id) on delete restrict,
  action text not null,
  target_user_id uuid references public.profiles(id) on delete restrict,
  reference_type text,
  reference_id uuid,
  reason text not null,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create table public.site_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create index profiles_referred_by_idx on public.profiles(referred_by);
create index deposit_requests_user_created_idx on public.deposit_requests(user_id, created_at desc);
create index withdrawal_requests_user_created_idx on public.withdrawal_requests(user_id, created_at desc);
create index plan_subscriptions_user_created_idx on public.plan_subscriptions(user_id, created_at desc);
create index transaction_ledger_user_created_idx on public.transaction_ledger(user_id, created_at desc);
create index referral_commissions_beneficiary_idx on public.referral_commissions(beneficiary_user_id, created_at desc);
create index admin_audit_logs_created_idx on public.admin_audit_logs(created_at desc);

-- Helper: role is read from the protected profiles table.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin' and p.account_status = 'active'
  );
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

alter table public.profiles enable row level security;
alter table public.plans enable row level security;
alter table public.deposit_requests enable row level security;
alter table public.plan_subscriptions enable row level security;
alter table public.withdrawal_requests enable row level security;
alter table public.transaction_ledger enable row level security;
alter table public.referral_commissions enable row level security;
alter table public.rewards enable row level security;
alter table public.reward_claims enable row level security;
alter table public.admin_audit_logs enable row level security;
alter table public.site_settings enable row level security;

create policy "Members read own profile; admins read all" on public.profiles
for select to authenticated using (id = auth.uid() or public.is_admin());
-- Users can update only their display name directly. Role, referral attribution,
-- account status, and other sensitive fields must be changed by trusted server code.
revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;
create policy "Members update own display name; admins update profiles" on public.profiles
for update to authenticated using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

create policy "Anyone can read active plans" on public.plans
for select to authenticated using (is_active or public.is_admin());
create policy "Admins manage plans" on public.plans
for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Members read own deposit requests; admins read all" on public.deposit_requests
for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "Members create own deposit requests" on public.deposit_requests
for insert to authenticated with check (user_id = auth.uid());
create policy "Admins review deposit requests" on public.deposit_requests
for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Members read own subscriptions; admins read all" on public.plan_subscriptions
for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "Admins manage subscriptions" on public.plan_subscriptions
for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Members read own withdrawals; admins read all" on public.withdrawal_requests
for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "Members create own withdrawal requests" on public.withdrawal_requests
for insert to authenticated with check (user_id = auth.uid());
create policy "Admins review withdrawals" on public.withdrawal_requests
for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Members read own ledger; admins read all" on public.transaction_ledger
for select to authenticated using (user_id = auth.uid() or public.is_admin());
-- No client insert/update/delete policies on the ledger: trusted backend only.

create policy "Members read own commissions; admins read all" on public.referral_commissions
for select to authenticated using (beneficiary_user_id = auth.uid() or public.is_admin());
create policy "Authenticated users read active rewards" on public.rewards
for select to authenticated using (is_active or public.is_admin());
create policy "Admins manage rewards" on public.rewards
for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Members read own reward claims; admins read all" on public.reward_claims
for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "Members request own reward claims" on public.reward_claims
for insert to authenticated with check (user_id = auth.uid());
create policy "Admins review reward claims" on public.reward_claims
for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy "Admins read audit logs" on public.admin_audit_logs
for select to authenticated using (public.is_admin());
-- Audit inserts should be written by trusted server-side functions only.
create policy "Authenticated users read public settings" on public.site_settings
for select to authenticated using (key not like 'private.%' or public.is_admin());
create policy "Admins manage settings" on public.site_settings
for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.plans (name, min_amount, max_amount, duration_days, daily_rate_min, daily_rate_max)
values
  ('Package 1', 50, 100, 120, 0.015, 0.020),
  ('Package 2', 100, 250, 120, 0.015, 0.020),
  ('Package 3', 250, 500, 120, 0.015, 0.020)
on conflict do nothing;

insert into public.rewards (name, required_active_members, reward_amount)
values
  ('Team 10', 10, 3),
  ('Team 20', 20, 5),
  ('Team 50', 50, 10),
  ('Team 100', 100, 20),
  ('Team 500', 500, 50)
on conflict do nothing;

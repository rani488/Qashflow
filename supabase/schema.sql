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
declare referrer_id uuid;
begin
  if nullif(trim(new.raw_user_meta_data ->> 'referral_code'),'') is not null then
    select id into referrer_id from public.profiles where referral_code = upper(trim(new.raw_user_meta_data ->> 'referral_code')) limit 1;
  end if;
  insert into public.profiles (id, display_name, referral_code, referred_by)
  values (
    new.id,
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
    referrer_id
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


-- Support tickets submitted by authenticated members.
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  topic text not null,
  transaction_reference text,
  message text not null check (length(trim(message)) > 0),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  admin_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_tickets_user_created_idx on public.support_tickets(user_id, created_at desc);
alter table public.support_tickets enable row level security;
drop policy if exists "Members read own support tickets" on public.support_tickets;
create policy "Members read own support tickets" on public.support_tickets
for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists "Members create own support tickets" on public.support_tickets;
create policy "Members create own support tickets" on public.support_tickets
for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Admins manage support tickets" on public.support_tickets;
create policy "Admins manage support tickets" on public.support_tickets
for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Safe, server-side financial workflows.
create or replace function public.get_my_dashboard()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  balance numeric(18,2);
  earnings numeric(18,2);
  active_plans integer;
  team_count integer;
  pending_withdrawals numeric(18,2);
  lvl1 integer;
  lvl2 integer;
  lvl3 integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select coalesce(sum(amount),0) into balance from public.transaction_ledger where user_id=uid;
  select coalesce(sum(amount),0) into earnings from public.transaction_ledger where user_id=uid and entry_type in ('mining_earning','referral_commission','bonus','reward');
  select count(*) into active_plans from public.plan_subscriptions where user_id=uid and status='active';
  select count(*) into team_count from public.profiles where referred_by=uid and account_status='active';
  select coalesce(sum(amount),0) into pending_withdrawals from public.withdrawal_requests where user_id=uid and status='pending';
  select count(*) into lvl1 from public.profiles where referred_by=uid and account_status='active';
  select count(*) into lvl2 from public.profiles p join public.profiles p1 on p.referred_by=p1.id where p1.referred_by=uid and p.account_status='active';
  select count(*) into lvl3 from public.profiles p join public.profiles p1 on p.referred_by=p1.id join public.profiles p2 on p1.referred_by=p2.id where p2.referred_by=uid and p.account_status='active';
  return jsonb_build_object('balance',balance,'earnings',earnings,'active_plans',active_plans,'team_count',team_count,'pending_withdrawals',pending_withdrawals,'level1',lvl1,'level2',lvl2,'level3',lvl3);
end;
$$;
grant execute on function public.get_my_dashboard() to authenticated;

create or replace function public.create_deposit_request(
  p_amount numeric,
  p_currency text,
  p_payment_method text,
  p_wallet_address text default null,
  p_transaction_hash text default null
) returns uuid
language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid deposit amount'; end if;
  if coalesce(trim(p_payment_method),'') = '' then raise exception 'Payment method is required'; end if;
  if p_transaction_hash is not null and exists(select 1 from public.deposit_requests where transaction_hash=p_transaction_hash) then raise exception 'Transaction hash already submitted'; end if;
  insert into public.deposit_requests(user_id,amount,currency,payment_method,wallet_address,transaction_hash)
  values(uid,p_amount,coalesce(nullif(trim(p_currency),''),'USD'),trim(p_payment_method),nullif(trim(p_wallet_address),''),nullif(trim(p_transaction_hash),''))
  returning id into rid;
  return rid;
end;
$$;
grant execute on function public.create_deposit_request(numeric,text,text,text,text) to authenticated;

create or replace function public.create_withdrawal_request(
  p_amount numeric,
  p_currency text,
  p_destination_address text
) returns uuid
language plpgsql security definer set search_path=public as $$
declare uid uuid := auth.uid(); rid uuid; bal numeric; pending numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_amount is null or p_amount < 5 then raise exception 'Minimum withdrawal is $5'; end if;
  if coalesce(trim(p_destination_address),'') = '' then raise exception 'Destination address is required'; end if;
  perform 1 from public.profiles where id=uid for update;
  select coalesce(sum(amount),0) into bal from public.transaction_ledger where user_id=uid;
  select coalesce(sum(amount),0) into pending from public.withdrawal_requests where user_id=uid and status='pending';
  if bal - pending < p_amount then raise exception 'Insufficient available balance'; end if;
  insert into public.withdrawal_requests(user_id,amount,currency,destination_address)
  values(uid,p_amount,coalesce(nullif(trim(p_currency),''),'USD'),trim(p_destination_address)) returning id into rid;
  return rid;
end;
$$;
grant execute on function public.create_withdrawal_request(numeric,text,text) to authenticated;

create or replace function public.approve_deposit(p_request_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare r public.deposit_requests; entry_id uuid;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  select * into r from public.deposit_requests where id=p_request_id for update;
  if not found then raise exception 'Deposit request not found'; end if;
  if r.status <> 'pending' then raise exception 'Deposit is already processed'; end if;
  update public.deposit_requests set status='approved', reviewed_by=auth.uid(), reviewed_at=now(), review_note=p_note where id=r.id;
  insert into public.transaction_ledger(user_id,entry_type,amount,currency,reference_type,reference_id,idempotency_key,description,created_by,metadata)
  values(r.user_id,'deposit',r.amount,r.currency,'deposit_request',r.id,'deposit:'||r.id::text,'Deposit approved',auth.uid(),jsonb_build_object('payment_method',r.payment_method,'transaction_hash',r.transaction_hash))
  on conflict(idempotency_key) do nothing returning id into entry_id;
  insert into public.admin_audit_logs(actor_user_id,action,target_user_id,reference_type,reference_id,reason,after_data)
  values(auth.uid(),'approve_deposit',r.user_id,'deposit_request',r.id,coalesce(p_note,'Deposit approved'),jsonb_build_object('amount',r.amount));
end;
$$;
grant execute on function public.approve_deposit(uuid,text) to authenticated;

create or replace function public.reject_deposit(p_request_id uuid, p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.deposit_requests;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Rejection reason is required'; end if;
  select * into r from public.deposit_requests where id=p_request_id for update;
  if not found then raise exception 'Deposit request not found'; end if;
  if r.status <> 'pending' then raise exception 'Deposit is already processed'; end if;
  update public.deposit_requests set status='rejected', reviewed_by=auth.uid(), reviewed_at=now(), review_note=trim(p_note) where id=r.id;
  insert into public.admin_audit_logs(actor_user_id,action,target_user_id,reference_type,reference_id,reason,after_data)
  values(auth.uid(),'reject_deposit',r.user_id,'deposit_request',r.id,trim(p_note),jsonb_build_object('amount',r.amount));
end;
$$;
grant execute on function public.reject_deposit(uuid,text) to authenticated;

create or replace function public.approve_withdrawal(p_request_id uuid, p_tx_hash text default null, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare r public.withdrawal_requests; bal numeric; pending numeric;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  select * into r from public.withdrawal_requests where id=p_request_id for update;
  if not found then raise exception 'Withdrawal request not found'; end if;
  if r.status <> 'pending' then raise exception 'Withdrawal is already processed'; end if;
  perform 1 from public.profiles where id=r.user_id for update;
  select coalesce(sum(amount),0) into bal from public.transaction_ledger where user_id=r.user_id;
  select coalesce(sum(amount),0) into pending from public.withdrawal_requests where user_id=r.user_id and status='pending' and id<>r.id;
  if bal - pending < r.amount then raise exception 'Member no longer has sufficient balance'; end if;
  update public.withdrawal_requests set status='approved', reviewed_by=auth.uid(), reviewed_at=now(), review_note=p_note, transaction_hash=nullif(trim(p_tx_hash),'') where id=r.id;
  insert into public.transaction_ledger(user_id,entry_type,amount,currency,reference_type,reference_id,idempotency_key,description,created_by,metadata)
  values(r.user_id,'withdrawal',-r.amount,r.currency,'withdrawal_request',r.id,'withdrawal:'||r.id::text,'Withdrawal approved',auth.uid(),jsonb_build_object('destination',r.destination_address,'transaction_hash',p_tx_hash))
  on conflict(idempotency_key) do nothing;
  insert into public.admin_audit_logs(actor_user_id,action,target_user_id,reference_type,reference_id,reason,after_data)
  values(auth.uid(),'approve_withdrawal',r.user_id,'withdrawal_request',r.id,coalesce(p_note,'Withdrawal approved'),jsonb_build_object('amount',r.amount,'transaction_hash',p_tx_hash));
end;
$$;
grant execute on function public.approve_withdrawal(uuid,text,text) to authenticated;

create or replace function public.reject_withdrawal(p_request_id uuid, p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare r public.withdrawal_requests;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if coalesce(trim(p_note),'')='' then raise exception 'Rejection reason is required'; end if;
  select * into r from public.withdrawal_requests where id=p_request_id for update;
  if not found then raise exception 'Withdrawal request not found'; end if;
  if r.status <> 'pending' then raise exception 'Withdrawal is already processed'; end if;
  update public.withdrawal_requests set status='rejected', reviewed_by=auth.uid(), reviewed_at=now(), review_note=trim(p_note) where id=r.id;
  insert into public.admin_audit_logs(actor_user_id,action,target_user_id,reference_type,reference_id,reason,after_data)
  values(auth.uid(),'reject_withdrawal',r.user_id,'withdrawal_request',r.id,trim(p_note),jsonb_build_object('amount',r.amount));
end;
$$;
grant execute on function public.reject_withdrawal(uuid,text) to authenticated;

create or replace function public.activate_plan(p_plan_id uuid, p_amount numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); p public.plans; bal numeric; pending numeric; sid uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into p from public.plans where id=p_plan_id and is_active=true;
  if not found then raise exception 'Plan not found'; end if;
  if p_amount < p.min_amount or p_amount > p.max_amount then raise exception 'Amount is outside this plan range'; end if;
  perform 1 from public.profiles where id=uid for update;
  select coalesce(sum(amount),0) into bal from public.transaction_ledger where user_id=uid;
  select coalesce(sum(amount),0) into pending from public.withdrawal_requests where user_id=uid and status='pending';
  if bal - pending < p_amount then raise exception 'Insufficient available balance'; end if;
  insert into public.plan_subscriptions(user_id,plan_id,principal_amount,status,activated_at,expires_at)
  values(uid,p.id,p_amount,'active',now(),now()+(p.duration_days||' days')::interval) returning id into sid;
  insert into public.transaction_ledger(user_id,entry_type,amount,currency,reference_type,reference_id,idempotency_key,description,created_by)
  values(uid,'plan_purchase',-p_amount,'USD','plan_subscription',sid,'plan:'||sid::text,'Plan activated',uid);
  return sid;
end;
$$;
grant execute on function public.activate_plan(uuid,numeric) to authenticated;

create or replace function public.claim_reward(p_reward_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); r public.rewards; direct integer; claim_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into r from public.rewards where id=p_reward_id and is_active=true;
  if not found then raise exception 'Reward not found'; end if;
  select count(*) into direct from public.profiles where referred_by=uid and account_status='active';
  if direct < r.required_active_members then raise exception 'Reward requirements are not met'; end if;
  insert into public.reward_claims(reward_id,user_id,status) values(r.id,uid,'approved') returning id into claim_id;
  insert into public.transaction_ledger(user_id,entry_type,amount,currency,reference_type,reference_id,idempotency_key,description,created_by)
  values(uid,'reward',r.reward_amount,r.currency,'reward_claim',claim_id,'reward:'||claim_id::text,'Team milestone reward',uid);
  return claim_id;
exception when unique_violation then raise exception 'Reward already claimed';
end;
$$;
grant execute on function public.claim_reward(uuid) to authenticated;

create or replace function public.admin_set_setting(p_key text, p_value jsonb, p_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if coalesce(trim(p_key),'')='' or coalesce(trim(p_reason),'')='' then raise exception 'Setting key and reason are required'; end if;
  insert into public.site_settings(key,value,updated_by,updated_at) values(trim(p_key),p_value,auth.uid(),now())
  on conflict(key) do update set value=excluded.value,updated_by=auth.uid(),updated_at=now();
  insert into public.admin_audit_logs(actor_user_id,action,reference_type,reason,after_data)
  values(auth.uid(),'update_setting','site_setting',trim(p_reason),jsonb_build_object('key',p_key,'value',p_value));
end;
$$;
grant execute on function public.admin_set_setting(text,jsonb,text) to authenticated;

create or replace function public.admin_list_requests(p_kind text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if p_kind='deposits' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select d.*,p.display_name,p.referral_code from public.deposit_requests d join public.profiles p on p.id=d.user_id order by d.created_at desc limit 100) x;
  elsif p_kind='withdrawals' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out from (select w.*,p.display_name,p.referral_code from public.withdrawal_requests w join public.profiles p on p.id=w.user_id order by w.created_at desc limit 100) x;
  else raise exception 'Unknown request type'; end if;
  return out;
end;
$$;
grant execute on function public.admin_list_requests(text) to authenticated;

create or replace function public.admin_list_members()
returns jsonb language plpgsql security definer set search_path=public as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into out
  from (select id,display_name,referral_code,role,account_status,created_at from public.profiles order by created_at desc limit 500) x;
  return out;
end;
$$;
grant execute on function public.admin_list_members() to authenticated;

create or replace function public.admin_set_member_status(p_user_id uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare old_status text;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('active','suspended','closed') then raise exception 'Invalid account status'; end if;
  if coalesce(trim(p_reason),'')='' then raise exception 'Reason is required'; end if;
  select account_status into old_status from public.profiles where id=p_user_id for update;
  if not found then raise exception 'Member not found'; end if;
  update public.profiles set account_status=p_status,updated_at=now() where id=p_user_id;
  insert into public.admin_audit_logs(actor_user_id,action,target_user_id,reason,before_data,after_data)
  values(auth.uid(),'set_member_status',p_user_id,trim(p_reason),jsonb_build_object('account_status',old_status),jsonb_build_object('account_status',p_status));
end;
$$;
grant execute on function public.admin_set_member_status(uuid,text,text) to authenticated;

create or replace function public.admin_adjust_balance(p_user_id uuid, p_amount numeric, p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare bal numeric;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if p_amount=0 then raise exception 'Adjustment cannot be zero'; end if;
  if coalesce(trim(p_reason),'')='' then raise exception 'Reason is required'; end if;
  perform 1 from public.profiles where id=p_user_id for update;
  if not found then raise exception 'Member not found'; end if;
  select coalesce(sum(amount),0) into bal from public.transaction_ledger where user_id=p_user_id;
  if bal+p_amount < 0 then raise exception 'Adjustment would make balance negative'; end if;
  insert into public.transaction_ledger(user_id,entry_type,amount,currency,reference_type,idempotency_key,description,created_by,metadata)
  values(p_user_id,'admin_adjustment',p_amount,'USD','admin_adjustment','admin_adjustment:'||gen_random_uuid()::text,'Admin balance adjustment',auth.uid(),jsonb_build_object('reason',trim(p_reason)));
  insert into public.admin_audit_logs(actor_user_id,action,target_user_id,reason,before_data,after_data)
  values(auth.uid(),'balance_adjustment',p_user_id,trim(p_reason),jsonb_build_object('balance',bal),jsonb_build_object('balance',bal+p_amount,'amount',p_amount));
end;
$$;
grant execute on function public.admin_adjust_balance(uuid,numeric,text) to authenticated;

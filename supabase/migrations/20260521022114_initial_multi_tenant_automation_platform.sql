create extension if not exists pgcrypto;

create schema if not exists app_private;

create type public.account_type as enum ('personal', 'organization');
create type public.account_status as enum ('active', 'suspended', 'archived');
create type public.member_status as enum ('invited', 'active', 'suspended', 'left');
create type public.role_scope as enum ('system', 'account');
create type public.service_status as enum ('active', 'inactive', 'degraded', 'archived');
create type public.workflow_status as enum ('draft', 'published', 'archived');
create type public.run_status as enum ('queued', 'running', 'succeeded', 'failed', 'cancelled', 'timed_out');

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  type public.account_type not null,
  name text not null,
  slug text,
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  status public.account_status not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint accounts_slug_check check (
    slug is null or slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
  ),
  constraint accounts_slug_required_for_org check (
    (type = 'organization' and slug is not null) or (type = 'personal')
  )
);

create unique index accounts_org_slug_uniq on public.accounts (slug) where type = 'organization';
create index accounts_owner_user_id_idx on public.accounts (owner_user_id);

create table public.account_members (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  member_status public.member_status not null default 'active',
  joined_at timestamptz not null default now(),
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, user_id)
);

create index account_members_user_id_idx on public.account_members (user_id);
create index account_members_account_id_idx on public.account_members (account_id);

create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  description text,
  created_at timestamptz not null default now()
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.accounts(id) on delete cascade,
  scope public.role_scope not null default 'account',
  name text not null,
  description text,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, name),
  constraint roles_scope_account_consistency check (
    (scope = 'system' and account_id is null and is_system = true)
    or
    (scope = 'account' and account_id is not null)
  )
);

create index roles_account_id_idx on public.roles (account_id);

create table public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (role_id, permission_id)
);

create index role_permissions_permission_id_idx on public.role_permissions (permission_id);

create table public.member_roles (
  account_member_id uuid not null references public.account_members(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (account_member_id, role_id)
);

create index member_roles_role_id_idx on public.member_roles (role_id);

create table public.resource_shares (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  resource_type text not null,
  resource_id uuid not null,
  member_id uuid references public.account_members(id) on delete cascade,
  role_id uuid references public.roles(id) on delete cascade,
  access_level text not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint resource_shares_target_check check (
    ((member_id is not null)::int + (role_id is not null)::int) = 1
  )
);

create index resource_shares_account_resource_idx on public.resource_shares (account_id, resource_type, resource_id);

create table public.account_invitations (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  email text not null,
  role_id uuid references public.roles(id) on delete set null,
  invited_by uuid not null references auth.users(id) on delete restrict,
  token_hash text not null unique,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index account_invitations_account_id_idx on public.account_invitations (account_id);
create index account_invitations_email_idx on public.account_invitations (email);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name text not null,
  slug text not null,
  type text not null,
  owner_member_id uuid references public.account_members(id) on delete set null,
  status public.service_status not null default 'active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (account_id, slug)
);

create index services_account_id_idx on public.services (account_id);
create index services_owner_member_id_idx on public.services (owner_member_id);

create table public.service_environments (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  env_name text not null,
  runtime_config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (service_id, env_name)
);

create index service_environments_account_id_idx on public.service_environments (account_id);
create index service_environments_service_id_idx on public.service_environments (service_id);

create table public.service_endpoints (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  protocol text not null,
  endpoint text not null,
  auth_mode text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_endpoints_account_id_idx on public.service_endpoints (account_id);
create index service_endpoints_service_id_idx on public.service_endpoints (service_id);

create table public.service_secrets (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  key_name text not null,
  secret_ref text not null,
  rotation_due_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (service_id, key_name)
);

create index service_secrets_account_id_idx on public.service_secrets (account_id);
create index service_secrets_service_id_idx on public.service_secrets (service_id);

create table public.service_health_checks (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  check_type text not null,
  interval_seconds integer not null check (interval_seconds > 0),
  last_status text,
  last_checked_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_health_checks_account_id_idx on public.service_health_checks (account_id);
create index service_health_checks_service_id_idx on public.service_health_checks (service_id);

create table public.service_incidents (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  severity text not null,
  title text not null,
  description text,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_incidents_account_id_idx on public.service_incidents (account_id);
create index service_incidents_service_id_idx on public.service_incidents (service_id);

create table public.service_events (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index service_events_account_id_idx on public.service_events (account_id);
create index service_events_service_id_idx on public.service_events (service_id);
create index service_events_occurred_at_idx on public.service_events (occurred_at desc);

create table public.workflows (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name text not null,
  status public.workflow_status not null default 'draft',
  trigger_mode text not null default 'manual',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index workflows_account_id_idx on public.workflows (account_id);

create table public.workflow_versions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  version integer not null check (version > 0),
  graph_json jsonb not null default '{}'::jsonb,
  published_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (workflow_id, version)
);

create index workflow_versions_account_id_idx on public.workflow_versions (account_id);
create index workflow_versions_workflow_id_idx on public.workflow_versions (workflow_id);

create table public.workflow_nodes (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_version_id uuid not null references public.workflow_versions(id) on delete cascade,
  node_id text not null,
  node_type text not null,
  config_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workflow_version_id, node_id)
);

create index workflow_nodes_account_id_idx on public.workflow_nodes (account_id);
create index workflow_nodes_workflow_version_id_idx on public.workflow_nodes (workflow_version_id);

create table public.workflow_edges (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_version_id uuid not null references public.workflow_versions(id) on delete cascade,
  from_node_id text not null,
  to_node_id text not null,
  condition_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index workflow_edges_account_id_idx on public.workflow_edges (account_id);
create index workflow_edges_workflow_version_id_idx on public.workflow_edges (workflow_version_id);

create table public.workflow_triggers (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  trigger_type text not null,
  config_json jsonb not null default '{}'::jsonb,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index workflow_triggers_account_id_idx on public.workflow_triggers (account_id);
create index workflow_triggers_workflow_id_idx on public.workflow_triggers (workflow_id);

create table public.workflow_schedules (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  cron_expr text not null,
  timezone text not null default 'UTC',
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index workflow_schedules_account_id_idx on public.workflow_schedules (account_id);
create index workflow_schedules_workflow_id_idx on public.workflow_schedules (workflow_id);

create table public.workflow_webhooks (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  route_key text not null,
  secret_ref text not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, route_key)
);

create index workflow_webhooks_workflow_id_idx on public.workflow_webhooks (workflow_id);

create table public.retry_policies (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_id uuid references public.workflows(id) on delete cascade,
  max_attempts integer not null check (max_attempts >= 0),
  backoff_strategy text not null default 'exponential',
  backoff_seconds integer not null default 30 check (backoff_seconds >= 0),
  timeout_seconds integer check (timeout_seconds > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index retry_policies_account_id_idx on public.retry_policies (account_id);
create index retry_policies_workflow_id_idx on public.retry_policies (workflow_id);

create table public.workflow_runs (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  version_id uuid references public.workflow_versions(id) on delete set null,
  status public.run_status not null default 'queued',
  trigger_source text not null,
  idempotency_key text,
  retry_policy_id uuid references public.retry_policies(id) on delete set null,
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, idempotency_key)
);

create index workflow_runs_account_id_idx on public.workflow_runs (account_id);
create index workflow_runs_workflow_id_idx on public.workflow_runs (workflow_id);
create index workflow_runs_status_idx on public.workflow_runs (status, created_at desc);

create table public.node_runs (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_run_id uuid not null references public.workflow_runs(id) on delete cascade,
  node_id text not null,
  status public.run_status not null default 'queued',
  attempt integer not null default 1 check (attempt > 0),
  input_ref text,
  output_ref text,
  error_ref text,
  latency_ms integer check (latency_ms >= 0),
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index node_runs_account_id_idx on public.node_runs (account_id);
create index node_runs_workflow_run_id_idx on public.node_runs (workflow_run_id);
create index node_runs_status_idx on public.node_runs (status, created_at desc);

create table public.run_logs (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  run_id uuid references public.workflow_runs(id) on delete cascade,
  node_run_id uuid references public.node_runs(id) on delete cascade,
  level text not null,
  message text not null,
  metadata_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint run_logs_target_check check (
    ((run_id is not null)::int + (node_run_id is not null)::int) >= 1
  )
);

create index run_logs_account_id_idx on public.run_logs (account_id);
create index run_logs_run_id_idx on public.run_logs (run_id);
create index run_logs_node_run_id_idx on public.run_logs (node_run_id);
create index run_logs_created_at_idx on public.run_logs (created_at desc);

create table public.run_artifacts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  run_id uuid not null references public.workflow_runs(id) on delete cascade,
  artifact_type text not null,
  storage_path text not null,
  checksum text,
  created_at timestamptz not null default now()
);

create index run_artifacts_account_id_idx on public.run_artifacts (account_id);
create index run_artifacts_run_id_idx on public.run_artifacts (run_id);

create table public.dead_letter_runs (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_run_id uuid not null references public.workflow_runs(id) on delete cascade,
  reason text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index dead_letter_runs_account_id_idx on public.dead_letter_runs (account_id);
create index dead_letter_runs_workflow_run_id_idx on public.dead_letter_runs (workflow_run_id);

create table public.ai_providers (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  provider_name text not null,
  config jsonb not null default '{}'::jsonb,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, provider_name)
);

create index ai_providers_account_id_idx on public.ai_providers (account_id);

create table public.ai_models (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  provider_id uuid not null references public.ai_providers(id) on delete cascade,
  model_name text not null,
  capabilities jsonb not null default '{}'::jsonb,
  pricing_metadata jsonb not null default '{}'::jsonb,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider_id, model_name)
);

create index ai_models_account_id_idx on public.ai_models (account_id);
create index ai_models_provider_id_idx on public.ai_models (provider_id);

create table public.ai_prompt_templates (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name text not null,
  version integer not null default 1,
  template text not null,
  variables_json jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (account_id, name, version)
);

create index ai_prompt_templates_account_id_idx on public.ai_prompt_templates (account_id);

create table public.ai_tool_registry (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  tool_name text not null,
  tool_type text not null,
  config jsonb not null default '{}'::jsonb,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, tool_name)
);

create index ai_tool_registry_account_id_idx on public.ai_tool_registry (account_id);

create table public.ai_executions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  workflow_run_id uuid references public.workflow_runs(id) on delete set null,
  node_run_id uuid references public.node_runs(id) on delete set null,
  model_id uuid references public.ai_models(id) on delete set null,
  prompt_ref text,
  response_ref text,
  token_usage jsonb not null default '{}'::jsonb,
  estimated_cost numeric(12, 6) not null default 0,
  created_at timestamptz not null default now()
);

create index ai_executions_account_id_idx on public.ai_executions (account_id);
create index ai_executions_workflow_run_id_idx on public.ai_executions (workflow_run_id);
create index ai_executions_node_run_id_idx on public.ai_executions (node_run_id);

create table public.knowledge_sources (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name text not null,
  source_type text not null,
  config jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index knowledge_sources_account_id_idx on public.knowledge_sources (account_id);

create table public.ai_usage_daily (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  usage_date date not null,
  total_tokens bigint not null default 0,
  total_estimated_cost numeric(12, 6) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, usage_date)
);

create index ai_usage_daily_account_id_idx on public.ai_usage_daily (account_id);

create table public.api_keys (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name text not null,
  key_hash text not null unique,
  scopes text[] not null default '{}',
  expires_at timestamptz,
  last_used_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index api_keys_account_id_idx on public.api_keys (account_id);

create table public.webhook_deliveries (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  webhook_id uuid not null references public.workflow_webhooks(id) on delete cascade,
  attempt integer not null check (attempt > 0),
  status text not null,
  response_code integer,
  response_body text,
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

create index webhook_deliveries_account_id_idx on public.webhook_deliveries (account_id);
create index webhook_deliveries_webhook_id_idx on public.webhook_deliveries (webhook_id);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  channel text not null,
  template text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create index notifications_account_id_idx on public.notifications (account_id);
create index notifications_status_idx on public.notifications (status, created_at desc);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  resource_type text not null,
  resource_id uuid,
  before_ref text,
  after_ref text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index audit_logs_account_id_idx on public.audit_logs (account_id);
create index audit_logs_created_at_idx on public.audit_logs (created_at desc);

create table public.feature_flags (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  flag_key text not null,
  enabled boolean not null default false,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, flag_key)
);

create index feature_flags_account_id_idx on public.feature_flags (account_id);

create or replace function public.is_account_member(target_account_id uuid, target_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.account_members am
    where am.account_id = target_account_id
      and am.user_id = target_user_id
      and am.member_status = 'active'
  );
$$;

create or replace function public.has_account_permission(
  target_account_id uuid,
  permission_code text,
  target_user_id uuid default auth.uid()
)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.account_members am
    join public.member_roles mr on mr.account_member_id = am.id
    join public.roles r on r.id = mr.role_id
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions p on p.id = rp.permission_id
    where am.account_id = target_account_id
      and am.user_id = target_user_id
      and am.member_status = 'active'
      and (
        r.scope = 'system'
        or (r.scope = 'account' and r.account_id = target_account_id)
      )
      and p.code = permission_code
  );
$$;

revoke all on function public.is_account_member(uuid, uuid) from public;
revoke all on function public.has_account_permission(uuid, text, uuid) from public;
grant execute on function public.is_account_member(uuid, uuid) to authenticated;
grant execute on function public.has_account_permission(uuid, text, uuid) to authenticated;

insert into public.permissions (code, description)
values
  ('accounts.read', 'Read accounts'),
  ('accounts.manage', 'Manage account metadata and settings'),
  ('members.manage', 'Manage account memberships'),
  ('roles.manage', 'Manage role and permission assignments'),
  ('services.read', 'Read services'),
  ('services.manage', 'Manage services and service resources'),
  ('automation.read', 'Read workflows and automation resources'),
  ('automation.manage', 'Manage workflows, triggers, and versions'),
  ('automation.run', 'Run workflow executions'),
  ('runs.read', 'Read workflow and node runs'),
  ('runs.manage', 'Manage retries and dead letters'),
  ('ai.read', 'Read AI resources'),
  ('ai.manage', 'Manage AI providers, models, prompts and tools'),
  ('keys.manage', 'Manage API keys'),
  ('audit.read', 'Read audit logs'),
  ('notifications.manage', 'Manage notifications and webhooks'),
  ('feature_flags.manage', 'Manage feature flags')
on conflict (code) do nothing;

insert into public.roles (scope, account_id, name, description, is_system)
select role_seed.scope, role_seed.account_id, role_seed.name, role_seed.description, role_seed.is_system
from (
  values
    ('system'::public.role_scope, null::uuid, 'Owner'::text, 'Full access to all account resources'::text, true),
    ('system'::public.role_scope, null::uuid, 'Admin'::text, 'Administrative access to most resources'::text, true),
    ('system'::public.role_scope, null::uuid, 'Operator'::text, 'Operational access to services and automation'::text, true),
    ('system'::public.role_scope, null::uuid, 'Viewer'::text, 'Read-only access'::text, true)
) as role_seed(scope, account_id, name, description, is_system)
where not exists (
  select 1
  from public.roles existing_role
  where existing_role.scope = role_seed.scope
    and existing_role.name = role_seed.name
);

with role_map as (
  select id, name from public.roles where scope = 'system'
),
permission_map as (
  select id, code from public.permissions
)
insert into public.role_permissions (role_id, permission_id)
select rm.id, pm.id
from role_map rm
join permission_map pm on
  (
    rm.name = 'Owner'
    or (
      rm.name = 'Admin'
      and pm.code <> 'keys.manage'
    )
    or (
      rm.name = 'Operator'
      and pm.code in ('services.read', 'services.manage', 'automation.read', 'automation.manage', 'automation.run', 'runs.read', 'runs.manage', 'ai.read')
    )
    or (
      rm.name = 'Viewer'
      and pm.code in ('accounts.read', 'services.read', 'automation.read', 'runs.read', 'ai.read', 'audit.read')
    )
  )
on conflict do nothing;

create or replace function app_private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do update
  set email = excluded.email,
      display_name = coalesce(public.profiles.display_name, excluded.display_name),
      updated_at = now();

  insert into public.accounts (type, name, owner_user_id)
  values (
    'personal',
    coalesce(new.raw_user_meta_data ->> 'display_name', new.email, new.id::text),
    new.id
  );

  return new;
end;
$$;

revoke all on function app_private.handle_new_user() from public;

create or replace function app_private.handle_new_account()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  member_id uuid;
  owner_role_id uuid;
begin
  insert into public.account_members (account_id, user_id, member_status)
  values (new.id, new.owner_user_id, 'active')
  on conflict (account_id, user_id) do update
  set member_status = 'active',
      updated_at = now()
  returning id into member_id;

  select id into owner_role_id
  from public.roles
  where scope = 'system' and name = 'Owner'
  limit 1;

  if owner_role_id is not null and member_id is not null then
    insert into public.member_roles (account_member_id, role_id)
    values (member_id, owner_role_id)
    on conflict do nothing;
  end if;

  return new;
end;
$$;

revoke all on function app_private.handle_new_account() from public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure app_private.handle_new_user();

drop trigger if exists on_account_created on public.accounts;
create trigger on_account_created
after insert on public.accounts
for each row execute procedure app_private.handle_new_account();

create trigger profiles_set_updated_at before update on public.profiles for each row execute procedure public.set_updated_at();
create trigger accounts_set_updated_at before update on public.accounts for each row execute procedure public.set_updated_at();
create trigger account_members_set_updated_at before update on public.account_members for each row execute procedure public.set_updated_at();
create trigger roles_set_updated_at before update on public.roles for each row execute procedure public.set_updated_at();
create trigger resource_shares_set_updated_at before update on public.resource_shares for each row execute procedure public.set_updated_at();
create trigger account_invitations_set_updated_at before update on public.account_invitations for each row execute procedure public.set_updated_at();
create trigger services_set_updated_at before update on public.services for each row execute procedure public.set_updated_at();
create trigger service_environments_set_updated_at before update on public.service_environments for each row execute procedure public.set_updated_at();
create trigger service_endpoints_set_updated_at before update on public.service_endpoints for each row execute procedure public.set_updated_at();
create trigger service_secrets_set_updated_at before update on public.service_secrets for each row execute procedure public.set_updated_at();
create trigger service_health_checks_set_updated_at before update on public.service_health_checks for each row execute procedure public.set_updated_at();
create trigger service_incidents_set_updated_at before update on public.service_incidents for each row execute procedure public.set_updated_at();
create trigger workflows_set_updated_at before update on public.workflows for each row execute procedure public.set_updated_at();
create trigger workflow_nodes_set_updated_at before update on public.workflow_nodes for each row execute procedure public.set_updated_at();
create trigger workflow_triggers_set_updated_at before update on public.workflow_triggers for each row execute procedure public.set_updated_at();
create trigger workflow_schedules_set_updated_at before update on public.workflow_schedules for each row execute procedure public.set_updated_at();
create trigger workflow_webhooks_set_updated_at before update on public.workflow_webhooks for each row execute procedure public.set_updated_at();
create trigger retry_policies_set_updated_at before update on public.retry_policies for each row execute procedure public.set_updated_at();
create trigger workflow_runs_set_updated_at before update on public.workflow_runs for each row execute procedure public.set_updated_at();
create trigger node_runs_set_updated_at before update on public.node_runs for each row execute procedure public.set_updated_at();
create trigger ai_providers_set_updated_at before update on public.ai_providers for each row execute procedure public.set_updated_at();
create trigger ai_models_set_updated_at before update on public.ai_models for each row execute procedure public.set_updated_at();
create trigger ai_prompt_templates_set_updated_at before update on public.ai_prompt_templates for each row execute procedure public.set_updated_at();
create trigger ai_tool_registry_set_updated_at before update on public.ai_tool_registry for each row execute procedure public.set_updated_at();
create trigger knowledge_sources_set_updated_at before update on public.knowledge_sources for each row execute procedure public.set_updated_at();
create trigger ai_usage_daily_set_updated_at before update on public.ai_usage_daily for each row execute procedure public.set_updated_at();
create trigger feature_flags_set_updated_at before update on public.feature_flags for each row execute procedure public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.accounts enable row level security;
alter table public.account_members enable row level security;
alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.member_roles enable row level security;
alter table public.resource_shares enable row level security;
alter table public.account_invitations enable row level security;
alter table public.services enable row level security;
alter table public.service_environments enable row level security;
alter table public.service_endpoints enable row level security;
alter table public.service_secrets enable row level security;
alter table public.service_health_checks enable row level security;
alter table public.service_incidents enable row level security;
alter table public.service_events enable row level security;
alter table public.workflows enable row level security;
alter table public.workflow_versions enable row level security;
alter table public.workflow_nodes enable row level security;
alter table public.workflow_edges enable row level security;
alter table public.workflow_triggers enable row level security;
alter table public.workflow_schedules enable row level security;
alter table public.workflow_webhooks enable row level security;
alter table public.retry_policies enable row level security;
alter table public.workflow_runs enable row level security;
alter table public.node_runs enable row level security;
alter table public.run_logs enable row level security;
alter table public.run_artifacts enable row level security;
alter table public.dead_letter_runs enable row level security;
alter table public.ai_providers enable row level security;
alter table public.ai_models enable row level security;
alter table public.ai_prompt_templates enable row level security;
alter table public.ai_tool_registry enable row level security;
alter table public.ai_executions enable row level security;
alter table public.knowledge_sources enable row level security;
alter table public.ai_usage_daily enable row level security;
alter table public.api_keys enable row level security;
alter table public.webhook_deliveries enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_logs enable row level security;
alter table public.feature_flags enable row level security;

create policy profiles_select_self on public.profiles
for select to authenticated
using ((select auth.uid()) = id);

create policy profiles_insert_self on public.profiles
for insert to authenticated
with check ((select auth.uid()) = id);

create policy profiles_update_self on public.profiles
for update to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy accounts_select_member on public.accounts
for select to authenticated
using (public.is_account_member(id));

create policy accounts_insert_owner on public.accounts
for insert to authenticated
with check ((select auth.uid()) = owner_user_id);

create policy accounts_update_manager on public.accounts
for update to authenticated
using (public.has_account_permission(id, 'accounts.manage'))
with check (public.has_account_permission(id, 'accounts.manage'));

create policy account_members_select_member on public.account_members
for select to authenticated
using (public.is_account_member(account_id));

create policy account_members_insert_manager on public.account_members
for insert to authenticated
with check (public.has_account_permission(account_id, 'members.manage'));

create policy account_members_update_manager on public.account_members
for update to authenticated
using (public.has_account_permission(account_id, 'members.manage'))
with check (public.has_account_permission(account_id, 'members.manage'));

create policy account_members_delete_manager on public.account_members
for delete to authenticated
using (public.has_account_permission(account_id, 'members.manage'));

create policy permissions_read_authenticated on public.permissions
for select to authenticated
using (true);

create policy roles_select_member on public.roles
for select to authenticated
using (
  scope = 'system'
  or public.is_account_member(account_id)
);

create policy roles_insert_manager on public.roles
for insert to authenticated
with check (
  account_id is not null
  and scope = 'account'
  and public.has_account_permission(account_id, 'roles.manage')
);

create policy roles_update_manager on public.roles
for update to authenticated
using (
  account_id is not null
  and scope = 'account'
  and public.has_account_permission(account_id, 'roles.manage')
)
with check (
  account_id is not null
  and scope = 'account'
  and public.has_account_permission(account_id, 'roles.manage')
);

create policy roles_delete_manager on public.roles
for delete to authenticated
using (
  account_id is not null
  and scope = 'account'
  and public.has_account_permission(account_id, 'roles.manage')
);

create policy role_permissions_select_member on public.role_permissions
for select to authenticated
using (
  exists (
    select 1
    from public.roles r
    where r.id = role_permissions.role_id
      and (r.scope = 'system' or public.is_account_member(r.account_id))
  )
);

create policy role_permissions_manage on public.role_permissions
for all to authenticated
using (
  exists (
    select 1
    from public.roles r
    where r.id = role_permissions.role_id
      and r.scope = 'account'
      and public.has_account_permission(r.account_id, 'roles.manage')
  )
)
with check (
  exists (
    select 1
    from public.roles r
    where r.id = role_permissions.role_id
      and r.scope = 'account'
      and public.has_account_permission(r.account_id, 'roles.manage')
  )
);

create policy member_roles_select_member on public.member_roles
for select to authenticated
using (
  exists (
    select 1
    from public.account_members am
    where am.id = member_roles.account_member_id
      and public.is_account_member(am.account_id)
  )
);

create policy member_roles_manage on public.member_roles
for all to authenticated
using (
  exists (
    select 1
    from public.account_members am
    where am.id = member_roles.account_member_id
      and public.has_account_permission(am.account_id, 'members.manage')
  )
)
with check (
  exists (
    select 1
    from public.account_members am
    where am.id = member_roles.account_member_id
      and public.has_account_permission(am.account_id, 'members.manage')
  )
);

create policy resource_shares_access on public.resource_shares
for all to authenticated
using (
  public.has_account_permission(account_id, 'automation.read')
)
with check (
  public.has_account_permission(account_id, 'automation.manage')
);

create policy account_invitations_access on public.account_invitations
for all to authenticated
using (public.has_account_permission(account_id, 'members.manage'))
with check (public.has_account_permission(account_id, 'members.manage'));

create policy services_select on public.services
for select to authenticated
using (public.has_account_permission(account_id, 'services.read'));

create policy services_write on public.services
for all to authenticated
using (public.has_account_permission(account_id, 'services.manage'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy service_environments_access on public.service_environments
for all to authenticated
using (public.has_account_permission(account_id, 'services.read'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy service_endpoints_access on public.service_endpoints
for all to authenticated
using (public.has_account_permission(account_id, 'services.read'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy service_secrets_access on public.service_secrets
for all to authenticated
using (public.has_account_permission(account_id, 'services.manage'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy service_health_checks_access on public.service_health_checks
for all to authenticated
using (public.has_account_permission(account_id, 'services.read'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy service_incidents_access on public.service_incidents
for all to authenticated
using (public.has_account_permission(account_id, 'services.read'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy service_events_access on public.service_events
for all to authenticated
using (public.has_account_permission(account_id, 'services.read'))
with check (public.has_account_permission(account_id, 'services.manage'));

create policy workflows_access on public.workflows
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy workflow_versions_access on public.workflow_versions
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy workflow_nodes_access on public.workflow_nodes
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy workflow_edges_access on public.workflow_edges
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy workflow_triggers_access on public.workflow_triggers
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy workflow_schedules_access on public.workflow_schedules
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy workflow_webhooks_access on public.workflow_webhooks
for all to authenticated
using (public.has_account_permission(account_id, 'automation.read'))
with check (public.has_account_permission(account_id, 'automation.manage'));

create policy retry_policies_access on public.retry_policies
for all to authenticated
using (public.has_account_permission(account_id, 'runs.read'))
with check (public.has_account_permission(account_id, 'runs.manage'));

create policy workflow_runs_access on public.workflow_runs
for all to authenticated
using (public.has_account_permission(account_id, 'runs.read'))
with check (
  public.has_account_permission(account_id, 'automation.run')
  or public.has_account_permission(account_id, 'runs.manage')
);

create policy node_runs_access on public.node_runs
for all to authenticated
using (public.has_account_permission(account_id, 'runs.read'))
with check (public.has_account_permission(account_id, 'automation.run'));

create policy run_logs_access on public.run_logs
for all to authenticated
using (public.has_account_permission(account_id, 'runs.read'))
with check (public.has_account_permission(account_id, 'automation.run'));

create policy run_artifacts_access on public.run_artifacts
for all to authenticated
using (public.has_account_permission(account_id, 'runs.read'))
with check (public.has_account_permission(account_id, 'automation.run'));

create policy dead_letter_runs_access on public.dead_letter_runs
for all to authenticated
using (public.has_account_permission(account_id, 'runs.read'))
with check (public.has_account_permission(account_id, 'runs.manage'));

create policy ai_providers_access on public.ai_providers
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'ai.manage'));

create policy ai_models_access on public.ai_models
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'ai.manage'));

create policy ai_prompt_templates_access on public.ai_prompt_templates
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'ai.manage'));

create policy ai_tool_registry_access on public.ai_tool_registry
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'ai.manage'));

create policy ai_executions_access on public.ai_executions
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'automation.run'));

create policy knowledge_sources_access on public.knowledge_sources
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'ai.manage'));

create policy ai_usage_daily_access on public.ai_usage_daily
for all to authenticated
using (public.has_account_permission(account_id, 'ai.read'))
with check (public.has_account_permission(account_id, 'ai.manage'));

create policy api_keys_access on public.api_keys
for all to authenticated
using (public.has_account_permission(account_id, 'keys.manage'))
with check (public.has_account_permission(account_id, 'keys.manage'));

create policy webhook_deliveries_access on public.webhook_deliveries
for all to authenticated
using (public.has_account_permission(account_id, 'notifications.manage'))
with check (public.has_account_permission(account_id, 'notifications.manage'));

create policy notifications_access on public.notifications
for all to authenticated
using (public.has_account_permission(account_id, 'notifications.manage'))
with check (public.has_account_permission(account_id, 'notifications.manage'));

create policy audit_logs_access on public.audit_logs
for all to authenticated
using (public.has_account_permission(account_id, 'audit.read'))
with check (public.has_account_permission(account_id, 'accounts.manage'));

create policy feature_flags_access on public.feature_flags
for all to authenticated
using (public.has_account_permission(account_id, 'accounts.read'))
with check (public.has_account_permission(account_id, 'feature_flags.manage'));

revoke all on all tables in schema public from anon;
grant usage on schema app_private to authenticated;
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

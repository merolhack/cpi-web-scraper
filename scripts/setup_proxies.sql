-- Create table for proxies
create table if not exists public.cpi_proxies (
  proxy_id bigint generated always as identity not null,
  ip_address inet not null,
  port integer not null,
  protocol text not null, -- 'http', 'socks4', 'socks5'
  country_code char(2) not null, -- 'MX'
  status text not null default 'unchecked', -- 'active', 'dead', 'unchecked'
  latency_ms integer default 9999,
  fail_count integer default 0,
  success_count integer default 0,
  last_checked timestamp with time zone default now(),
  last_used timestamp with time zone,
  created_at timestamp with time zone default now() not null,
  
  constraint cpi_proxies_pkey primary key (proxy_id),
  constraint cpi_proxies_unique_socket unique (ip_address, port, protocol)
);

-- Partial index for fast retrieval of active MX proxies
create index if not exists idx_cpi_proxies_active_mx 
  on public.cpi_proxies (latency_ms asc, fail_count asc) 
  where status = 'active' and country_code = 'MX';

-- RPC function to get the best available proxy
create or replace function get_best_proxy_mx()
returns json
language plpgsql
as $$
declare
  selected_proxy record;
begin
  -- Select best proxy: active, MX, lowest fail_count, lowest latency
  -- Also prioritize proxies not used recently (or never used) to distribute load? 
  -- For now, simple greedy approach as requested.
  
  update public.cpi_proxies
  set last_used = now()
  where proxy_id = (
    select proxy_id
    from public.cpi_proxies
    where status = 'active' and country_code = 'MX'
    order by fail_count asc, latency_ms asc
    limit 1
    for update skip locked
  )
  returning * into selected_proxy;
  
  if selected_proxy is null then
    return null;
  end if;
  
  return row_to_json(selected_proxy);
end;
$$;

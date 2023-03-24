-- Users
create table users (
  id                       uuid references auth.users on delete cascade not null primary key,
  updated_at               timestamp with time zone,
  full_name                text,
  email                    text unique not null,
  avatar_url               text,
  has_completed_onboarding boolean not null default false
);

-- RLS
alter table users
  enable row level security;

create policy "Public users are viewable by everyone." on users
  for select using (true);

create policy "Users can insert their own user." on users
  for insert with check (auth.uid() = id);

create policy "Users can update own user." on users
  for update using (auth.uid() = id);

-- This trigger automatically creates a user entry when a new user signs up
-- via Supabase Auth.for more details.
create function public.handle_new_user()
returns trigger as $$
begin
  insert into public.users (id, full_name, email, avatar_url)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'email', new.raw_user_meta_data->>'avatar_url');
  return new;
end;
$$ language plpgsql security definer;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Teams
create table public.teams (
  id                  uuid primary key default uuid_generate_v4(),
  inserted_at         timestamp with time zone default timezone('utc'::text, now()) not null,
  slug                text not null unique,
  name                text,
  is_personal         boolean default false,
  stripe_customer_id  text,
  stripe_price_id     text,
  billing_cycle_start timestamp with time zone,
  created_by          uuid references public.users not null
);
comment on table public.teams is 'Teams data.';

-- Projects
create table public.projects (
  id            uuid primary key default uuid_generate_v4(),
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  slug           text not null,
  name           text not null,
  public_api_key text not null unique,
  github_repo    text,
  team_id        uuid references public.teams on delete cascade not null,
  is_starter     boolean not null default false,
  created_by     uuid references public.users not null
);
comment on table public.projects is 'Projects within a team.';

-- Memberships
create type membership_type as enum ('viewer', 'admin');

create table public.memberships (
  id            uuid primary key default uuid_generate_v4(),
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  user_id       uuid references public.users not null,
  team_id       uuid references public.teams not null,
  type          membership_type not null
);
comment on table public.memberships is 'Memberships of a user in a team.';

-- Domains
create table public.domains (
  id            bigint generated by default as identity primary key,
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  name          text not null unique,
  project_id    uuid references public.projects on delete cascade not null
);
comment on table public.domains is 'Domains associated to a project.';

-- Tokens
create table public.tokens (
  id            bigint generated by default as identity primary key,
  inserted_at   timestamp with time zone default timezone('utc'::text, now()) not null,
  value         text not null,
  project_id    uuid references public.projects on delete cascade not null,
  created_by    uuid references public.users not null
);
comment on table public.tokens is 'Tokens associated to a project.';

-- Files
create extension if not exists vector with schema public;

create table public.files (
  id          bigint generated by default as identity primary key,
  path        text not null,
  meta        jsonb,
  project_id  uuid references public.projects on delete cascade not null,
  updated_at  timestamp with time zone default timezone('utc'::text, now()) not null
);

-- File sections
create table public.file_sections (
  id          bigint generated by default as identity primary key,
  file_id     bigint not null references public.files on delete cascade,
  content     text,
  token_count int,
  embedding   vector(1536)
);

create or replace function match_file_sections(embedding vector(1536), match_threshold float, match_count int, min_content_length int)
returns table (path text, content text, token_count int, similarity float)
language plpgsql
as $$
#variable_conflict use_variable
begin
  return query
  select
    files.path,
    file_sections.content,
    file_sections.token_count,
    (file_sections.embedding <#> embedding) * -1 as similarity
  from file_sections
  join files
    on file_sections.file_id = files.id

  -- We only care about sections that have a useful amount of content
  where length(file_sections.content) >= min_content_length

  -- The dot product is negative because of a Postgres limitation, so we negate it
  and (file_sections.embedding <#> embedding) * -1 > match_threshold

  -- OpenAI embeddings are normalized to length 1, so
  -- cosine similarity and dot product will produce the same results.
  -- Using dot product which can be computed slightly faster.
  --
  -- For the different syntaxes, see https://github.com/pgvector/pgvector
  order by file_sections.embedding <#> embedding

  limit match_count;
end;
$$;

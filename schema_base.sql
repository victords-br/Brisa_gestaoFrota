-- ============================================================================
-- Brisa Transporte — Gestão de Frota
-- Schema base (tabelas e índices) — DDL de origem do projeto Supabase.
--
-- Observações:
--   * Pressupõe um projeto Supabase (o schema `auth` com a tabela auth.users já existe).
--   * As tabelas foram reordenadas por dependência de FK para permitir execução
--     em um banco limpo. O conteúdo das colunas/constraints é o original.
--   * RLS, políticas, grants, triggers e funções NÃO estão aqui: ver
--     `erp_almoxarifado.sql` (incremento do módulo de almoxarifado/manutenção)
--     e as migrações específicas de cada módulo.
-- ============================================================================

create table public.setores (
  id uuid not null default gen_random_uuid (),
  nome_setor character varying null,
  constraint setores_pkey primary key (id)
) TABLESPACE pg_default;

create table public.funcionarios (
  id uuid not null default gen_random_uuid (),
  cod_funcionario integer not null,
  nome_funcionario character varying not null,
  cpf_funcionario character varying not null,
  rg_funcionario character varying null,
  endereco_funcionario character varying null,
  tell_funcionario character varying null,
  setor_id uuid null,
  is_mecanico boolean not null default false,
  constraint funcionarios_pkey primary key (id),
  constraint funcionarios_setor_id_fkey foreign KEY (setor_id) references setores (id)
) TABLESPACE pg_default;

create table public.veiculos (
  id bigserial not null,
  placa text not null,
  modelo text not null,
  criado_em timestamp with time zone null default now(),
  constraint veiculos_pkey primary key (id),
  constraint veiculos_placa_key unique (placa)
) TABLESPACE pg_default;

create table public.linhas (
  id integer not null,
  nome character varying null,
  constraint linhas_pkey primary key (id)
) TABLESPACE pg_default;

create table public.grupo_problemas (
  id uuid not null default gen_random_uuid (),
  nome text not null,
  created_at timestamp with time zone not null default timezone ('utc'::text, now()),
  constraint grupo_problemas_pkey primary key (id),
  constraint grupo_problemas_nome_key unique (nome)
) TABLESPACE pg_default;

create table public.profiles (
  id uuid not null,
  nome text not null,
  role text not null default 'motorista'::text,
  criado_em timestamp with time zone null default now(),
  constraint profiles_pkey primary key (id),
  constraint profiles_id_fkey foreign KEY (id) references auth.users (id) on delete CASCADE,
  constraint profiles_role_check check (
    (
      role = any (
        array[
          'motorista'::text,
          'admin'::text,
          'porteiro'::text,
          'manutencao'::text
        ]
      )
    )
  )
) TABLESPACE pg_default;

create table public.pecas (
  id bigserial not null,
  codigo text not null,
  nome text not null,
  descricao text null,
  unidade text not null default 'un'::text,
  estoque_minimo numeric(12, 3) not null default 0,
  saldo_estoque numeric(12, 3) not null default 0,
  custo_medio numeric(14, 4) not null default 0,
  ativo boolean not null default true,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint pecas_pkey primary key (id),
  constraint pecas_codigo_key unique (codigo),
  constraint pecas_custo_medio_check check ((custo_medio >= (0)::numeric)),
  constraint pecas_estoque_minimo_check check ((estoque_minimo >= (0)::numeric)),
  constraint pecas_saldo_estoque_check check ((saldo_estoque >= (0)::numeric))
) TABLESPACE pg_default;

create table public.checklists (
  id bigserial not null,
  motorista_id uuid null,
  motorista_nome text null,
  veiculo_id bigint null,
  veiculo_placa text null,
  data timestamp with time zone null default now(),
  itens_ok integer null default 0,
  itens_nao_ok integer null default 0,
  observacoes text null,
  fotos jsonb null default '[]'::jsonb,
  status_portaria text not null default 'Aguardando'::text,
  validado_por uuid null,
  validado_em timestamp with time zone null,
  observacao_portaria text null,
  itens_nao_ok_detalhes jsonb not null default '[]'::jsonb,
  constraint checklists_pkey primary key (id),
  constraint checklists_motorista_id_fkey foreign KEY (motorista_id) references auth.users (id),
  constraint checklists_validado_por_fkey foreign KEY (validado_por) references auth.users (id) on delete set null,
  constraint checklists_veiculo_id_fkey foreign KEY (veiculo_id) references veiculos (id),
  constraint checklists_status_portaria_check check (
    (
      status_portaria = any (
        array[
          'Aguardando'::text,
          'Validado'::text,
          'Encaminhado'::text
        ]
      )
    )
  )
) TABLESPACE pg_default;

create table public.ordens_servico (
  id uuid not null default gen_random_uuid (),
  veiculo_id bigint null,
  porteiro_id uuid null,
  prioridade text not null default 'Normal'::text,
  descricao text not null,
  status text not null default 'Pendente'::text,
  mecanico text null,
  obs_manutencao text null,
  data_conclusao timestamp with time zone null,
  created_at timestamp with time zone not null default timezone ('utc'::text, now()),
  grupo_id uuid null,
  funcionario_id uuid null,
  mecanico_id uuid null,
  checklist_id bigint null,
  motorista_id uuid null,
  motorista_nome text null,
  constraint ordens_servico_pkey primary key (id),
  constraint ordens_servico_checklist_id_fkey foreign KEY (checklist_id) references checklists (id) on delete set null,
  constraint ordens_servico_grupo_id_fkey foreign KEY (grupo_id) references grupo_problemas (id) on delete set null,
  constraint ordens_servico_mecanico_id_fkey foreign KEY (mecanico_id) references funcionarios (id) on delete set null,
  constraint ordens_servico_motorista_id_fkey foreign KEY (motorista_id) references auth.users (id) on delete set null,
  constraint ordens_servico_porteiro_id_fkey foreign KEY (porteiro_id) references profiles (id) on delete set null,
  constraint fk_ordens_servico_funcionario foreign KEY (funcionario_id) references funcionarios (id) not VALID,
  constraint ordens_servico_veiculo_id_fkey foreign KEY (veiculo_id) references veiculos (id) on delete CASCADE
) TABLESPACE pg_default;

create unique INDEX IF not exists ordens_servico_checklist_id_uidx on public.ordens_servico using btree (checklist_id) TABLESPACE pg_default
where
  (checklist_id is not null);

create table public.itens_ordem_servico (
  id bigserial not null,
  ordem_servico_id uuid not null,
  peca_id bigint not null,
  quantidade numeric(12, 3) not null,
  custo_unitario numeric(14, 4) not null,
  custo_total numeric GENERATED ALWAYS as ((quantidade * custo_unitario)) STORED (16, 4) null,
  created_at timestamp with time zone not null default now(),
  quantidade_utilizada numeric(12, 3) not null default 0,
  mecanico_id uuid null,
  liberado_por uuid null,
  liberado_em timestamp with time zone null,
  confirmado_por uuid null,
  confirmado_em timestamp with time zone null,
  constraint itens_ordem_servico_pkey primary key (id),
  constraint itens_ordem_servico_liberado_por_fkey foreign KEY (liberado_por) references auth.users (id) on delete set null,
  constraint itens_ordem_servico_mecanico_id_fkey foreign KEY (mecanico_id) references funcionarios (id) on delete set null,
  constraint itens_ordem_servico_ordem_servico_id_fkey foreign KEY (ordem_servico_id) references ordens_servico (id) on delete RESTRICT,
  constraint itens_ordem_servico_peca_id_fkey foreign KEY (peca_id) references pecas (id) on delete RESTRICT,
  constraint itens_ordem_servico_confirmado_por_fkey foreign KEY (confirmado_por) references auth.users (id) on delete set null,
  constraint itens_ordem_servico_custo_unitario_check check ((custo_unitario >= (0)::numeric)),
  constraint itens_ordem_servico_quantidade_check check ((quantidade > (0)::numeric)),
  constraint itens_os_quantidade_utilizada_check check (
    (
      (quantidade_utilizada >= (0)::numeric)
      and (quantidade_utilizada <= quantidade)
    )
  )
) TABLESPACE pg_default;

create index IF not exists itens_os_ordem_idx on public.itens_ordem_servico using btree (ordem_servico_id) TABLESPACE pg_default;

create table public.movimentacoes_estoque (
  id bigserial not null,
  peca_id bigint not null,
  tipo text not null,
  quantidade numeric(12, 3) not null,
  custo_unitario numeric(14, 4) not null,
  custo_total numeric GENERATED ALWAYS as ((quantidade * custo_unitario)) STORED (16, 4) null,
  ordem_servico_id uuid null,
  usuario_id uuid null,
  observacao text null,
  created_at timestamp with time zone not null default now(),
  constraint movimentacoes_estoque_pkey primary key (id),
  constraint movimentacoes_estoque_ordem_servico_id_fkey foreign KEY (ordem_servico_id) references ordens_servico (id) on delete RESTRICT,
  constraint movimentacoes_estoque_peca_id_fkey foreign KEY (peca_id) references pecas (id) on delete RESTRICT,
  constraint movimentacoes_estoque_usuario_id_fkey foreign KEY (usuario_id) references auth.users (id) on delete set null,
  constraint movimentacoes_estoque_custo_unitario_check check ((custo_unitario >= (0)::numeric)),
  constraint movimentacoes_estoque_quantidade_check check ((quantidade > (0)::numeric)),
  constraint movimentacoes_estoque_tipo_check check (
    (
      tipo = any (array['entrada'::text, 'saida'::text])
    )
  )
) TABLESPACE pg_default;

create index IF not exists movimentos_peca_data_idx on public.movimentacoes_estoque using btree (peca_id, created_at desc) TABLESPACE pg_default;

create index IF not exists movimentos_os_idx on public.movimentacoes_estoque using btree (ordem_servico_id) TABLESPACE pg_default;

create table public.mapa_abastecimento (
  id bigserial not null,
  horario text not null,
  km_ini double precision not null,
  km_fim double precision not null,
  qtd_litros integer not null,
  func_id uuid null,
  veiculo_id integer not null,
  linha_id integer null,
  data date null,
  tipo_abastecimento character varying null default 'GASOLINA, DIESEL S10, DIESEL S500'::character varying,
  constraint mapa_abastecimento_pkey primary key (id),
  constraint mapa_abastecimento_func_id_fkey foreign KEY (func_id) references funcionarios (id),
  constraint mapa_abastecimento_linha_id_fkey foreign KEY (linha_id) references linhas (id)
) TABLESPACE pg_default;

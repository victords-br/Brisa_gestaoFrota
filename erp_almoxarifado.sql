ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role = ANY (ARRAY['motorista', 'admin', 'porteiro', 'manutencao']));

ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS is_mecanico boolean NOT NULL DEFAULT false;

-- Vínculo do funcionário (RH) com o usuário do app (auth.users).
-- Permite a RPC validar_checklist_portaria resolver o autor do checklist
-- para um funcionário e gravar funcionario_id na OS (coluna canônica do motorista).
ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS funcionarios_user_id_uidx
  ON public.funcionarios (user_id)
  WHERE user_id IS NOT NULL;

-- (OPCIONAL) Backfill best-effort do vínculo por nome. Revise ANTES de rodar:
-- casa profiles.nome com funcionarios.nome_funcionario (case-insensitive).
-- UPDATE public.funcionarios f
-- SET user_id = p.id
-- FROM public.profiles p
-- WHERE f.user_id IS NULL
--   AND lower(trim(f.nome_funcionario)) = lower(trim(p.nome));

ALTER TABLE public.ordens_servico
  ADD COLUMN IF NOT EXISTS mecanico_id uuid REFERENCES public.funcionarios (id) ON DELETE SET NULL;

ALTER TABLE public.ordens_servico
  ADD COLUMN IF NOT EXISTS checklist_id bigint REFERENCES public.checklists (id) ON DELETE SET NULL;
ALTER TABLE public.ordens_servico
  ADD COLUMN IF NOT EXISTS motorista_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;
ALTER TABLE public.ordens_servico
  ADD COLUMN IF NOT EXISTS motorista_nome text;

ALTER TABLE public.checklists
  ADD COLUMN IF NOT EXISTS status_portaria text NOT NULL DEFAULT 'Aguardando',
  ADD COLUMN IF NOT EXISTS validado_por uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS validado_em timestamptz,
  ADD COLUMN IF NOT EXISTS observacao_portaria text,
  ADD COLUMN IF NOT EXISTS itens_nao_ok_detalhes jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.checklists
  DROP CONSTRAINT IF EXISTS checklists_status_portaria_check;

ALTER TABLE public.checklists
  ADD CONSTRAINT checklists_status_portaria_check
  CHECK (status_portaria IN ('Aguardando', 'Validado', 'Encaminhado'));

UPDATE public.checklists c
SET status_portaria = 'Encaminhado'
FROM public.ordens_servico os
WHERE os.checklist_id = c.id;

CREATE UNIQUE INDEX IF NOT EXISTS ordens_servico_checklist_id_uidx
  ON public.ordens_servico (checklist_id)
  WHERE checklist_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.pecas (
  id bigserial PRIMARY KEY,
  codigo text NOT NULL UNIQUE,
  nome text NOT NULL,
  descricao text,
  unidade text NOT NULL DEFAULT 'un',
  estoque_minimo numeric(12, 3) NOT NULL DEFAULT 0 CHECK (estoque_minimo >= 0),
  saldo_estoque numeric(12, 3) NOT NULL DEFAULT 0 CHECK (saldo_estoque >= 0),
  custo_medio numeric(14, 4) NOT NULL DEFAULT 0 CHECK (custo_medio >= 0),
  ativo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.itens_ordem_servico (
  id bigserial PRIMARY KEY,
  ordem_servico_id uuid NOT NULL REFERENCES public.ordens_servico (id) ON DELETE RESTRICT,
  peca_id bigint NOT NULL REFERENCES public.pecas (id) ON DELETE RESTRICT,
  quantidade numeric(12, 3) NOT NULL CHECK (quantidade > 0),
  custo_unitario numeric(14, 4) NOT NULL CHECK (custo_unitario >= 0),
  custo_total numeric(16, 4) GENERATED ALWAYS AS (quantidade * custo_unitario) STORED,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.itens_ordem_servico
  ADD COLUMN IF NOT EXISTS quantidade_utilizada numeric(12, 3) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS mecanico_id uuid REFERENCES public.funcionarios (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS liberado_por uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS liberado_em timestamptz,
  ADD COLUMN IF NOT EXISTS confirmado_por uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS confirmado_em timestamptz;

UPDATE public.itens_ordem_servico
SET quantidade_utilizada = quantidade,
    liberado_em = created_at,
    confirmado_em = created_at
WHERE liberado_em IS NULL AND confirmado_em IS NULL;

ALTER TABLE public.itens_ordem_servico
  ALTER COLUMN quantidade_utilizada SET DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'itens_os_quantidade_utilizada_check'
      AND conrelid = 'public.itens_ordem_servico'::regclass
  ) THEN
    ALTER TABLE public.itens_ordem_servico
      ADD CONSTRAINT itens_os_quantidade_utilizada_check
      CHECK (quantidade_utilizada >= 0 AND quantidade_utilizada <= quantidade);
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.movimentacoes_estoque (
  id bigserial PRIMARY KEY,
  peca_id bigint NOT NULL REFERENCES public.pecas (id) ON DELETE RESTRICT,
  tipo text NOT NULL CHECK (tipo IN ('entrada', 'saida')),
  quantidade numeric(12, 3) NOT NULL CHECK (quantidade > 0),
  custo_unitario numeric(14, 4) NOT NULL CHECK (custo_unitario >= 0),
  custo_total numeric(16, 4) GENERATED ALWAYS AS (quantidade * custo_unitario) STORED,
  ordem_servico_id uuid REFERENCES public.ordens_servico (id) ON DELETE RESTRICT,
  usuario_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  observacao text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS itens_os_ordem_idx
  ON public.itens_ordem_servico (ordem_servico_id);
CREATE INDEX IF NOT EXISTS movimentos_peca_data_idx
  ON public.movimentacoes_estoque (peca_id, created_at DESC);
CREATE INDEX IF NOT EXISTS movimentos_os_idx
  ON public.movimentacoes_estoque (ordem_servico_id);

CREATE TABLE IF NOT EXISTS public.ordens_servico_mecanicos (
  ordem_servico_id uuid NOT NULL REFERENCES public.ordens_servico (id) ON DELETE CASCADE,
  funcionario_id uuid NOT NULL REFERENCES public.funcionarios (id) ON DELETE RESTRICT,
  especialidade text NOT NULL DEFAULT 'Mecânico',
  inicio_em timestamptz,
  fim_em timestamptz,
  horas_trabalhadas numeric(10, 2) GENERATED ALWAYS AS (
    CASE
      WHEN inicio_em IS NOT NULL AND fim_em IS NOT NULL
      THEN round((extract(epoch FROM (fim_em - inicio_em)) / 3600)::numeric, 2)
      ELSE NULL
    END
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (ordem_servico_id, funcionario_id),
  CONSTRAINT ordens_servico_mecanicos_especialidade_check
    CHECK (length(trim(especialidade)) > 0),
  CONSTRAINT ordens_servico_mecanicos_periodo_check
    CHECK (
      (inicio_em IS NULL AND fim_em IS NULL)
      OR (inicio_em IS NOT NULL AND fim_em IS NOT NULL AND fim_em > inicio_em)
    )
);

CREATE INDEX IF NOT EXISTS ordens_servico_mecanicos_funcionario_idx
  ON public.ordens_servico_mecanicos (funcionario_id);

-- Mantém os mecânicos já atribuídos antes da associação de equipe.
INSERT INTO public.ordens_servico_mecanicos (ordem_servico_id, funcionario_id)
SELECT os.id, os.mecanico_id
FROM public.ordens_servico os
WHERE os.mecanico_id IS NOT NULL
ON CONFLICT (ordem_servico_id, funcionario_id) DO NOTHING;

ALTER TABLE public.pecas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.itens_ordem_servico ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimentacoes_estoque ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ordens_servico_mecanicos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pecas_manutencao_select ON public.pecas;
CREATE POLICY pecas_manutencao_select ON public.pecas
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

DROP POLICY IF EXISTS pecas_manutencao_insert ON public.pecas;
CREATE POLICY pecas_manutencao_insert ON public.pecas
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

DROP POLICY IF EXISTS pecas_manutencao_update ON public.pecas;
CREATE POLICY pecas_manutencao_update ON public.pecas
  FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

DROP POLICY IF EXISTS itens_os_manutencao_select ON public.itens_ordem_servico;
CREATE POLICY itens_os_manutencao_select ON public.itens_ordem_servico
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

DROP POLICY IF EXISTS movimentos_manutencao_select ON public.movimentacoes_estoque;
CREATE POLICY movimentos_manutencao_select ON public.movimentacoes_estoque
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

DROP POLICY IF EXISTS ordens_servico_operacao_select ON public.ordens_servico;
CREATE POLICY ordens_servico_operacao_select ON public.ordens_servico
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao', 'porteiro')
  ));

DROP POLICY IF EXISTS ordens_servico_mecanicos_manutencao_select ON public.ordens_servico_mecanicos;
CREATE POLICY ordens_servico_mecanicos_manutencao_select ON public.ordens_servico_mecanicos
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

REVOKE INSERT, UPDATE ON public.pecas FROM authenticated;
GRANT SELECT ON public.pecas TO authenticated;
GRANT SELECT ON public.ordens_servico TO authenticated;
GRANT INSERT (codigo, nome, descricao, unidade, estoque_minimo)
  ON public.pecas TO authenticated;
GRANT UPDATE (codigo, nome, descricao, unidade, estoque_minimo, ativo, updated_at)
  ON public.pecas TO authenticated;
GRANT SELECT ON public.itens_ordem_servico, public.movimentacoes_estoque TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.itens_ordem_servico, public.movimentacoes_estoque FROM authenticated;
REVOKE ALL ON public.ordens_servico_mecanicos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ordens_servico_mecanicos TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.pecas_id_seq TO authenticated;

CREATE OR REPLACE FUNCTION public.registrar_entrada_estoque(
  p_peca_id bigint,
  p_quantidade numeric,
  p_custo_unitario numeric,
  p_observacao text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_saldo numeric(12, 3);
  v_custo_medio numeric(14, 4);
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') NOT IN ('admin', 'manutencao') THEN
    RAISE EXCEPTION 'Sem permissão para registrar entrada de estoque';
  END IF;
  IF p_quantidade <= 0 OR p_custo_unitario < 0 THEN
    RAISE EXCEPTION 'Quantidade ou custo inválido';
  END IF;

  SELECT saldo_estoque, custo_medio
  INTO v_saldo, v_custo_medio
  FROM public.pecas
  WHERE id = p_peca_id AND ativo
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Peça não encontrada ou inativa';
  END IF;

  UPDATE public.pecas
  SET custo_medio = CASE
        WHEN v_saldo + p_quantidade = 0 THEN 0
        ELSE ((v_saldo * v_custo_medio) + (p_quantidade * p_custo_unitario)) / (v_saldo + p_quantidade)
      END,
      saldo_estoque = v_saldo + p_quantidade,
      updated_at = now()
  WHERE id = p_peca_id;

  INSERT INTO public.movimentacoes_estoque (
    peca_id, tipo, quantidade, custo_unitario, usuario_id, observacao
  ) VALUES (
    p_peca_id, 'entrada', p_quantidade, p_custo_unitario, auth.uid(), p_observacao
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.definir_funcionario_mecanico(
  p_funcionario_id uuid,
  p_is_mecanico boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') <> 'admin' THEN
    RAISE EXCEPTION 'Somente administradores podem gerenciar mecânicos';
  END IF;
  IF p_is_mecanico IS NULL THEN
    RAISE EXCEPTION 'Informe se o funcionário é mecânico';
  END IF;

  UPDATE public.funcionarios
  SET is_mecanico = p_is_mecanico
  WHERE id = p_funcionario_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Funcionário não encontrado';
  END IF;
END;
$$;

-- Lista os usuários do app (profiles) para o admin escolher o vínculo.
-- SECURITY DEFINER para não depender do RLS de leitura em profiles.
CREATE OR REPLACE FUNCTION public.listar_usuarios_app()
RETURNS TABLE (
  id uuid,
  nome text,
  role text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT p.role INTO v_role
  FROM public.profiles p
  WHERE p.id = auth.uid();

  IF COALESCE(v_role, '') <> 'admin' THEN
    RAISE EXCEPTION 'Somente administradores podem listar usuários';
  END IF;

  RETURN QUERY
  SELECT p.id, COALESCE(p.nome, 'Sem nome')::text, p.role::text
  FROM public.profiles p
  ORDER BY p.nome;
END;
$$;

-- Vincula (ou desvincula, com p_user_id nulo) um usuário do app a um funcionário (RH).
-- Resolve o ponto de atenção da validar_checklist_portaria: sem este vínculo
-- a OS gerada pelo checklist fica sem funcionario_id.
CREATE OR REPLACE FUNCTION public.definir_funcionario_vinculo(
  p_funcionario_id uuid,
  p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') <> 'admin' THEN
    RAISE EXCEPTION 'Somente administradores podem vincular usuários';
  END IF;

  IF p_funcionario_id IS NULL THEN
    RAISE EXCEPTION 'Selecione um funcionário';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.funcionarios WHERE id = p_funcionario_id) THEN
    RAISE EXCEPTION 'Funcionário não encontrado';
  END IF;

  IF p_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'Usuário não encontrado';
  END IF;

  -- Um usuário só pode estar vinculado a um funcionário (índice único parcial).
  -- Ao (re)vincular, libera o usuário de qualquer outro funcionário.
  UPDATE public.funcionarios
  SET user_id = NULL
  WHERE user_id = p_user_id
    AND id <> p_funcionario_id;

  UPDATE public.funcionarios
  SET user_id = p_user_id
  WHERE id = p_funcionario_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.listar_checklists_portaria()
RETURNS TABLE (
  id bigint,
  motorista_id uuid,
  motorista_nome text,
  veiculo_id bigint,
  veiculo_placa text,
  veiculo_modelo text,
  data timestamptz,
  itens_nao_ok integer,
  itens_nao_ok_detalhes jsonb,
  observacoes text,
  fotos jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles AS profile
  WHERE profile.id = auth.uid();

  IF COALESCE(v_role, '') NOT IN ('admin', 'porteiro') THEN
    RAISE EXCEPTION 'Sem permissão para consultar checklists da portaria';
  END IF;

  RETURN QUERY
  SELECT c.id, c.motorista_id, c.motorista_nome, c.veiculo_id,
         COALESCE(c.veiculo_placa, v.placa), v.modelo, c.data,
         c.itens_nao_ok, c.itens_nao_ok_detalhes, c.observacoes, c.fotos
  FROM public.checklists c
  LEFT JOIN public.veiculos v ON v.id = c.veiculo_id
  WHERE c.status_portaria = 'Aguardando'
  ORDER BY c.data ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.validar_checklist_portaria(
  p_checklist_id bigint,
  p_criar_os boolean,
  p_grupo_id uuid DEFAULT NULL,
  p_prioridade text DEFAULT NULL,
  p_descricao text DEFAULT NULL,
  p_observacao_portaria text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_status text;
  v_itens_nao_ok integer;
  v_motorista_id uuid;
  v_motorista_nome text;
  v_funcionario_id uuid;
  v_veiculo_id bigint;
  v_ordem_id uuid;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') NOT IN ('admin', 'porteiro') THEN
    RAISE EXCEPTION 'Sem permissão para validar checklist';
  END IF;

  SELECT status_portaria, itens_nao_ok, motorista_id, motorista_nome, veiculo_id
  INTO v_status, v_itens_nao_ok, v_motorista_id, v_motorista_nome, v_veiculo_id
  FROM public.checklists
  WHERE id = p_checklist_id
  FOR UPDATE;

  IF NOT FOUND OR v_status <> 'Aguardando' THEN
    RAISE EXCEPTION 'Checklist não encontrado ou já validado';
  END IF;
  IF p_criar_os IS NULL THEN
    RAISE EXCEPTION 'Informe o resultado da vistoria';
  END IF;
  IF NOT p_criar_os AND COALESCE(v_itens_nao_ok, 0) > 0
     AND NULLIF(trim(p_observacao_portaria), '') IS NULL THEN
    RAISE EXCEPTION 'Registre por que a avaria não foi confirmada';
  END IF;

  IF p_criar_os THEN
    IF COALESCE(v_itens_nao_ok, 0) <= 0 THEN
      RAISE EXCEPTION 'Não há avarias no checklist para gerar uma OS';
    END IF;
    IF v_veiculo_id IS NULL OR p_grupo_id IS NULL
       OR NULLIF(trim(p_prioridade), '') IS NULL
       OR NULLIF(trim(p_descricao), '') IS NULL THEN
      RAISE EXCEPTION 'Veículo, grupo, prioridade e descrição são obrigatórios';
    END IF;

    -- Resolve o funcionário (RH) vinculado ao autor do checklist (coluna canônica)
    SELECT f.id INTO v_funcionario_id
    FROM public.funcionarios f
    WHERE f.user_id = v_motorista_id
    LIMIT 1;

    INSERT INTO public.ordens_servico (
      checklist_id, funcionario_id, motorista_nome, veiculo_id, porteiro_id,
      grupo_id, prioridade, descricao, status
    ) VALUES (
      p_checklist_id, v_funcionario_id, v_motorista_nome, v_veiculo_id, auth.uid(),
      p_grupo_id, trim(p_prioridade), trim(p_descricao), 'Pendente'
    ) RETURNING id INTO v_ordem_id;
  END IF;

  UPDATE public.checklists
  SET status_portaria = CASE WHEN p_criar_os THEN 'Encaminhado' ELSE 'Validado' END,
      validado_por = auth.uid(),
      validado_em = now(),
      observacao_portaria = p_observacao_portaria
  WHERE id = p_checklist_id;

  RETURN v_ordem_id;
END;
$$;

DROP FUNCTION IF EXISTS public.finalizar_ordem_servico(uuid, uuid, text, jsonb);

DROP FUNCTION IF EXISTS public.registrar_saida_estoque_os(uuid, uuid, jsonb);

CREATE OR REPLACE FUNCTION public.registrar_saida_estoque_os(
  p_ordem_id uuid,
  p_mecanicos jsonb,
  p_itens jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_status text;
  v_mecanico_id uuid;
  v_mecanico_nome text;
  v_saldo numeric(12, 3);
  v_custo_medio numeric(14, 4);
  v_item record;
  v_mecanico jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') NOT IN ('admin', 'manutencao') THEN
    RAISE EXCEPTION 'Sem permissão para liberar peças para ordem de serviço';
  END IF;
  IF COALESCE(jsonb_typeof(p_itens), '') <> 'array'
    OR COALESCE(jsonb_typeof(p_mecanicos), '') <> 'array' THEN
    RAISE EXCEPTION 'As listas de mecânicos e peças devem ser arrays';
  END IF;
  IF jsonb_array_length(p_mecanicos) = 0 THEN
    RAISE EXCEPTION 'Associe pelo menos um mecânico à ordem de serviço';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_mecanicos) AS item
    GROUP BY item->>'funcionario_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Não repita o mesmo mecânico na equipe da OS';
  END IF;

  SELECT status INTO v_status
  FROM public.ordens_servico
  WHERE id = p_ordem_id
  FOR UPDATE;

  IF NOT FOUND OR v_status <> 'Pendente' THEN
    RAISE EXCEPTION 'Ordem não encontrada ou já concluída';
  END IF;

  v_mecanico_id := (p_mecanicos->0->>'funcionario_id')::uuid;
  SELECT nome_funcionario INTO v_mecanico_nome
  FROM public.funcionarios
  WHERE id = v_mecanico_id AND is_mecanico;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selecione mecânicos ativos no cadastro de funcionários';
  END IF;

  FOR v_mecanico IN SELECT value FROM jsonb_array_elements(p_mecanicos)
  LOOP
    IF COALESCE(trim(v_mecanico->>'especialidade'), '') = '' THEN
      RAISE EXCEPTION 'Informe a especialidade de cada mecânico';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.funcionarios
      WHERE id = (v_mecanico->>'funcionario_id')::uuid AND is_mecanico
    ) THEN
      RAISE EXCEPTION 'Um dos funcionários selecionados não está marcado como mecânico';
    END IF;

    INSERT INTO public.ordens_servico_mecanicos (
      ordem_servico_id, funcionario_id, especialidade
    ) VALUES (
      p_ordem_id,
      (v_mecanico->>'funcionario_id')::uuid,
      trim(v_mecanico->>'especialidade')
    )
    ON CONFLICT (ordem_servico_id, funcionario_id)
    DO UPDATE SET especialidade = EXCLUDED.especialidade;
  END LOOP;

  FOR v_item IN
    SELECT (item->>'peca_id')::bigint AS peca_id,
           sum((item->>'quantidade')::numeric) AS quantidade
    FROM jsonb_array_elements(p_itens) AS item
    GROUP BY (item->>'peca_id')::bigint
    ORDER BY (item->>'peca_id')::bigint
  LOOP
    IF v_item.quantidade <= 0 THEN
      RAISE EXCEPTION 'Quantidade de peça inválida';
    END IF;

    SELECT saldo_estoque, custo_medio
    INTO v_saldo, v_custo_medio
    FROM public.pecas
    WHERE id = v_item.peca_id AND ativo
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Peça % não encontrada ou inativa', v_item.peca_id;
    END IF;
    IF v_saldo < v_item.quantidade THEN
      RAISE EXCEPTION 'Estoque insuficiente para a peça % (saldo: %, solicitado: %)',
        v_item.peca_id, v_saldo, v_item.quantidade;
    END IF;

    INSERT INTO public.itens_ordem_servico (
      ordem_servico_id, peca_id, quantidade, quantidade_utilizada, custo_unitario,
      mecanico_id, liberado_por, liberado_em
    ) VALUES (
      p_ordem_id, v_item.peca_id, v_item.quantidade, 0, v_custo_medio,
      v_mecanico_id, auth.uid(), now()
    );

    UPDATE public.pecas
    SET saldo_estoque = saldo_estoque - v_item.quantidade,
        updated_at = now()
    WHERE id = v_item.peca_id;

    INSERT INTO public.movimentacoes_estoque (
      peca_id, tipo, quantidade, custo_unitario, ordem_servico_id, usuario_id, observacao
    ) VALUES (
      v_item.peca_id, 'saida', v_item.quantidade, v_custo_medio,
      p_ordem_id, auth.uid(), 'Peça liberada para mecânico na ordem de serviço'
    );
  END LOOP;

  UPDATE public.ordens_servico
  SET mecanico_id = v_mecanico_id,
      mecanico = v_mecanico_nome
  WHERE id = p_ordem_id;
END;
$$;

DROP FUNCTION IF EXISTS public.finalizar_ordem_servico(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.finalizar_ordem_servico(
  p_ordem_id uuid,
  p_obs text,
  p_itens jsonb DEFAULT '[]'::jsonb,
  p_mecanicos jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_status text;
  v_item record;
  v_mecanico_id uuid;
  v_quantidade_utilizada numeric(12, 3);
  v_quantidade_devolvida numeric(12, 3);
  v_mecanico jsonb;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') NOT IN ('admin', 'manutencao') THEN
    RAISE EXCEPTION 'Sem permissão para concluir ordem de serviço';
  END IF;
  IF COALESCE(jsonb_typeof(p_itens), '') <> 'array'
    OR COALESCE(jsonb_typeof(p_mecanicos), '') <> 'array' THEN
    RAISE EXCEPTION 'As listas de mecânicos e peças devem ser arrays';
  END IF;

  SELECT status, mecanico_id INTO v_status, v_mecanico_id
  FROM public.ordens_servico
  WHERE id = p_ordem_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ordem de serviço não encontrada';
  END IF;
  IF v_status <> 'Pendente' THEN
    RAISE EXCEPTION 'Somente OS liberadas pela portaria podem ser concluídas';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.ordens_servico_mecanicos
    WHERE ordem_servico_id = p_ordem_id
  ) THEN
    RAISE EXCEPTION 'Associe pelo menos um mecânico à OS no Almoxarifado antes de concluir';
  END IF;
  IF jsonb_array_length(p_mecanicos) = 0 OR EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_mecanicos) AS item
    GROUP BY item->>'funcionario_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Informe o período trabalhado de cada mecânico da equipe';
  END IF;
  IF jsonb_array_length(p_mecanicos) <> (
    SELECT count(*) FROM public.ordens_servico_mecanicos
    WHERE ordem_servico_id = p_ordem_id
  ) THEN
    RAISE EXCEPTION 'Informe o período de todos os mecânicos associados à OS';
  END IF;

  FOR v_mecanico IN SELECT value FROM jsonb_array_elements(p_mecanicos)
  LOOP
    IF NULLIF(v_mecanico->>'inicio_em', '') IS NULL
      OR NULLIF(v_mecanico->>'fim_em', '') IS NULL
      OR (v_mecanico->>'fim_em')::timestamptz <= (v_mecanico->>'inicio_em')::timestamptz THEN
      RAISE EXCEPTION 'Informe início e fim válidos para cada mecânico';
    END IF;

    UPDATE public.ordens_servico_mecanicos
    SET inicio_em = (v_mecanico->>'inicio_em')::timestamptz,
        fim_em = (v_mecanico->>'fim_em')::timestamptz
    WHERE ordem_servico_id = p_ordem_id
      AND funcionario_id = (v_mecanico->>'funcionario_id')::uuid;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Um mecânico informado não está associado a esta OS';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_itens) AS item
    LEFT JOIN public.itens_ordem_servico liberado
      ON liberado.id = (item->>'item_id')::bigint
     AND liberado.ordem_servico_id = p_ordem_id
    WHERE liberado.id IS NULL
  ) THEN
    RAISE EXCEPTION 'A confirmação contém peça não liberada para esta OS';
  END IF;

  FOR v_item IN
    SELECT id, peca_id, quantidade, custo_unitario
    FROM public.itens_ordem_servico
    WHERE ordem_servico_id = p_ordem_id
    ORDER BY id
    FOR UPDATE
  LOOP
    SELECT COALESCE(sum((item->>'quantidade_utilizada')::numeric), 0)
    INTO v_quantidade_utilizada
    FROM jsonb_array_elements(p_itens) AS item
    WHERE (item->>'item_id')::bigint = v_item.id;

    IF v_quantidade_utilizada < 0 OR v_quantidade_utilizada > v_item.quantidade THEN
      RAISE EXCEPTION 'Quantidade utilizada inválida para o item %', v_item.id;
    END IF;

    v_quantidade_devolvida := v_item.quantidade - v_quantidade_utilizada;
    UPDATE public.itens_ordem_servico
    SET quantidade_utilizada = v_quantidade_utilizada,
        confirmado_por = auth.uid(),
        confirmado_em = now()
    WHERE id = v_item.id;

    IF v_quantidade_devolvida > 0 THEN
      UPDATE public.pecas
      SET saldo_estoque = saldo_estoque + v_quantidade_devolvida,
          updated_at = now()
      WHERE id = v_item.peca_id;

      INSERT INTO public.movimentacoes_estoque (
        peca_id, tipo, quantidade, custo_unitario, ordem_servico_id, usuario_id, observacao
      ) VALUES (
        v_item.peca_id, 'entrada', v_quantidade_devolvida, v_item.custo_unitario,
        p_ordem_id, auth.uid(), 'Devolução de peça não utilizada na ordem de serviço'
      );
    END IF;
  END LOOP;

  UPDATE public.ordens_servico
  SET status = 'Concluída',
      obs_manutencao = p_obs,
      data_conclusao = now()
  WHERE id = p_ordem_id;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_entrada_estoque(bigint, numeric, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.definir_funcionario_mecanico(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_usuarios_app() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.definir_funcionario_vinculo(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_checklists_portaria() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.validar_checklist_portaria(bigint, boolean, uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_saida_estoque_os(uuid, jsonb, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.finalizar_ordem_servico(uuid, text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_entrada_estoque(bigint, numeric, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.definir_funcionario_mecanico(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_usuarios_app() TO authenticated;
GRANT EXECUTE ON FUNCTION public.definir_funcionario_vinculo(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_checklists_portaria() TO authenticated;
GRANT EXECUTE ON FUNCTION public.validar_checklist_portaria(bigint, boolean, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_saida_estoque_os(uuid, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_ordem_servico(uuid, text, jsonb, jsonb) TO authenticated;

-- Necessário apenas se a leitura de funcionarios for por coluna (grants coluna a coluna).
GRANT SELECT (user_id) ON public.funcionarios TO authenticated;

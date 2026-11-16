ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check
  CHECK (role = ANY (ARRAY['motorista', 'admin', 'porteiro', 'manutencao']));

ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS is_mecanico boolean NOT NULL DEFAULT false;

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

ALTER TABLE public.pecas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.itens_ordem_servico ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movimentacoes_estoque ENABLE ROW LEVEL SECURITY;

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

REVOKE INSERT, UPDATE ON public.pecas FROM authenticated;
GRANT SELECT ON public.pecas TO authenticated;
GRANT SELECT ON public.ordens_servico TO authenticated;
GRANT INSERT (codigo, nome, descricao, unidade, estoque_minimo)
  ON public.pecas TO authenticated;
GRANT UPDATE (codigo, nome, descricao, unidade, estoque_minimo, ativo, updated_at)
  ON public.pecas TO authenticated;
GRANT SELECT ON public.itens_ordem_servico, public.movimentacoes_estoque TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.itens_ordem_servico, public.movimentacoes_estoque FROM authenticated;
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

    INSERT INTO public.ordens_servico (
      checklist_id, motorista_id, motorista_nome, veiculo_id, porteiro_id,
      grupo_id, prioridade, descricao, status
    ) VALUES (
      p_checklist_id, v_motorista_id, v_motorista_nome, v_veiculo_id, auth.uid(),
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

CREATE OR REPLACE FUNCTION public.finalizar_ordem_servico(
  p_ordem_id uuid,
  p_mecanico_id uuid,
  p_obs text,
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
  v_mecanico_nome text;
  v_item record;
  v_saldo numeric(12, 3);
  v_custo_medio numeric(14, 4);
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') NOT IN ('admin', 'manutencao') THEN
    RAISE EXCEPTION 'Sem permissão para concluir ordem de serviço';
  END IF;
  IF jsonb_typeof(p_itens) <> 'array' THEN
    RAISE EXCEPTION 'A lista de peças deve ser um array';
  END IF;

  SELECT status INTO v_status
  FROM public.ordens_servico
  WHERE id = p_ordem_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ordem de serviço não encontrada';
  END IF;
  IF v_status <> 'Pendente' THEN
    RAISE EXCEPTION 'Somente OS liberadas pela portaria podem ser concluídas';
  END IF;

  SELECT nome_funcionario INTO v_mecanico_nome
  FROM public.funcionarios
  WHERE id = p_mecanico_id AND is_mecanico;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selecione um mecânico ativo no cadastro de funcionários';
  END IF;

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
      ordem_servico_id, peca_id, quantidade, custo_unitario
    ) VALUES (
      p_ordem_id, v_item.peca_id, v_item.quantidade, v_custo_medio
    );

    UPDATE public.pecas
    SET saldo_estoque = saldo_estoque - v_item.quantidade,
        updated_at = now()
    WHERE id = v_item.peca_id;

    INSERT INTO public.movimentacoes_estoque (
      peca_id, tipo, quantidade, custo_unitario, ordem_servico_id, usuario_id, observacao
    ) VALUES (
      v_item.peca_id, 'saida', v_item.quantidade, v_custo_medio,
      p_ordem_id, auth.uid(), 'Consumo na ordem de serviço'
    );
  END LOOP;

  UPDATE public.ordens_servico
  SET status = 'Concluída',
      mecanico_id = p_mecanico_id,
      mecanico = v_mecanico_nome,
      obs_manutencao = p_obs,
      data_conclusao = now()
  WHERE id = p_ordem_id;
END;
$$;

REVOKE ALL ON FUNCTION public.registrar_entrada_estoque(bigint, numeric, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.definir_funcionario_mecanico(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.listar_checklists_portaria() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.validar_checklist_portaria(bigint, boolean, uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.finalizar_ordem_servico(uuid, uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_entrada_estoque(bigint, numeric, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.definir_funcionario_mecanico(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.listar_checklists_portaria() TO authenticated;
GRANT EXECUTE ON FUNCTION public.validar_checklist_portaria(bigint, boolean, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_ordem_servico(uuid, uuid, text, jsonb) TO authenticated;
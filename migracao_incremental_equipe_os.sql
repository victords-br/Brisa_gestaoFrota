-- Migração incremental para uma instalação que já possui o módulo de almoxarifado.
-- Não repete backfills de checklists nem de itens de estoque do script completo.
-- IMPORTANTE: execute os blocos numerados separadamente no SQL Editor.
-- Não selecione nem execute o arquivo inteiro de uma vez.

-- ETAPA 1: coluna, tabela, índice, RLS e permissões.
ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS funcionarios_user_id_uidx
  ON public.funcionarios (user_id)
  WHERE user_id IS NOT NULL;

GRANT SELECT (user_id) ON public.funcionarios TO authenticated;

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

ALTER TABLE public.ordens_servico_mecanicos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ordens_servico_mecanicos_manutencao_select
  ON public.ordens_servico_mecanicos;
CREATE POLICY ordens_servico_mecanicos_manutencao_select
  ON public.ordens_servico_mecanicos
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

REVOKE ALL ON public.ordens_servico_mecanicos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.ordens_servico_mecanicos TO authenticated;

-- ETAPA 2: RPCs de vínculo de funcionário e validação de checklist.
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
  IF p_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Usuário não encontrado';
  END IF;

  UPDATE public.funcionarios
  SET user_id = NULL
  WHERE user_id = p_user_id
    AND id <> p_funcionario_id;

  UPDATE public.funcionarios
  SET user_id = p_user_id
  WHERE id = p_funcionario_id;
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

-- ETAPA 3: substitui a liberação de peças para aceitar uma equipe.
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

-- ETAPA 4: registra início/fim dos mecânicos e conclui a OS.
DROP FUNCTION IF EXISTS public.finalizar_ordem_servico(uuid, uuid, text, jsonb);
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

  -- Toda peça liberada precisa ter a quantidade utilizada confirmada explicitamente.
  -- Impede concluir a OS apenas com as horas do mecânico, devolvendo peças sem conferência.
  IF EXISTS (
    SELECT 1
    FROM public.itens_ordem_servico liberado
    WHERE liberado.ordem_servico_id = p_ordem_id
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_itens) AS item
        WHERE (item->>'item_id')::bigint = liberado.id
          AND NULLIF(item->>'quantidade_utilizada', '') IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'Confirme a quantidade utilizada de todas as peças liberadas antes de concluir a OS';
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

REVOKE ALL ON FUNCTION public.listar_usuarios_app() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.definir_funcionario_vinculo(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.validar_checklist_portaria(bigint, boolean, uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_saida_estoque_os(uuid, jsonb, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.finalizar_ordem_servico(uuid, text, jsonb, jsonb) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.listar_usuarios_app() TO authenticated;
GRANT EXECUTE ON FUNCTION public.definir_funcionario_vinculo(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.validar_checklist_portaria(bigint, boolean, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_saida_estoque_os(uuid, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_ordem_servico(uuid, text, jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

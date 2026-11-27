-- Migração incremental: obriga a confirmação da quantidade utilizada de TODAS as peças
-- liberadas antes de concluir a OS.
--
-- Motivo: a versão anterior da RPC percorria as peças liberadas e, para as que não
-- vinham na confirmação, assumia quantidade utilizada = 0 e devolvia a peça inteira
-- ao estoque. Isso permitia concluir a OS informando apenas as horas do mecânico,
-- sem que ninguém conferisse as peças.
--
-- A assinatura da função não muda, então basta substituir o corpo.
-- Pode ser executado novamente com segurança.

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

REVOKE ALL ON FUNCTION public.finalizar_ordem_servico(uuid, text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finalizar_ordem_servico(uuid, text, jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Migração incremental: funções da oficina (Eletricista, Chapista, ...).
-- Para bancos que já executaram migracao_incremental_equipe_os.sql.
-- IMPORTANTE: execute os blocos numerados separadamente no SQL Editor,
-- na ordem, e não o arquivo inteiro de uma vez.

-- ETAPA 1: tabela de funções, vínculo do funcionário e compatibilidade legada.
CREATE TABLE IF NOT EXISTS public.funcoes_oficina (
  id bigserial PRIMARY KEY,
  nome text NOT NULL UNIQUE,
  ativo boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT funcoes_oficina_nome_check CHECK (length(trim(nome)) > 0)
);

INSERT INTO public.funcoes_oficina (nome) VALUES
  ('Mecânico'),
  ('Eletricista'),
  ('Chapista'),
  ('Funileiro'),
  ('Borracheiro'),
  ('Soldador')
ON CONFLICT (nome) DO NOTHING;

ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS funcao_id bigint REFERENCES public.funcoes_oficina (id) ON DELETE SET NULL;

-- Mantém a coluna antiga enquanto policies/RPCs legadas ainda puderem usá-la.
ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS is_mecanico boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS funcionarios_funcao_idx
  ON public.funcionarios (funcao_id);

UPDATE public.funcionarios
SET funcao_id = (SELECT id FROM public.funcoes_oficina WHERE nome = 'Mecânico')
WHERE funcao_id IS NULL AND is_mecanico;

UPDATE public.funcionarios
SET is_mecanico = (funcao_id IS NOT NULL)
WHERE is_mecanico IS DISTINCT FROM (funcao_id IS NOT NULL);

CREATE OR REPLACE FUNCTION public.sincronizar_flag_mecanico_legado()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.is_mecanico := NEW.funcao_id IS NOT NULL;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS funcionarios_sincronizar_flag_mecanico
  ON public.funcionarios;
CREATE TRIGGER funcionarios_sincronizar_flag_mecanico
  BEFORE INSERT OR UPDATE OF funcao_id ON public.funcionarios
  FOR EACH ROW
  EXECUTE FUNCTION public.sincronizar_flag_mecanico_legado();

REVOKE ALL ON FUNCTION public.sincronizar_flag_mecanico_legado() FROM PUBLIC, anon, authenticated;

ALTER TABLE public.funcoes_oficina ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS funcoes_oficina_manutencao_select ON public.funcoes_oficina;
CREATE POLICY funcoes_oficina_manutencao_select ON public.funcoes_oficina
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role IN ('admin', 'manutencao')
  ));

REVOKE ALL ON public.funcoes_oficina FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.funcoes_oficina TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.funcoes_oficina_id_seq TO authenticated;
GRANT SELECT (funcao_id) ON public.funcionarios TO authenticated;
GRANT SELECT (is_mecanico) ON public.funcionarios TO authenticated;

-- ETAPA 2: RPCs de função de oficina.
DROP FUNCTION IF EXISTS public.definir_funcionario_mecanico(uuid, boolean);

CREATE OR REPLACE FUNCTION public.definir_funcionario_funcao(
  p_funcionario_id uuid,
  p_funcao_id bigint
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
    RAISE EXCEPTION 'Somente administradores podem gerenciar a equipe da manutenção';
  END IF;
  IF p_funcionario_id IS NULL THEN
    RAISE EXCEPTION 'Selecione um funcionário';
  END IF;
  IF p_funcao_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.funcoes_oficina WHERE id = p_funcao_id AND ativo
  ) THEN
    RAISE EXCEPTION 'Função de oficina não encontrada';
  END IF;

  UPDATE public.funcionarios
  SET funcao_id = p_funcao_id
  WHERE id = p_funcionario_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Funcionário não encontrado';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.criar_funcao_oficina(p_nome text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_role text;
  v_id bigint;
  v_nome text;
BEGIN
  SELECT role INTO v_role
  FROM public.profiles
  WHERE id = auth.uid();

  IF COALESCE(v_role, '') <> 'admin' THEN
    RAISE EXCEPTION 'Somente administradores podem cadastrar funções de oficina';
  END IF;

  v_nome := NULLIF(trim(p_nome), '');
  IF v_nome IS NULL THEN
    RAISE EXCEPTION 'Informe o nome da função';
  END IF;

  INSERT INTO public.funcoes_oficina (nome)
  VALUES (v_nome)
  ON CONFLICT (nome) DO UPDATE SET ativo = true
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.definir_funcionario_funcao(uuid, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.criar_funcao_oficina(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.definir_funcionario_funcao(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.criar_funcao_oficina(text) TO authenticated;

-- ETAPA 3: liberação de peças passa a aceitar qualquer função de oficina.
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
  WHERE id = v_mecanico_id AND funcao_id IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selecione funcionários da equipe da manutenção';
  END IF;

  FOR v_mecanico IN SELECT value FROM jsonb_array_elements(p_mecanicos)
  LOOP
    IF COALESCE(trim(v_mecanico->>'especialidade'), '') = '' THEN
      RAISE EXCEPTION 'Informe a especialidade de cada mecânico';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.funcionarios
      WHERE id = (v_mecanico->>'funcionario_id')::uuid AND funcao_id IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'Um dos funcionários selecionados não pertence à equipe da manutenção';
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

REVOKE ALL ON FUNCTION public.registrar_saida_estoque_os(uuid, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_saida_estoque_os(uuid, jsonb, jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Reparo para bancos que ja removeram funcionarios.is_mecanico.
-- Recria a coluna usada por policies/RPCs legadas e sincroniza-a com funcao_id.
-- Execute uma vez no Supabase depois da ETAPA 1 da migracao de funcoes da oficina.

ALTER TABLE public.funcionarios
  ADD COLUMN IF NOT EXISTS is_mecanico boolean NOT NULL DEFAULT false;

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

REVOKE ALL ON FUNCTION public.sincronizar_flag_mecanico_legado()
  FROM PUBLIC, anon, authenticated;
GRANT SELECT (is_mecanico) ON public.funcionarios TO authenticated;

NOTIFY pgrst, 'reload schema';

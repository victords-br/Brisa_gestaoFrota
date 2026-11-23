-- Execute depois da ETAPA 1 de migracao_incremental_equipe_os.sql.
-- Opcional: importa o mecânico principal de OS pendentes existentes.
-- Pode ser executado novamente com segurança.
INSERT INTO public.ordens_servico_mecanicos (ordem_servico_id, funcionario_id)
SELECT os.id, os.mecanico_id
FROM public.ordens_servico os
WHERE os.status = 'Pendente'
  AND os.mecanico_id IS NOT NULL
ON CONFLICT (ordem_servico_id, funcionario_id) DO NOTHING;

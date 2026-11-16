// ============================================
// CONFIGURAÇÃO DO SUPABASE
// ============================================
(function () {
  if (typeof window.supabase === 'undefined') {
    console.error('❌ CDN do Supabase não carregado. Confira o Head Content.');
    return;
  }

  const SUPABASE_URL = 'https://lzhonlgoumadhdnyhzqm.supabase.co';
  const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx6aG9ubGdvdW1hZGhkbnloenFtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwOTA2ODQsImV4cCI6MjEwNzY2NjY4NH0.RJ2ehWCoU-XdqvpFHaEjCWe-BqJ4sBSVWE-Sog4KWGA';

  const { createClient } = window.supabase;
  window.db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  console.log('✅ Supabase conectado com sucesso.');

  // ---- Número de WhatsApp de destino ----
  window.WHATSAPP_DESTINO = '5573981747651'; // ← troque pelo seu número

  // ---- Itens do checklist ----
  window.ITENS_CHECKLIST = [
    { id: 'farol',        label: 'Faróis (baixo e alto) funcionando' },
    { id: 'lanterna',     label: 'Lanternas traseiras funcionando' },
    { id: 'freio_luz',    label: 'Luz de freio funcionando' },
    { id: 're',           label: 'Luz de ré funcionando' },
    { id: 'seta',         label: 'Setas / pisca funcionando' },
    { id: 'pisca_alerta', label: 'Pisca-alerta funcionando' },
    { id: 'buzina',       label: 'Buzina funcionando' },
    { id: 'pneus',        label: 'Pneus em bom estado e calibrados' },
    { id: 'estepe',       label: 'Estepe presente e em bom estado' },
    { id: 'lataria',      label: 'Lataria sem danos aparentes' },
    { id: 'retrovisor',   label: 'Retrovisores íntegros e ajustados' },
    { id: 'parabrisa',    label: 'Para-brisa sem trincas' },
    { id: 'limpador',     label: 'Limpador de para-brisa funcionando' },
    { id: 'placa',        label: 'Placas legíveis e fixadas' },
    { id: 'cintos',       label: 'Cintos de segurança funcionando' },
    { id: 'extintor',     label: 'Extintor na validade' },
    { id: 'triangulo',    label: 'Triângulo de sinalização presente' },
    { id: 'documento',    label: 'Documentação em dia' },
    { id: 'oleo',         label: 'Nível de óleo adequado' },
    { id: 'agua',         label: 'Nível de água do radiador adequado' },
    { id: 'combustivel',  label: 'Combustível suficiente' },
    { id: 'freio',        label: 'Freios funcionando' }
  ];

  // ---- Flag persistente (não depende de evento) ----
  window.__SUPABASE_PRONTO__ = true;

  // ---- Dispara o evento (compatibilidade) ----
  window.dispatchEvent(new Event('supabase-ready'));
})();
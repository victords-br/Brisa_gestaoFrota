// ============================================
// CHECKLIST VEICULAR (motorista)
// ============================================
(async function () {
  console.log('🟢 checklist.js iniciado');

  // ---- Espera o Supabase estar disponível ----
  let tentativas = 0;
  while (!window.db && tentativas < 50) {
    await new Promise(r => setTimeout(r, 100));
    tentativas++;
  }

  if (!window.db) {
    console.error('❌ Supabase não ficou disponível.');
    return;
  }

  // ---- Verifica sessão ----
  const { data: { session } } = await window.db.auth.getSession();
  if (!session) {
    window.location.replace('login.html');
    return;
  }

  const USUARIO = session.user;

  // ---- Pega perfil ----
  const { data: perfil } = await window.db
    .from('profiles')
    .select('nome, role')
    .eq('id', USUARIO.id)
    .single();

  const PERFIL = perfil || { nome: USUARIO.email, role: 'motorista' };
  document.getElementById('nome-motorista').textContent = PERFIL.nome;

  // ---- Função para encurtar URL ----
  async function encurtarUrl(urlLonga) {
    try {
      const resp = await fetch(`https://is.gd/create.php?format=simple&url=${encodeURIComponent(urlLonga)}`);
      if (resp.ok) {
        const link = (await resp.text()).trim();
        if (link && link.startsWith('http')) return link;
      }
    } catch (e) { /* fallback abaixo */ }
    return urlLonga;
  }

  // ---- Carrega veículos ----
  async function carregarVeiculos() {
    const { data, error } = await window.db.from('veiculos').select('*').order('placa');
    const sel = document.getElementById('veiculo');

    if (error || !data || data.length === 0) {
      sel.innerHTML = '<option value="">Nenhum veículo cadastrado</option>';
      return;
    }

    sel.innerHTML = '<option value="">Selecione o veículo...</option>' +
      data.map(v => `<option value="${v.id}" data-placa="${v.placa}">${v.placa} — ${v.modelo}</option>`).join('');
  }

  // ---- Renderiza itens ----
  function renderItens() {
    const container = document.getElementById('itens-checklist');
    container.className = "d-flex flex-column gap-2";
    container.innerHTML = window.ITENS_CHECKLIST.map(item => `
      <div class="item-checklist shadow-sm border-0 bg-white p-3">
        <span class="fw-bold text-secondary mb-2 tex mb-sm-0 list">${item.label}</span>
        <div class="btn-group btn-check-group" role="group">
          <input type="radio" class="btn-check" name="${item.id}" id="${item.id}_ok" value="ok" checked autocomplete="off">
          <label class="btn btn-outline-success border-2" for="${item.id}_ok">
            <i class="bi bi-check2-circle me-1"></i> OK
          </label>

          <input type="radio" class="btn-check" name="${item.id}" id="${item.id}_nok" value="nao_ok" autocomplete="off">
          <label class="btn btn-outline-danger border-2" for="${item.id}_nok">
            <i class="bi bi-x-circle me-1"></i> Falha
          </label>
        </div>
      </div>
    `).join('');
  }

  // ---- Preview de fotos ----
  document.getElementById('fotos').addEventListener('change', (e) => {
    const preview = document.getElementById('preview-fotos');
    preview.innerHTML = '';
    Array.from(e.target.files).forEach(file => {
      const reader = new FileReader();
      reader.onload = (ev) => {
        const img = document.createElement('img');
        img.src = ev.target.result;
        preview.appendChild(img);
      };
      reader.readAsDataURL(file);
    });
  });

  // ---- Envio do checklist ----
  document.getElementById('form-checklist').addEventListener('submit', async (e) => {
    e.preventDefault();

    const msg = document.getElementById('msg');
    const btn = document.getElementById('btn-enviar');

    btn.disabled = true;
    btn.textContent = 'Enviando...';
    msg.className = 'text-center mt-3';
    msg.textContent = '';

    try {
      const sel = document.getElementById('veiculo');
      const veiculoId = sel.value;
      const veiculoPlaca = sel.options[sel.selectedIndex]?.dataset.placa || '';
      const observacoes = document.getElementById('observacoes').value.trim();

      if (!veiculoId) throw new Error('Selecione um veículo.');

      let ok = 0, naoOk = 0;
      const problemas = [];

      window.ITENS_CHECKLIST.forEach(item => {
        const checked = document.querySelector(`input[name="${item.id}"]:checked`);
        if (checked && checked.value === 'ok') ok++;
        else { naoOk++; problemas.push(item.label); }
      });

      // ---- Upload de fotos ----
      const arquivos = document.getElementById('fotos').files;
      const urlsFotos = [];
      const stamp = Date.now();
      let contador = 1;

      for (const arq of arquivos) {
        const ext = arq.name.split('.').pop() || 'jpg';
        const nomeCurto = `${stamp}_foto${contador}.${ext}`;
        const caminho = `${USUARIO.id}/${nomeCurto}`;
        contador++;

        const { error: errUp } = await window.db.storage
          .from('fotos-checklist')
          .upload(caminho, arq, { upsert: false });

        if (!errUp) {
          const { data: urlData } = window.db.storage
            .from('fotos-checklist')
            .getPublicUrl(caminho);

          const linkCurto = await encurtarUrl(urlData.publicUrl);
          urlsFotos.push(linkCurto);
        }
      }

      // ---- Salva no banco ----
      const { error } = await window.db.from('checklists').insert([{
        motorista_id: USUARIO.id,
        motorista_nome: PERFIL.nome,
        veiculo_id: veiculoId,
        veiculo_placa: veiculoPlaca,
        itens_ok: ok,
        itens_nao_ok: naoOk,
        itens_nao_ok_detalhes: problemas,
        observacoes: observacoes,
        fotos: urlsFotos
      }]);

      if (error) throw error;

      // ---- Monta mensagem ----
      const dataHora = new Date().toLocaleString('pt-BR');
      let texto = `*CHECKLIST VEICULAR*\n\n`;
      texto += `Veículo: ${veiculoPlaca}\n`;
      texto += `Motorista: ${PERFIL.nome}\n`;
      texto += `Data: ${dataHora}\n\n`;
      texto += `Itens OK: ${ok}\n`;
      texto += `Itens Não OK: ${naoOk}\n`;

      if (problemas.length) texto += `\n*Problemas:*\n- ${problemas.join('\n- ')}\n`;
      if (observacoes) texto += `\n*Observações:* ${observacoes}\n`;
      if (urlsFotos.length) {
        texto += `\n*Fotos:*\n`;
        urlsFotos.forEach((u, i) => { texto += `📷 Foto ${i + 1}: ${u}\n`; });
      }

      const urlWhats = `https://wa.me/${window.WHATSAPP_DESTINO}?text=${encodeURIComponent(texto)}`;
      window.open(urlWhats, '_blank');

      msg.className = 'msg-sucesso text-center mt-3';
      msg.textContent = 'Checklist salvo e enviado com sucesso!';
      document.getElementById('form-checklist').reset();
      document.getElementById('preview-fotos').innerHTML = '';

      btn.disabled = false;
      btn.textContent = 'Enviar Checklist';

    } catch (err) {
      console.error(err);
      msg.className = 'msg-erro text-center mt-3';
      msg.textContent = err.message || 'Erro ao enviar checklist.';
      btn.disabled = false;
      btn.textContent = 'Enviar Checklist';
    }
  });

  // ---- Logout ----
  document.getElementById('btn-sair').addEventListener('click', async () => {
    await window.db.auth.signOut();
    window.location.replace('login.html');
  });

  // ---- Start ----
  await carregarVeiculos();
  renderItens();
})();
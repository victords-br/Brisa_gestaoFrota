// ============================================
// PORTARIA - CRIAÇÃO DE ORDENS DE SERVIÇO
// ============================================
(async function () {
  console.log('🟢 portaria.js iniciado');

  let tentativas = 0;
  while (!window.db && tentativas < 50) {
    await new Promise(r => setTimeout(r, 100));
    tentativas++;
  }

  if (!window.db) {
    console.error('❌ Supabase não conectado.');
    return;
  }

  const { data: { session } } = await window.db.auth.getSession();
  if (!session) {
    window.location.replace('login.html');
    return;
  }

  const USUARIO = session.user;
  const { data: perfil } = await window.db
    .from('profiles')
    .select('nome, role')
    .eq('id', USUARIO.id)
    .single();

  const PERFIL = perfil || { nome: USUARIO.email, role: 'porteiro' };
  if (!['admin', 'porteiro'].includes(PERFIL.role)) {
    window.location.replace(PERFIL.role === 'manutencao' ? 'dashboard.html' : 'index.html');
    return;
  }

  const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[char]);
  let gruposCache = [];
  let choicesFuncionario = null;
  document.getElementById('nome-porteiro').textContent = PERFIL.nome + ' (Portaria)';

  // ---- Carrega veículos e grupos ----
  async function carregarSelects() {
    // Veículos
    const { data: veiculos } = await window.db.from('veiculos').select('*').order('placa');
    const selVeiculo = document.getElementById('veiculo-os');
    if (veiculos && veiculos.length > 0) {
      selVeiculo.innerHTML = '<option value="">Selecione o veículo...</option>' +
        veiculos.map(v => `<option value="${v.id}" data-placa="${v.placa}">${v.placa} — ${v.modelo}</option>`).join('');
    } else {
      selVeiculo.innerHTML = '<option value="">Nenhum veículo cadastrado</option>';
    }

    // Grupos de Problemas
    const { data: grupos } = await window.db.from('grupo_problemas').select('*').order('nome');
    gruposCache = grupos || [];
    const selGrupo = document.getElementById('grupo-os');
    if (grupos && grupos.length > 0) {
      selGrupo.innerHTML = '<option value="">Selecione o grupo...</option>' +
        grupos.map(g => `<option value="${escapeHTML(g.id)}">${escapeHTML(g.nome)}</option>`).join('');
    } else {
      selGrupo.innerHTML = '<option value="">Nenhum grupo cadastrado</option>';
    }

    // Funcionários (da tabela funcionarios, colunas id, cod_funcionario e nome_funcionario)
    const { data: funcionarios } = await window.db.from('funcionarios').select('id, cod_funcionario, nome_funcionario').order('nome_funcionario');
    const selFuncionario = document.getElementById('funcionario-os');
    if (funcionarios && funcionarios.length > 0) {
      selFuncionario.innerHTML = '<option value="">Selecione o motorista ou responsável...</option>' +
        funcionarios.map(f => `<option value="${escapeHTML(f.id)}" data-nome="${escapeHTML(f.nome_funcionario)}">[${escapeHTML(f.cod_funcionario)}] ${escapeHTML(f.nome_funcionario)}</option>`).join('');
      
      // Ativa Choices.js para busca interativa no select se disponível
      if (typeof Choices !== 'undefined') {
        choicesFuncionario = new Choices(selFuncionario, {
          itemSelectText: 'Pressione para selecionar',
          noResultsText: 'Nenhum funcionário encontrado',
          noChoicesText: 'Sem funcionários',
          searchEnabled: true,
          shouldSort: false,
          removeItemButton: true
        });
      }
    } else {
      selFuncionario.innerHTML = '<option value="">Nenhum funcionário encontrado</option>';
    }
  }

  async function carregarChecklistsPortaria() {
    const tbody = document.getElementById('tabela-checklists-portaria');
    const { data: problemas, error } = await window.db.rpc('listar_checklists_portaria');

    if (error) {
      console.error('Erro ao carregar checklists para vistoria:', error);
      tbody.innerHTML = '<p class="ops-empty text-danger">Erro ao carregar checklists.</p>';
      return;
    }

    const pendentes = problemas || [];
    document.getElementById('total-checklists-portaria').textContent = pendentes.length;

    if (!pendentes.length) {
      tbody.innerHTML = '<p class="ops-empty">Nenhum checklist aguardando vistoria.</p>';
      return;
    }

    tbody.innerHTML = pendentes.map(row => {
      const fotos = Array.isArray(row.fotos) ? row.fotos : [];
      const fotosHtml = fotos.map((foto, index) => {
        try {
          const url = new URL(foto);
          if (!['http:', 'https:'].includes(url.protocol)) return '';
          return `<a class="btn btn-sm btn-outline-secondary me-1" href="${escapeHTML(url.href)}" target="_blank" rel="noopener noreferrer">Foto ${index + 1}</a>`;
        } catch {
          return '';
        }
      }).join('') || '—';
      const detalhesFalhas = Array.isArray(row.itens_nao_ok_detalhes)
        ? row.itens_nao_ok_detalhes.map(escapeHTML).join('<br>')
        : '';
      const temProblemas = Number(row.itens_nao_ok) > 0;

      return `<article class="ops-card ops-card-checklist ${temProblemas ? 'is-urgent' : 'is-pending'}">
        <header class="ops-card-header">
          <span class="ops-card-reference">Checklist #${escapeHTML(row.id)} · ${escapeHTML(new Date(row.data).toLocaleString('pt-BR'))}</span>
          <span class="ops-card-badges"><span class="badge ${temProblemas ? 'bg-danger' : 'bg-success'}">${temProblemas ? `${escapeHTML(row.itens_nao_ok)} falhas` : 'Sem falhas'}</span></span>
        </header>
        <div class="ops-card-vehicle">
          <span class="ops-card-vehicle-icon"><i class="bi bi-truck-front"></i></span>
          <div><span class="ops-card-vehicle-label">Veículo</span><strong>${escapeHTML(row.veiculo_placa || '—')} · ${escapeHTML(row.veiculo_modelo || '')}</strong></div>
        </div>
        <div class="ops-card-facts"><div class="ops-card-fact"><span class="ops-card-label">Motorista</span><strong>${escapeHTML(row.motorista_nome || '—')}</strong></div></div>
        ${detalhesFalhas ? `<p class="ops-card-description"><span class="ops-card-label">Itens apontados</span>${detalhesFalhas}</p>` : ''}
        ${row.observacoes ? `<p class="ops-card-description"><span class="ops-card-label">Observações do motorista</span>${escapeHTML(row.observacoes)}</p>` : ''}
        ${fotosHtml !== '—' ? `<div class="ops-card-photos">${fotosHtml}</div>` : ''}
        <footer class="ops-card-footer">
          <small>Aguardando vistoria da portaria</small>
          <button class="btn btn-sm btn-primary btn-validar-checklist"
            data-id="${escapeHTML(row.id)}"
            data-veiculo-id="${escapeHTML(row.veiculo_id || '')}"
            data-placa="${escapeHTML(row.veiculo_placa || '')}"
            data-motorista-id="${escapeHTML(row.motorista_id || '')}"
            data-motorista="${escapeHTML(row.motorista_nome || '')}"
            data-problemas="${escapeHTML(row.itens_nao_ok || 0)}"
            data-descricao="${escapeHTML(row.observacoes || detalhesFalhas.replace(/<br>/g, ', ') || 'Problema apontado no checklist')}">
            <i class="bi bi-search me-1"></i>Vistoriar</button>
        </footer>
      </article>`;
    }).join('');
  }

  document.getElementById('tabela-checklists-portaria').addEventListener('click', event => {
    const button = event.target.closest('.btn-validar-checklist');
    if (!button) return;
    abrirModalValidarChecklist(button.dataset);
  });

  function abrirModalValidarChecklist(checklist) {
    const temProblemas = Number(checklist.problemas) > 0;
    if (temProblemas && !gruposCache.length) {
      alert('Cadastre ao menos um grupo de problema antes de gerar a OS.');
      return;
    }

    const modalAntigo = document.getElementById('modal-validar-checklist');
    if (modalAntigo) modalAntigo.remove();
    const grupoOptions = gruposCache.map(grupo =>
      `<option value="${escapeHTML(grupo.id)}">${escapeHTML(grupo.nome)}</option>`
    ).join('');
    const modalHtml = `<div class="modal fade" id="modal-validar-checklist" tabindex="-1">
      <div class="modal-dialog modal-dialog-centered"><div class="modal-content">
        <div class="modal-header bg-primary text-white">
          <h5 class="modal-title">Validar vistoria · ${escapeHTML(checklist.placa)}</h5>
          <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
        </div>
        <form id="form-validar-checklist">
          <div class="modal-body">
            <p class="mb-3"><strong>Motorista:</strong> ${escapeHTML(checklist.motorista || '—')}</p>
            ${temProblemas ? `<div class="mb-3"><label class="form-label" for="checklist-grupo">Grupo do problema</label>
              <select class="form-select" id="checklist-grupo" required><option value="">Selecione...</option>${grupoOptions}</select></div>
              <div class="mb-3"><label class="form-label" for="checklist-prioridade">Prioridade</label>
                <select class="form-select" id="checklist-prioridade"><option>Normal</option><option>Urgente</option><option>Imediata (Veículo Parado)</option></select></div>
              <div class="mb-3"><label class="form-label" for="checklist-descricao">Descrição confirmada na vistoria</label>
                <textarea class="form-control" id="checklist-descricao" rows="4" required>${escapeHTML(checklist.descricao)}</textarea></div>`
              : '<p class="alert alert-success">Nenhuma avaria foi apontada. A vistoria pode ser encerrada sem OS.</p>'}
            <div><label class="form-label" for="checklist-obs-portaria">Observação da portaria</label>
              <textarea class="form-control" id="checklist-obs-portaria" rows="2"></textarea></div>
          </div>
          <div class="modal-footer"><button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Voltar</button>
            ${temProblemas ? '<button type="button" class="btn btn-outline-secondary" id="btn-validar-sem-os">Não constatado</button>' : ''}
            <button type="submit" class="btn btn-primary" id="btn-confirmar-vistoria">${temProblemas ? 'Confirmar e encaminhar à manutenção' : 'Validar checklist'}</button></div>
        </form>
      </div></div>
    </div>`;
    document.body.insertAdjacentHTML('beforeend', modalHtml);
    const modalElement = document.getElementById('modal-validar-checklist');
    const modal = new bootstrap.Modal(modalElement);
    modal.show();

    async function enviarValidacao(criarOS) {
      const observacaoPortaria = document.getElementById('checklist-obs-portaria').value.trim();
      if (!criarOS && temProblemas && !observacaoPortaria) {
        alert('Informe por que a avaria do checklist não foi confirmada.');
        return;
      }
      const button = document.getElementById('btn-confirmar-vistoria');
      button.disabled = true;
      button.textContent = criarOS ? 'Criando OS...' : 'Validando checklist...';
      const { error } = await window.db.rpc('validar_checklist_portaria', {
        p_checklist_id: Number(checklist.id),
        p_criar_os: criarOS,
        p_grupo_id: criarOS ? document.getElementById('checklist-grupo').value : null,
        p_prioridade: criarOS ? document.getElementById('checklist-prioridade').value : null,
        p_descricao: criarOS ? document.getElementById('checklist-descricao').value.trim() : null,
        p_observacao_portaria: observacaoPortaria || null
      });

      if (error) {
        alert('Não foi possível registrar a vistoria: ' + error.message);
        button.disabled = false;
        button.textContent = criarOS ? 'Confirmar e encaminhar à manutenção' : 'Validar checklist';
        return;
      }

      modal.hide();
      await Promise.all([carregarChecklistsPortaria(), carregarOSs()]);
    }

    document.getElementById('form-validar-checklist').addEventListener('submit', event => {
      event.preventDefault();
      enviarValidacao(temProblemas);
    });
    document.getElementById('btn-validar-sem-os')?.addEventListener('click', () => enviarValidacao(false));
  }

  // ---- Carrega OSs recentes ----
  async function carregarOSs() {
    const tbody = document.getElementById('tabela-os-portaria');
    const { data, error } = await window.db
      .from('ordens_servico')
      .select('*, veiculos(placa, modelo), grupo_problemas(nome), motorista:funcionarios!fk_ordens_servico_funcionario(cod_funcionario, nome_funcionario)')
      .order('created_at', { ascending: false })
      .limit(15);

    if (error) {
      tbody.innerHTML = '<p class="ops-empty text-danger">Erro ao carregar OSs.</p>';
      return;
    }

    if (!data || data.length === 0) {
      tbody.innerHTML = '<p class="ops-empty">Nenhuma OS cadastrada.</p>';
      return;
    }

    tbody.innerHTML = data.map(os => {
      const dataF = new Date(os.created_at).toLocaleString('pt-BR');
      const veiculoStr = os.veiculos ? `${os.veiculos.placa} (${os.veiculos.modelo})` : '—';
      const grupoNome = os.grupo_problemas ? os.grupo_problemas.nome : (os.grupo || 'Geral');
      const motorista = os.motorista
        ? `${os.motorista.nome_funcionario} (${os.motorista.cod_funcionario})`
        : (os.motorista_nome || '—');
      const prioridade = os.prioridade || 'Normal';
      const status = os.status || 'Pendente';
      const isComplete = status === 'Concluída';
      const dataConclusao = os.data_conclusao ? new Date(os.data_conclusao).toLocaleString('pt-BR') : '';

      return `
        <article class="ops-card ${isComplete ? 'is-complete' : 'is-pending'} ${prioridade.includes('Imediata') || prioridade.includes('Urgente') ? 'is-urgent' : ''}">
          <header class="ops-card-header">
            <span class="ops-card-reference">OS #${escapeHTML(String(os.id).slice(-8))} · ${escapeHTML(dataF)}</span>
            <span class="ops-card-badges"><span class="badge ${isComplete ? 'bg-success' : 'bg-warning text-dark'}">${escapeHTML(status)}</span>
              <span class="badge ${prioridade.includes('Imediata') || prioridade.includes('Urgente') ? 'bg-danger' : 'bg-light text-dark border'}">${escapeHTML(prioridade)}</span></span>
          </header>
          <div class="ops-card-vehicle"><span class="ops-card-vehicle-icon"><i class="bi bi-truck-front"></i></span>
            <div><span class="ops-card-vehicle-label">Veículo</span><strong>${escapeHTML(veiculoStr)}</strong></div></div>
          <div class="ops-card-facts">
            <div class="ops-card-fact"><span class="ops-card-label">Motorista</span><strong>${escapeHTML(motorista)}</strong></div>
            <div class="ops-card-fact"><span class="ops-card-label">Grupo</span><strong>${escapeHTML(grupoNome)}</strong></div>
          </div>
          <p class="ops-card-description">${escapeHTML(os.descricao)}</p>
          ${isComplete ? `<footer class="ops-card-footer"><small>Concluída em ${escapeHTML(dataConclusao)} · Mecânico: ${escapeHTML(os.mecanico || '—')}</small></footer>` : ''}
        </article>
      `;
    }).join('');
  }

  // ---- Enviar OS ----
  document.getElementById('form-os').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = document.getElementById('btn-enviar-os');
    const msg = document.getElementById('msg-os');

    btn.disabled = true;
    btn.textContent = 'Salvando OS...';
    msg.textContent = '';

    try {
      const sel = document.getElementById('veiculo-os');
      const veiculo_id = sel.value;
      const motorista_nome = document.getElementById('funcionario-os').selectedOptions[0]?.dataset.nome || '';
      const grupo_id = document.getElementById('grupo-os').value;
      const funcionario_id = document.getElementById('funcionario-os').value;
      const prioridade = document.getElementById('prioridade-os').value;
      const descricao = document.getElementById('descricao-os').value.trim();

      if (!veiculo_id) throw new Error('Selecione um veículo.');
      if (!funcionario_id) throw new Error('Selecione o motorista ou responsável.');
      if (!grupo_id) throw new Error('Selecione o grupo do problema.');

      const { error } = await window.db.from('ordens_servico').insert([{
        veiculo_id,
        porteiro_id: USUARIO.id,
        grupo_id,
        funcionario_id,
        motorista_nome,
        prioridade,
        descricao,
        status: 'Pendente'
      }]);

      if (error) throw error;

      msg.className = 'text-center mt-3 text-success fw-bold';
      msg.textContent = '✅ Ordem de Serviço criada com sucesso!';
      document.getElementById('form-os').reset();
      choicesFuncionario?.removeActiveItems();
      await Promise.all([carregarOSs(), carregarChecklistsPortaria()]);
    } catch (err) {
      console.error(err);
      msg.className = 'text-center mt-3 text-danger fw-bold';
      msg.textContent = '❌ Erro ao criar OS: ' + (err.message || err);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Abrir Ordem de Serviço';
    }
  });

  // ---- Logout ----
  document.getElementById('btn-sair').addEventListener('click', async () => {
    await window.db.auth.signOut();
    window.location.replace('login.html');
  });

  await carregarSelects();
  await Promise.all([carregarOSs(), carregarChecklistsPortaria()]);
  window.setInterval(carregarChecklistsPortaria, 30000);
})();
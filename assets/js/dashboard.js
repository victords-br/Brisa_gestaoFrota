// ============================================
// DASHBOARD
// ============================================
(async function () {
  console.log('🟢 dashboard.js iniciado');

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

  const { data: perfil } = await window.db
    .from('profiles')
    .select('role')
    .eq('id', session.user.id)
    .single();
  if (!['admin', 'manutencao'].includes(perfil?.role)) {
    window.location.replace(perfil?.role === 'porteiro' ? 'portaria.html' : 'index.html');
    return;
  }

  const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[char]);

  console.log('✅ Dashboard iniciado para:', session.user.email);

  // ---- KPIs (Ordens de Serviço) ----
  async function carregarKPIs() {
    const { data: osList, error } = await window.db
      .from('ordens_servico')
      .select('*, veiculos(placa)');

    if (error || !osList) {
      console.error('Erro ao carregar KPIs de OS:', error);
      return;
    }

    const totalOS = osList.length;
    const pendentesOS = osList.filter(o => o.status !== 'Concluída').length;
    const concluidasOS = osList.filter(o => o.status === 'Concluída').length;

    // Calcular veículo com mais OS
    const contagemVeiculos = {};
    osList.forEach(o => {
      const placa = o.veiculos?.placa || o.veiculo || 'Desconhecido';
      contagemVeiculos[placa] = (contagemVeiculos[placa] || 0) + 1;
    });

    let veiculoMaisProblematico = '—';
    let maxOS = 0;
    for (const [placa, qtd] of Object.entries(contagemVeiculos)) {
      if (qtd > maxOS) {
        maxOS = qtd;
        veiculoMaisProblematico = placa;
      }
    }

    document.getElementById('kpi-total').textContent = totalOS;
    document.getElementById('kpi-ok').textContent = pendentesOS;
    document.getElementById('kpi-naook').textContent = concluidasOS;
    document.getElementById('kpi-veiculo').textContent = veiculoMaisProblematico;
  }

  // ---- Logout ----
  document.getElementById('btn-sair').addEventListener('click', async () => {
    await window.db.auth.signOut();
    window.location.replace('login.html');
  });

  // ---- Start ----
  // ---- Tabela de Manutenção / Ordens de Serviço ----
  async function carregarOrdensServicoManutencao() {
    const tbody = document.getElementById('tabela-manutencao-os');
    if (!tbody) return;

    const { data, error } = await window.db
      .from('ordens_servico')
      .select('*, veiculos(placa, modelo), grupo_problemas(nome), motorista:funcionarios!fk_ordens_servico_funcionario(cod_funcionario, nome_funcionario), mecanico_funcionario:funcionarios!ordens_servico_mecanico_id_fkey(nome_funcionario), ordens_servico_mecanicos(funcionario_id, especialidade, horas_trabalhadas, mecanico:funcionarios!ordens_servico_mecanicos_funcionario_id_fkey(nome_funcionario)), itens_ordem_servico(id, quantidade, quantidade_utilizada, custo_unitario, pecas(nome, unidade))')
      .order('created_at', { ascending: false });

    if (error) {
      console.error(error);
      tbody.innerHTML = `<p class="ops-empty text-danger">Erro ao carregar ordens de serviço: ${escapeHTML(error.message)}</p>`;
      return;
    }

    if (!data || data.length === 0) {
      tbody.innerHTML = '<p class="ops-empty">Nenhuma ordem de serviço registrada.</p>';
      return;
    }

    tbody.innerHTML = data.map(os => {
      const dataF = new Date(os.created_at).toLocaleString('pt-BR');
      const veiculoStr = os.veiculos ? `${os.veiculos.placa} (${os.veiculos.modelo})` : '—';
      const motorista = os.motorista
        ? `${os.motorista.nome_funcionario} (${os.motorista.cod_funcionario})`
        : os.motorista_nome || '—';
      const grupoNome = os.grupo_problemas ? os.grupo_problemas.nome : (os.grupo || 'Geral');
      const isConcluida = os.status === 'Concluída';
      const prioridade = os.prioridade || 'Normal';
      const itens = os.itens_ordem_servico || [];
      const equipe = os.ordens_servico_mecanicos || [];
      const custoPecas = itens.reduce((total, item) => {
        const quantidadeCobrada = isConcluida ? item.quantidade_utilizada : item.quantidade;
        return total + Number(quantidadeCobrada || 0) * Number(item.custo_unitario || 0);
      }, 0);
      const itensHtml = itens.length
        ? `${itens.map(item => `${escapeHTML(item.pecas?.nome || 'Peça')} · liberada ${Number(item.quantidade).toLocaleString('pt-BR')} ${escapeHTML(item.pecas?.unidade || '')}${isConcluida ? ` · usada ${Number(item.quantidade_utilizada || 0).toLocaleString('pt-BR')}` : ' · uso a confirmar'}`).join('<br>')}<br><strong>${isConcluida ? 'Custo real das peças' : 'Custo estimado das peças liberadas'}: ${custoPecas.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })}</strong>`
        : '—';
      const dataConclusao = os.data_conclusao ? new Date(os.data_conclusao).toLocaleString('pt-BR') : '—';
      const mecanicoNome = equipe.length
        ? equipe.map(item => {
          const horas = Number(item.horas_trabalhadas || 0);
          const detalheHoras = isConcluida
            ? ` · ${horas.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} h`
            : '';
          return `${item.mecanico?.nome_funcionario || 'Mecânico'} (${item.especialidade}${detalheHoras})`;
        }).join(', ')
        : os.mecanico_funcionario?.nome_funcionario || os.mecanico || '—';
      const horasTrabalhadas = equipe.reduce((total, item) => total + Number(item.horas_trabalhadas || 0), 0);
      const status = os.status || 'Pendente';
      const busca = `${veiculoStr} ${motorista} ${grupoNome} ${os.descricao}`.toLocaleLowerCase('pt-BR');

      let acoesHtml = '';
      if (status === 'Pendente') {
        acoesHtml = `
          <button class="btn btn-sm btn-success fw-bold btn-tratar-os" data-id="${escapeHTML(os.id)}" data-placa="${escapeHTML(os.veiculos?.placa || '')}">
            <i class="bi bi-check2-circle me-1"></i> Tratar OS
          </button>
        `;
      }

      return `
        <article class="ops-card ${isConcluida ? 'is-complete' : status === 'Pendente' ? 'is-pending' : ''} ${prioridade.includes('Imediata') || prioridade.includes('Urgente') ? 'is-urgent' : ''}"
          data-status="${escapeHTML(status)}" data-search="${escapeHTML(busca)}">
          <header class="ops-card-header">
            <span class="ops-card-reference">OS #${escapeHTML(String(os.id).slice(-8))}</span>
            <span class="ops-card-badges">
              <span class="badge ${isConcluida ? 'bg-success' : status === 'Pendente' ? 'bg-warning text-dark' : 'bg-secondary'}">${escapeHTML(status)}</span>
              <span class="badge ${prioridade.includes('Imediata') || prioridade.includes('Urgente') ? 'bg-danger' : 'bg-light text-dark border'}">${escapeHTML(prioridade)}</span>
            </span>
          </header>
          <div class="ops-card-vehicle">
            <span class="ops-card-vehicle-icon"><i class="bi bi-truck-front"></i></span>
            <div><span class="ops-card-vehicle-label">Veículo</span><strong>${escapeHTML(veiculoStr)}</strong></div>
            <time class="ops-card-time">${escapeHTML(dataF)}</time>
          </div>
          <div class="ops-card-facts">
            <div class="ops-card-fact"><span class="ops-card-label">Motorista</span><strong>${escapeHTML(motorista)}</strong></div>
            <div class="ops-card-fact"><span class="ops-card-label">Grupo</span><strong>${escapeHTML(grupoNome)}</strong></div>
            <div class="ops-card-fact"><span class="ops-card-label">Equipe</span><strong>${escapeHTML(mecanicoNome)}</strong></div>
            <div class="ops-card-fact"><span class="ops-card-label">Horas trabalhadas</span><strong>${isConcluida ? `${horasTrabalhadas.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} h` : 'A calcular ao concluir'}</strong></div>
          </div>
          <p class="ops-card-description">${escapeHTML(os.descricao)}</p>
          <div class="ops-card-parts"><span class="ops-card-label">Peças e custo</span>${itensHtml}</div>
          <footer class="ops-card-footer">
            <small>${isConcluida ? `Concluída ${escapeHTML(dataConclusao)} · Equipe: ${escapeHTML(mecanicoNome)}` : 'Aguardando tratamento da manutenção'}</small>
            ${acoesHtml}
          </footer>
        </article>
      `;
    }).join('');
    aplicarFiltrosOrdens();
  }

  function aplicarFiltrosOrdens() {
    const statusSelecionado = document.querySelector('[data-os-status].active')?.dataset.osStatus || 'Todas';
    const termo = document.getElementById('filtro-os').value.trim().toLocaleLowerCase('pt-BR');
    document.querySelectorAll('#tabela-manutencao-os .ops-card').forEach(card => {
      card.hidden = (statusSelecionado !== 'Todas' && card.dataset.status !== statusSelecionado)
        || !card.dataset.search.includes(termo);
    });
  }

  document.querySelectorAll('[data-os-status]').forEach(button => {
    button.addEventListener('click', () => {
      document.querySelectorAll('[data-os-status]').forEach(filter => {
        const active = filter === button;
        filter.classList.toggle('active', active);
        filter.setAttribute('aria-pressed', String(active));
      });
      aplicarFiltrosOrdens();
    });
  });
  document.getElementById('filtro-os').addEventListener('input', aplicarFiltrosOrdens);

  document.getElementById('tabela-manutencao-os').addEventListener('click', (event) => {
    const button = event.target.closest('.btn-tratar-os');
    if (button) window.abrirModalConcluirOS(button.dataset.id, button.dataset.placa);
  });

  // Função global para abrir modal de conclusão de OS
  window.abrirModalConcluirOS = async function(osId, placa) {
    const modalAntigo = document.getElementById('modal-concluir-os');
    if (modalAntigo) modalAntigo.remove();

    const { data: ordem, error } = await window.db
      .from('ordens_servico')
      .select('mecanico_id, mecanico_funcionario:funcionarios!ordens_servico_mecanico_id_fkey(nome_funcionario), ordens_servico_mecanicos(funcionario_id, especialidade, inicio_em, fim_em, mecanico:funcionarios!ordens_servico_mecanicos_funcionario_id_fkey(nome_funcionario)), itens_ordem_servico(id, quantidade, quantidade_utilizada, custo_unitario, pecas(nome, unidade))')
      .eq('id', osId)
      .single();
    if (error) {
      alert('Não foi possível carregar as peças liberadas para esta OS: ' + error.message);
      return;
    }
    const equipe = ordem.ordens_servico_mecanicos || [];
    if (!equipe.length) {
      alert('Associe pelo menos um mecânico à OS no Almoxarifado antes de concluir.');
      return;
    }

    const itensLiberados = ordem.itens_ordem_servico || [];
    const itensHtml = itensLiberados.length ? itensLiberados.map(item => `
      <div class="row g-2 align-items-center mb-2 linha-confirmacao-peca" data-item-id="${escapeHTML(item.id)}">
        <div class="col-7"><strong>${escapeHTML(item.pecas?.nome || 'Peça')}</strong><small class="d-block text-muted">Liberada: ${Number(item.quantidade).toLocaleString('pt-BR')} ${escapeHTML(item.pecas?.unidade || '')}</small></div>
        <div class="col-5"><label class="visually-hidden" for="usada-${escapeHTML(item.id)}">Quantidade utilizada</label><input id="usada-${escapeHTML(item.id)}" class="form-control quantidade-utilizada" type="number" min="0" max="${escapeHTML(item.quantidade)}" step="0.001" value="0" aria-label="Quantidade utilizada"></div>
      </div>`).join('') : '<p class="text-muted mb-0">Nenhuma peça liberada para esta OS. Ela será concluída sem consumo de peças.</p>';
    const dataLocal = (valor) => {
      if (!valor) return '';
      const data = new Date(valor);
      data.setMinutes(data.getMinutes() - data.getTimezoneOffset());
      return data.toISOString().slice(0, 16);
    };
    const equipeHtml = equipe.map(item => `
      <div class="border rounded p-2 mb-2 linha-horas-mecanico" data-mecanico-id="${escapeHTML(item.funcionario_id)}">
        <strong>${escapeHTML(item.mecanico?.nome_funcionario || 'Mecânico')}</strong>
        <span class="text-muted"> · ${escapeHTML(item.especialidade)}</span>
        <div class="row g-2 mt-1">
          <div class="col-6"><label class="form-label small">Início</label><input class="form-control inicio-mecanico" type="datetime-local" required value="${escapeHTML(dataLocal(item.inicio_em))}"></div>
          <div class="col-6"><label class="form-label small">Fim</label><input class="form-control fim-mecanico" type="datetime-local" required value="${escapeHTML(dataLocal(item.fim_em))}"></div>
        </div>
        <small class="text-muted horas-mecanico-preview">Informe o início e o fim.</small>
      </div>`).join('');

    const modalHtml = `
      <div class="modal fade" id="modal-concluir-os" tabindex="-1">
        <div class="modal-dialog">
          <div class="modal-content">
            <div class="modal-header bg-success text-white">
              <h5 class="modal-title"><i class="bi bi-tools me-2"></i>Concluir OS — Veículo ${escapeHTML(placa)}</h5>
              <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
            </div>
            <div class="modal-body">
              <form id="form-concluir-os">
                <div class="mb-3">
                  <span class="form-label fw-bold d-block">Equipe e horas trabalhadas</span>
                  <p class="small text-muted">Informe o horário de início e fim de cada mecânico. As horas são calculadas individualmente e somadas na OS.</p>
                  <div id="equipe-horas-os">${equipeHtml}</div>
                  <strong>Total da equipe: <span id="total-horas-equipe">0,00 h</span></strong>
                </div>
                <div class="mb-3">
                  <label class="form-label fw-bold">Observações do Reparo</label>
                  <textarea class="form-control" id="mecanico-obs" rows="3" placeholder="Peças trocadas, serviço realizado..."></textarea>
                </div>
                <div class="mb-2 d-flex justify-content-between align-items-center">
                  <label class="form-label fw-bold mb-0">Confirmar quantidade utilizada</label>
                </div>
                <p class="small text-muted">O que não foi utilizado será devolvido ao estoque.</p>
                <div id="itens-pecas-os">${itensHtml}</div>
                <button type="submit" class="btn btn-success w-100 fw-bold mt-3" id="btn-concluir-os">Confirmar uso e concluir OS</button>
              </form>
            </div>
          </div>
        </div>
      </div>
    `;

    document.body.insertAdjacentHTML('beforeend', modalHtml);
    const modalEl = document.getElementById('modal-concluir-os');
    const modalBS = new bootstrap.Modal(modalEl);
    modalBS.show();

    const atualizarHoras = () => {
      let total = 0;
      modalEl.querySelectorAll('.linha-horas-mecanico').forEach(linha => {
        const inicio = linha.querySelector('.inicio-mecanico').value;
        const fim = linha.querySelector('.fim-mecanico').value;
        const preview = linha.querySelector('.horas-mecanico-preview');
        if (!inicio || !fim || new Date(fim) <= new Date(inicio)) {
          preview.textContent = inicio && fim ? 'O fim deve ser depois do início.' : 'Informe o início e o fim.';
          return;
        }
        const horas = (new Date(fim) - new Date(inicio)) / 3600000;
        total += horas;
        preview.textContent = `${horas.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} h trabalhadas`;
      });
      document.getElementById('total-horas-equipe').textContent = `${total.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} h`;
    };
    modalEl.querySelectorAll('.inicio-mecanico, .fim-mecanico').forEach(input => input.addEventListener('input', atualizarHoras));
    atualizarHoras();

    modalEl.querySelector('#form-concluir-os').addEventListener('submit', async (e) => {
      e.preventDefault();
      const obs = document.getElementById('mecanico-obs').value.trim();
      const itens = [...modalEl.querySelectorAll('#itens-pecas-os .linha-confirmacao-peca')].map(linha => ({
        item_id: Number(linha.dataset.itemId),
        quantidade_utilizada: Number(linha.querySelector('.quantidade-utilizada').value)
      }));
      for (const item of itens) {
        const linha = modalEl.querySelector(`[data-item-id="${item.item_id}"]`);
        const limite = Number(linha.querySelector('.quantidade-utilizada').max);
        if (!Number.isFinite(item.quantidade_utilizada) || item.quantidade_utilizada < 0 || item.quantidade_utilizada > limite) {
          alert('Informe uma quantidade utilizada válida, sem ultrapassar o que foi liberado.');
          return;
        }
      }
      const mecanicos = [...modalEl.querySelectorAll('.linha-horas-mecanico')].map(linha => {
        const inicio = linha.querySelector('.inicio-mecanico').value;
        const fim = linha.querySelector('.fim-mecanico').value;
        return {
          funcionario_id: linha.dataset.mecanicoId,
          inicio_em: inicio && Number.isFinite(new Date(inicio).getTime()) ? new Date(inicio).toISOString() : '',
          fim_em: fim && Number.isFinite(new Date(fim).getTime()) ? new Date(fim).toISOString() : ''
        };
      });
      if (mecanicos.some(item => !item.inicio_em || !item.fim_em || new Date(item.fim_em) <= new Date(item.inicio_em))) {
        alert('Informe horários válidos para todos os mecânicos. O fim deve ser depois do início.');
        return;
      }

      const botao = document.getElementById('btn-concluir-os');
      botao.disabled = true;
      botao.textContent = 'Confirmando uso e concluindo...';
      const { error } = await window.db.rpc('finalizar_ordem_servico', {
        p_ordem_id: osId,
        p_obs: obs,
        p_itens: itens,
        p_mecanicos: mecanicos
      });

      if (error) {
        alert('Erro ao concluir OS: ' + error.message);
        botao.disabled = false;
        botao.textContent = 'Confirmar uso e concluir OS';
        return;
      }

      modalBS.hide();
      carregarOrdensServicoManutencao();
      carregarKPIs();
    });
  };

  // ---- Geração de PDF ----
  async function gerarPdfOS(tipoFiltro) {
    const { jsPDF } = window.jspdf;
    const doc = new jsPDF({ orientation: 'landscape' });

    const titulo = tipoFiltro === 'Concluída' ? 'Relatório de Ordens de Serviço - Concluídas' : 'Relatório de Ordens de Serviço - Pendentes';
    const corCabecalho = tipoFiltro === 'Concluída' ? [40, 167, 69] : [255, 193, 7];

    const { data, error } = await window.db
      .from('ordens_servico')
      .select('*, veiculos(placa, modelo), grupo_problemas(nome), motorista:funcionarios!fk_ordens_servico_funcionario(cod_funcionario, nome_funcionario)')
      .eq('status', tipoFiltro)
      .order('created_at', { ascending: false });

    if (error) {
      alert('Erro ao carregar dados para o PDF: ' + error.message);
      return;
    }

    if (!data || data.length === 0) {
      alert(`Nenhuma Ordem de Serviço encontrada com o status "${tipoFiltro}".`);
      return;
    }

    // Cabeçalho no PDF
    doc.setFontSize(16);
    doc.setTextColor(40, 40, 40);
    doc.text(titulo, 14, 18);
    
    doc.setFontSize(10);
    doc.setTextColor(100, 100, 100);
    doc.text(`Gerado em: ${new Date().toLocaleString('pt-BR')}`, 14, 25);

    const corpoTabela = data.map(os => {
      const dataF = new Date(os.created_at).toLocaleString('pt-BR');
      const veiculoStr = os.veiculos ? `${os.veiculos.placa} (${os.veiculos.modelo})` : '—';
      const motoristaNome = os.motorista
        ? `${os.motorista.nome_funcionario} (${os.motorista.cod_funcionario})`
        : os.motorista_nome || '—';
      const grupoNome = os.grupo_problemas ? os.grupo_problemas.nome : (os.grupo || 'Geral');

      if (tipoFiltro === 'Concluída') {
        const dataFim = os.data_conclusao ? new Date(os.data_conclusao).toLocaleString('pt-BR') : '—';
        return [
          dataF,
          veiculoStr,
          motoristaNome,
          grupoNome,
          os.prioridade,
          os.descricao,
          os.mecanico || '—',
          dataFim
        ];
      } else {
        return [
          dataF,
          veiculoStr,
          motoristaNome,
          grupoNome,
          os.prioridade,
          os.descricao
        ];
      }
    });

    const colunas = tipoFiltro === 'Concluída' 
      ? ['Data/Hora', 'Veículo', 'Motorista', 'Grupo', 'Prioridade', 'Problema', 'Mecânico', 'Data Conclusão']
      : ['Data/Hora', 'Veículo', 'Motorista', 'Grupo', 'Prioridade', 'Problema'];

    doc.autoTable({
      startY: 32,
      head: [colunas],
      body: corpoTabela,
      theme: 'grid',
      headStyles: { fillColor: corCabecalho, textColor: tipoFiltro === 'Concluída' ? 255 : 40 },
      styles: { fontSize: 9, cellPadding: 4 }
    });

    doc.save(`os_${tipoFiltro.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')}.pdf`);
  }

  document.getElementById('btn-pdf-pendentes').addEventListener('click', () => gerarPdfOS('Pendente'));
  document.getElementById('btn-pdf-concluidas').addEventListener('click', () => gerarPdfOS('Concluída'));

  carregarKPIs();
  carregarOrdensServicoManutencao();
})();

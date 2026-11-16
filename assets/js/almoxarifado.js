// ============================================
// ALMOXARIFADO
// ============================================
(async function () {
  let tentativas = 0;
  while (!window.db && tentativas < 50) {
    await new Promise(resolve => setTimeout(resolve, 100));
    tentativas++;
  }

  if (!window.db) return;

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
  if (perfil.role === 'admin') {
    document.getElementById('painel-mecanicos').classList.remove('d-none');
  }

  const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[char]);
  const moeda = (value) => Number(value || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
  let pecasCache = [];

  function mensagem(id, texto, tipo) {
    const elemento = document.getElementById(id);
    elemento.textContent = texto;
    elemento.className = `form-feedback ${tipo ? `is-${tipo}` : ''}`;
  }

  async function carregarPecas() {
    const tbody = document.getElementById('tabela-pecas');
    const { data, error } = await window.db.from('pecas').select('*').eq('ativo', true).order('nome');
    if (error) {
      tbody.innerHTML = '<tr><td colspan="7" class="text-center text-danger py-4">Erro ao carregar estoque. Confira a migração e as permissões no Supabase.</td></tr>';
      return;
    }

    pecasCache = data || [];
    const abaixoMinimo = pecasCache.filter(peca => Number(peca.saldo_estoque) <= Number(peca.estoque_minimo));
    const valorTotal = pecasCache.reduce((total, peca) => total + Number(peca.saldo_estoque) * Number(peca.custo_medio), 0);
    document.getElementById('kpi-pecas').textContent = pecasCache.length;
    document.getElementById('kpi-baixo').textContent = abaixoMinimo.length;
    document.getElementById('kpi-valor').textContent = moeda(valorTotal);

    tbody.innerHTML = pecasCache.length ? pecasCache.map(peca => {
      const saldo = Number(peca.saldo_estoque);
      const minimo = Number(peca.estoque_minimo);
      const baixo = saldo <= minimo;
      return `<tr data-peca-busca="${escapeHTML(`${peca.codigo} ${peca.nome}`.toLocaleLowerCase('pt-BR'))}">
        <td class="fw-bold">${escapeHTML(peca.codigo)}</td>
        <td>${escapeHTML(peca.nome)}${peca.descricao ? `<small class="d-block text-muted">${escapeHTML(peca.descricao)}</small>` : ''}</td>
        <td>${saldo.toLocaleString('pt-BR')} ${escapeHTML(peca.unidade)}</td>
        <td>${minimo.toLocaleString('pt-BR')} ${escapeHTML(peca.unidade)}</td>
        <td>${moeda(peca.custo_medio)}</td>
        <td>${moeda(saldo * Number(peca.custo_medio))}</td>
        <td><span class="badge ${baixo ? 'stock-low' : 'stock-ok'}">${baixo ? 'Repor' : 'Normal'}</span></td>
      </tr>`;
    }).join('') : '<tr><td colspan="7" class="text-center text-muted py-4">Nenhuma peça cadastrada.</td></tr>';

    const select = document.getElementById('entrada-peca');
    select.innerHTML = '<option value="">Selecione uma peça...</option>' + pecasCache.map(peca =>
      `<option value="${escapeHTML(peca.id)}">${escapeHTML(peca.codigo)} · ${escapeHTML(peca.nome)} (${Number(peca.saldo_estoque).toLocaleString('pt-BR')} ${escapeHTML(peca.unidade)})</option>`
    ).join('');
    aplicarFiltro();
  }

  async function carregarMovimentacoes() {
    const tbody = document.getElementById('tabela-movimentos');
    const { data, error } = await window.db
      .from('movimentacoes_estoque')
      .select('id, tipo, quantidade, custo_total, observacao, created_at, pecas(codigo, nome)')
      .order('created_at', { ascending: false })
      .limit(30);
    if (error) {
      tbody.innerHTML = '<tr><td colspan="5" class="text-center text-danger py-4">Erro ao carregar movimentações.</td></tr>';
      return;
    }
    tbody.innerHTML = data?.length ? data.map(item => `
      <tr>
        <td class="text-nowrap">${escapeHTML(new Date(item.created_at).toLocaleString('pt-BR'))}</td>
        <td><span class="badge ${item.tipo === 'entrada' ? 'stock-ok' : 'stock-low'}">${item.tipo === 'entrada' ? (item.observacao?.includes('Devolução') ? 'Devolução' : 'Entrada') : 'Liberada'}</span></td>
        <td>${escapeHTML(item.pecas?.codigo || '')} · ${escapeHTML(item.pecas?.nome || 'Peça')}</td>
        <td>${Number(item.quantidade).toLocaleString('pt-BR')}</td>
        <td class="text-end">${moeda(item.custo_total)}</td>
      </tr>`).join('') : '<tr><td colspan="5" class="text-center text-muted py-4">Nenhuma movimentação registrada.</td></tr>';
  }

  async function carregarCustosPorVeiculo() {
    const tbody = document.getElementById('tabela-custo-veiculo');
    const { data, error } = await window.db
      .from('itens_ordem_servico')
      .select('quantidade_utilizada, custo_unitario, ordens_servico!inner(veiculos(placa, modelo))')
      .gt('quantidade_utilizada', 0);
    if (error) {
      tbody.innerHTML = '<tr><td colspan="2" class="text-center text-danger py-4">Erro ao calcular custos por veículo.</td></tr>';
      return;
    }

    const totais = new Map();
    (data || []).forEach(movimento => {
      const veiculo = movimento.ordens_servico?.veiculos;
      if (!veiculo) return;
      const nome = `${veiculo.placa} · ${veiculo.modelo}`;
      totais.set(nome, (totais.get(nome) || 0) + Number(movimento.quantidade_utilizada || 0) * Number(movimento.custo_unitario || 0));
    });
    const linhas = [...totais.entries()].sort((a, b) => b[1] - a[1]);
    tbody.innerHTML = linhas.length ? linhas.map(([veiculo, custo]) =>
      `<tr><td class="fw-bold">${escapeHTML(veiculo)}</td><td class="text-end fw-bold">${moeda(custo)}</td></tr>`
    ).join('') : '<tr><td colspan="2" class="text-center text-muted py-4">Ainda não há consumo de peças vinculado a veículos.</td></tr>';
  }

  async function carregarFuncionarios() {
    const select = document.getElementById('funcionario-mecanico');
    const { data, error } = await window.db
      .from('funcionarios')
      .select('id, cod_funcionario, nome_funcionario, is_mecanico')
      .order('nome_funcionario');
    if (error) {
      select.innerHTML = '<option value="">Erro ao carregar funcionários</option>';
      mensagem('msg-mecanico', error.message, 'error');
      return;
    }
    select.innerHTML = '<option value="">Selecione um funcionário...</option>' + (data || []).map(funcionario =>
      `<option value="${escapeHTML(funcionario.id)}" data-mecanico="${funcionario.is_mecanico}">[${escapeHTML(funcionario.cod_funcionario)}] ${escapeHTML(funcionario.nome_funcionario)}</option>`
    ).join('');
    select.addEventListener('change', () => {
      document.getElementById('status-mecanico').value = select.selectedOptions[0]?.dataset.mecanico === 'true' ? 'true' : 'false';
    });
  }

  async function carregarOrdensLiberacao() {
    const container = document.getElementById('lista-os-liberacao');
    const [{ data: ordens, error: erroOrdens }, { data: mecanicos, error: erroMecanicos }] = await Promise.all([
      window.db.from('ordens_servico')
        .select('id, descricao, created_at, status, veiculos(placa, modelo), mecanico_id, mecanico_funcionario:funcionarios!ordens_servico_mecanico_id_fkey(nome_funcionario), itens_ordem_servico(id, quantidade, quantidade_utilizada, pecas(codigo, nome, unidade))')
        .eq('status', 'Pendente')
        .order('created_at', { ascending: true }),
      window.db.from('funcionarios').select('id, cod_funcionario, nome_funcionario').eq('is_mecanico', true).order('nome_funcionario')
    ]);

    if (erroOrdens || erroMecanicos) {
      container.innerHTML = '<p class="text-danger">Erro ao carregar OS ou mecânicos. Confira a migração do almoxarifado.</p>';
      return;
    }
    if (!ordens?.length) {
      container.innerHTML = '<p class="text-muted">Não há ordens pendentes para separar peças.</p>';
      return;
    }

    const mecanicoOptions = (mecanicos || []).map(mecanico =>
      `<option value="${escapeHTML(mecanico.id)}">${escapeHTML(mecanico.nome_funcionario)} (${escapeHTML(mecanico.cod_funcionario)})</option>`
    ).join('');
    const pecaOptions = pecasCache.filter(peca => Number(peca.saldo_estoque) > 0).map(peca =>
      `<option value="${escapeHTML(peca.id)}" data-saldo="${escapeHTML(peca.saldo_estoque)}">${escapeHTML(peca.codigo)} · ${escapeHTML(peca.nome)} (${Number(peca.saldo_estoque).toLocaleString('pt-BR')} ${escapeHTML(peca.unidade)})</option>`
    ).join('');

    container.innerHTML = ordens.map(os => {
      const placa = os.veiculos ? `${os.veiculos.placa} (${os.veiculos.modelo})` : 'Veículo não identificado';
      const itens = os.itens_ordem_servico || [];
      const itensHtml = itens.length ? itens.map(item =>
        `${escapeHTML(item.pecas?.nome || 'Peça')} × ${Number(item.quantidade).toLocaleString('pt-BR')} ${escapeHTML(item.pecas?.unidade || '')}`
      ).join('<br>') : 'Nenhuma peça liberada ainda.';
      return `<article class="warehouse-release-card">
        <h3>${escapeHTML(placa)}</h3>
        <p class="small text-muted mb-1">OS #${escapeHTML(String(os.id).slice(-8))}</p>
        <p class="small mb-2">${escapeHTML(os.descricao)}</p>
        <p class="small mb-1"><strong>Mecânico:</strong> ${escapeHTML(os.mecanico_funcionario?.nome_funcionario || 'A definir')}</p>
        <div class="warehouse-release-items"><strong>Peças liberadas</strong><br>${itensHtml}</div>
        <form class="warehouse-release-form" data-release-os="${escapeHTML(os.id)}">
          <label class="form-label" for="mecanico-os-${escapeHTML(os.id)}">Mecânico que receberá</label>
          <select class="form-select mb-2 release-mechanic" id="mecanico-os-${escapeHTML(os.id)}" required ${os.mecanico_id ? 'disabled' : ''}>
            <option value="">Selecione...</option>${mecanicoOptions}
          </select>
          <div class="release-lines d-flex flex-column gap-2"></div>
          <div class="d-flex gap-2 mt-2">
            <button type="button" class="btn btn-sm btn-outline-secondary btn-add-release" ${pecaOptions ? '' : 'disabled'}><i class="bi bi-plus-lg me-1"></i>Adicionar peça</button>
            <button type="submit" class="btn btn-sm btn-warehouse">${itens.length ? 'Liberar mais peças' : 'Associar mecânico e liberar'}</button>
          </div>
          <span class="form-feedback" aria-live="polite"></span>
        </form>
      </article>`;
    }).join('');

    container.querySelectorAll('[data-release-os]').forEach(form => {
      const os = ordens.find(ordem => ordem.id === form.dataset.releaseOs);
      if (os?.mecanico_id) form.querySelector('.release-mechanic').value = os.mecanico_id;
    });
  }

  document.getElementById('lista-os-liberacao').addEventListener('click', event => {
    const button = event.target.closest('.btn-add-release');
    if (!button) return;
    const linha = document.createElement('div');
    linha.className = 'row g-2 align-items-center release-line';
    const options = pecasCache.filter(peca => Number(peca.saldo_estoque) > 0).map(peca =>
      `<option value="${escapeHTML(peca.id)}" data-saldo="${escapeHTML(peca.saldo_estoque)}">${escapeHTML(peca.codigo)} · ${escapeHTML(peca.nome)} (${Number(peca.saldo_estoque).toLocaleString('pt-BR')})</option>`
    ).join('');
    linha.innerHTML = `<div class="col-7"><select class="form-select release-part" required><option value="">Selecione a peça...</option>${options}</select></div>
      <div class="col-4"><input class="form-control release-quantity" type="number" min="0.001" step="0.001" placeholder="Qtd." required></div>
      <div class="col-1"><button type="button" class="btn btn-outline-danger btn-sm remove-release" aria-label="Remover peça"><i class="bi bi-x-lg"></i></button></div>`;
    linha.querySelector('.remove-release').addEventListener('click', () => linha.remove());
    button.closest('form').querySelector('.release-lines').appendChild(linha);
  });

  document.getElementById('lista-os-liberacao').addEventListener('submit', async event => {
    const form = event.target.closest('[data-release-os]');
    if (!form) return;
    event.preventDefault();
    const mecanicoId = form.querySelector('.release-mechanic').value;
    const itens = [];
    for (const linha of form.querySelectorAll('.release-line')) {
      const select = linha.querySelector('.release-part');
      const quantidade = Number(linha.querySelector('.release-quantity').value);
      const saldo = Number(select.selectedOptions[0]?.dataset.saldo || 0);
      if (!select.value || !Number.isFinite(quantidade) || quantidade <= 0 || quantidade > saldo) {
        form.querySelector('.form-feedback').textContent = 'Informe peça e quantidade dentro do saldo disponível.';
        return;
      }
      itens.push({ peca_id: Number(select.value), quantidade });
    }
    const button = form.querySelector('[type="submit"]');
    button.disabled = true;
    form.querySelector('.form-feedback').textContent = '';
    const { error } = await window.db.rpc('registrar_saida_estoque_os', {
      p_ordem_id: form.dataset.releaseOs,
      p_mecanico_id: mecanicoId,
      p_itens: itens
    });
    if (error) {
      form.querySelector('.form-feedback').textContent = error.message;
      button.disabled = false;
      return;
    }
    await carregarPecas();
    await Promise.all([carregarMovimentacoes(), carregarOrdensLiberacao(), carregarCustosPorVeiculo()]);
  });

  function aplicarFiltro() {
    const termo = document.getElementById('filtro-pecas').value.trim().toLocaleLowerCase('pt-BR');
    document.querySelectorAll('#tabela-pecas tr[data-peca-busca]').forEach(linha => {
      linha.hidden = !linha.dataset.pecaBusca.includes(termo);
    });
  }

  document.getElementById('form-peca').addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = document.getElementById('btn-cadastrar-peca');
    button.disabled = true;
    mensagem('msg-peca', '', '');
    const { error } = await window.db.from('pecas').insert({
      codigo: document.getElementById('peca-codigo').value.trim(),
      nome: document.getElementById('peca-nome').value.trim(),
      unidade: document.getElementById('peca-unidade').value,
      estoque_minimo: Number(document.getElementById('peca-minimo').value),
      descricao: document.getElementById('peca-descricao').value.trim() || null
    });
    if (error) mensagem('msg-peca', error.message, 'error');
    else {
      event.target.reset();
      document.getElementById('peca-minimo').value = '0';
      mensagem('msg-peca', 'Peça cadastrada.', 'success');
      await carregarPecas();
    }
    button.disabled = false;
  });

  document.getElementById('form-entrada').addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = document.getElementById('btn-registrar-entrada');
    button.disabled = true;
    mensagem('msg-entrada', '', '');
    const { error } = await window.db.rpc('registrar_entrada_estoque', {
      p_peca_id: Number(document.getElementById('entrada-peca').value),
      p_quantidade: Number(document.getElementById('entrada-quantidade').value),
      p_custo_unitario: Number(document.getElementById('entrada-custo').value),
      p_observacao: document.getElementById('entrada-observacao').value.trim()
    });
    if (error) mensagem('msg-entrada', error.message, 'error');
    else {
      event.target.reset();
      mensagem('msg-entrada', 'Entrada registrada e custo médio atualizado.', 'success');
      await Promise.all([carregarPecas(), carregarMovimentacoes(), carregarCustosPorVeiculo()]);
    }
    button.disabled = false;
  });

  document.getElementById('filtro-pecas').addEventListener('input', aplicarFiltro);
  document.getElementById('form-mecanico').addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = document.getElementById('btn-salvar-mecanico');
    button.disabled = true;
    const { error } = await window.db.rpc('definir_funcionario_mecanico', {
      p_funcionario_id: document.getElementById('funcionario-mecanico').value,
      p_is_mecanico: document.getElementById('status-mecanico').value === 'true'
    });
    if (error) mensagem('msg-mecanico', error.message, 'error');
    else {
      mensagem('msg-mecanico', 'Função atualizada.', 'success');
      await carregarFuncionarios();
    }
    button.disabled = false;
  });
  document.getElementById('btn-sair').addEventListener('click', async () => {
    await window.db.auth.signOut();
    window.location.replace('login.html');
  });

  const cargas = [carregarPecas(), carregarMovimentacoes(), carregarCustosPorVeiculo()];
  if (perfil.role === 'admin') cargas.push(carregarFuncionarios());
  await Promise.all(cargas);
  await carregarOrdensLiberacao();
})();
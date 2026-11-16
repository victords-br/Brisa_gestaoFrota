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
      .select('id, tipo, quantidade, custo_total, created_at, pecas(codigo, nome)')
      .order('created_at', { ascending: false })
      .limit(30);
    if (error) {
      tbody.innerHTML = '<tr><td colspan="5" class="text-center text-danger py-4">Erro ao carregar movimentações.</td></tr>';
      return;
    }
    tbody.innerHTML = data?.length ? data.map(item => `
      <tr>
        <td class="text-nowrap">${escapeHTML(new Date(item.created_at).toLocaleString('pt-BR'))}</td>
        <td><span class="badge ${item.tipo === 'entrada' ? 'stock-ok' : 'stock-low'}">${item.tipo === 'entrada' ? 'Entrada' : 'Consumo'}</span></td>
        <td>${escapeHTML(item.pecas?.codigo || '')} · ${escapeHTML(item.pecas?.nome || 'Peça')}</td>
        <td>${Number(item.quantidade).toLocaleString('pt-BR')}</td>
        <td class="text-end">${moeda(item.custo_total)}</td>
      </tr>`).join('') : '<tr><td colspan="5" class="text-center text-muted py-4">Nenhuma movimentação registrada.</td></tr>';
  }

  async function carregarCustosPorVeiculo() {
    const tbody = document.getElementById('tabela-custo-veiculo');
    const { data, error } = await window.db
      .from('movimentacoes_estoque')
      .select('custo_total, ordens_servico!inner(veiculos(placa, modelo))')
      .eq('tipo', 'saida')
      .not('ordem_servico_id', 'is', null);
    if (error) {
      tbody.innerHTML = '<tr><td colspan="2" class="text-center text-danger py-4">Erro ao calcular custos por veículo.</td></tr>';
      return;
    }

    const totais = new Map();
    (data || []).forEach(movimento => {
      const veiculo = movimento.ordens_servico?.veiculos;
      if (!veiculo) return;
      const nome = `${veiculo.placa} · ${veiculo.modelo}`;
      totais.set(nome, (totais.get(nome) || 0) + Number(movimento.custo_total || 0));
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
})();
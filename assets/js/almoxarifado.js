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
  let usuariosCache = [];
  let funcionariosCache = [];
  let funcoesCache = [];

  function rotuloFuncionario(funcionario) {
    return `${funcionario.nome_funcionario} (${funcionario.cod_funcionario})`;
  }

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
      .select('quantidade, quantidade_utilizada, custo_unitario, ordens_servico!inner(status, veiculos(placa, modelo))');
    if (error) {
      tbody.innerHTML = '<tr><td colspan="3" class="text-center text-danger py-4">Erro ao calcular custos por veículo.</td></tr>';
      return;
    }

    const totais = new Map();
    (data || []).forEach(movimento => {
      const ordem = movimento.ordens_servico;
      const veiculo = ordem?.veiculos;
      if (!veiculo) return;
      const nome = `${veiculo.placa} · ${veiculo.modelo}`;
      const total = totais.get(nome) || { real: 0, estimado: 0 };
      if (ordem.status === 'Concluída') {
        total.real += Number(movimento.quantidade_utilizada || 0) * Number(movimento.custo_unitario || 0);
      } else {
        total.estimado += Number(movimento.quantidade || 0) * Number(movimento.custo_unitario || 0);
      }
      totais.set(nome, total);
    });
    const linhas = [...totais.entries()].sort((a, b) => (b[1].real + b[1].estimado) - (a[1].real + a[1].estimado));
    tbody.innerHTML = linhas.length ? linhas.map(([veiculo, custos]) =>
      `<tr><td class="fw-bold">${escapeHTML(veiculo)}</td><td class="text-end fw-bold">${moeda(custos.real)}</td><td class="text-end fw-bold">${moeda(custos.estimado)}</td></tr>`
    ).join('') : '<tr><td colspan="3" class="text-center text-muted py-4">Ainda não há peças liberadas para ordens vinculadas a veículos.</td></tr>';
  }

  function atualizarOpcoesUsuarios() {
    const selectUsuario = document.getElementById('usuario-vinculo');
    const selectFuncionario = document.getElementById('funcionario-mecanico');
    if (!selectUsuario || !selectFuncionario) return;
    const funcionarioId = selectFuncionario.value;
    const funcionarioSelecionado = funcionariosCache.find(item => item.id === funcionarioId);
    const desejado = funcionarioSelecionado?.user_id || '';
    const vinculos = new Map(funcionariosCache.filter(funcionario => funcionario.user_id).map(funcionario => [funcionario.user_id, funcionario]));
    selectUsuario.innerHTML = '<option value="">Sem vínculo</option>' + usuariosCache.map(usuario => {
      const dono = vinculos.get(usuario.id);
      const sufixo = dono && dono.id !== funcionarioId ? ` • vinculado a ${dono.nome_funcionario}` : '';
      return `<option value="${escapeHTML(usuario.id)}">${escapeHTML(usuario.nome)} (${escapeHTML(usuario.role)})${escapeHTML(sufixo)}</option>`;
    }).join('');
    selectUsuario.value = desejado;
  }

  function aplicarSelecaoFuncionario() {
    const busca = document.getElementById('funcionario-mecanico-busca');
    const funcionarioId = document.getElementById('funcionario-mecanico');
    if (!busca || !funcionarioId) return;
    const termo = busca.value.trim().toLocaleLowerCase('pt-BR');
    const funcionario = funcionariosCache.find(item =>
      rotuloFuncionario(item).toLocaleLowerCase('pt-BR') === termo
    );
    funcionarioId.value = funcionario?.id || '';
    const selectFuncao = document.getElementById('funcao-oficina');
    if (selectFuncao) {
      selectFuncao.value = funcionario?.funcao_id || '';
    }
    atualizarOpcoesUsuarios();
  }

  async function carregarFuncoes() {
    const select = document.getElementById('funcao-oficina');
    if (!select) return;
    const anterior = select.value;
    const { data, error } = await window.db
      .from('funcoes_oficina')
      .select('id, nome')
      .eq('ativo', true)
      .order('nome');
    if (error) {
      mensagem('msg-mecanico', error.message, 'error');
      return;
    }
    funcoesCache = data || [];
    select.innerHTML = '<option value="">Sem função (fora da manutenção)</option>' + funcoesCache.map(funcao =>
      `<option value="${escapeHTML(funcao.id)}">${escapeHTML(funcao.nome)}</option>`
    ).join('');
    if (anterior) select.value = anterior;
  }

  async function carregarUsuarios() {
    const select = document.getElementById('usuario-vinculo');
    if (!select) return;
    const { data, error } = await window.db.rpc('listar_usuarios_app');
    if (error) {
      select.innerHTML = '<option value="">Erro ao carregar usuários</option>';
      mensagem('msg-vinculo', error.message, 'error');
      return;
    }
    usuariosCache = data || [];
    atualizarOpcoesUsuarios();
  }

  async function carregarFuncionarios() {
    const busca = document.getElementById('funcionario-mecanico-busca');
    const funcionarioId = document.getElementById('funcionario-mecanico');
    const lista = document.getElementById('funcionarios-oficina-lista');
    if (!busca || !funcionarioId || !lista) return;
    const anterior = funcionarioId.value;
    const { data, error } = await window.db
      .from('funcionarios')
      .select('id, cod_funcionario, nome_funcionario, funcao_id, user_id')
      .order('nome_funcionario');
    if (error) {
      busca.value = '';
      busca.placeholder = 'Erro ao carregar funcionários';
      mensagem('msg-mecanico', error.message, 'error');
      return;
    }
    funcionariosCache = data || [];
    lista.innerHTML = funcionariosCache.map(funcionario =>
      `<option value="${escapeHTML(rotuloFuncionario(funcionario))}"></option>`
    ).join('');
    busca.oninput = aplicarSelecaoFuncionario;
    busca.onchange = aplicarSelecaoFuncionario;
    const selecionado = funcionariosCache.find(item => item.id === anterior);
    busca.placeholder = 'Digite o nome do funcionário...';
    busca.value = selecionado ? rotuloFuncionario(selecionado) : '';
    funcionarioId.value = selecionado?.id || '';
    aplicarSelecaoFuncionario();
  }

  async function carregarOrdensLiberacao() {
    const container = document.getElementById('lista-os-liberacao');
    const [{ data: ordens, error: erroOrdens }, { data: mecanicos, error: erroMecanicos }] = await Promise.all([
      window.db.from('ordens_servico')
        .select('id, descricao, created_at, status, veiculos(placa, modelo), mecanico_id, mecanico_funcionario:funcionarios!ordens_servico_mecanico_id_fkey(nome_funcionario), ordens_servico_mecanicos(funcionario_id, especialidade, mecanico:funcionarios!ordens_servico_mecanicos_funcionario_id_fkey(nome_funcionario, cod_funcionario)), itens_ordem_servico(id, quantidade, quantidade_utilizada, pecas(codigo, nome, unidade))')
        .eq('status', 'Pendente')
        .order('created_at', { ascending: true }),
      window.db.from('funcionarios').select('id, cod_funcionario, nome_funcionario, funcoes_oficina(nome)').not('funcao_id', 'is', null).order('nome_funcionario')
    ]);

    if (erroOrdens || erroMecanicos) {
      const detalhes = [
        erroOrdens && `OS: ${erroOrdens.message}`,
        erroMecanicos && `Equipe: ${erroMecanicos.message}`
      ].filter(Boolean).join(' | ');
      container.innerHTML = `<p class="text-danger">Erro ao carregar dados: ${escapeHTML(detalhes)}</p>`;
      return;
    }
    if (!ordens?.length) {
      container.innerHTML = '<p class="text-muted">Não há ordens pendentes para separar peças.</p>';
      return;
    }

    const mecanicoOptions = (mecanicos || []).map(mecanico =>
      `<option value="${escapeHTML(mecanico.id)}" data-especialidade="${escapeHTML(mecanico.funcoes_oficina?.nome || '')}">${escapeHTML(mecanico.nome_funcionario)} (${escapeHTML(mecanico.cod_funcionario)})</option>`
    ).join('');
    const pecaOptions = pecasCache.filter(peca => Number(peca.saldo_estoque) > 0).map(peca =>
      `<option value="${escapeHTML(peca.id)}" data-saldo="${escapeHTML(peca.saldo_estoque)}">${escapeHTML(peca.codigo)} · ${escapeHTML(peca.nome)} (${Number(peca.saldo_estoque).toLocaleString('pt-BR')} ${escapeHTML(peca.unidade)})</option>`
    ).join('');

    container.innerHTML = ordens.map(os => {
      const placa = os.veiculos ? `${os.veiculos.placa} (${os.veiculos.modelo})` : 'Veículo não identificado';
      const itens = os.itens_ordem_servico || [];
      const itensHtml = itens.length ? itens.map(item =>
        `${escapeHTML(item.pecas?.nome || 'Peça')} × ${Number(item.quantidade).toLocaleString('pt-BR')} ${escapeHTML(item.pecas?.unidade || '')}`
      ).join('<br>') : 'Nenhuma peça associada — a OS pode ser salva apenas com a equipe.';
      const equipe = os.ordens_servico_mecanicos || [];
      const equipeHtml = equipe.length
        ? equipe.map(item => `<span class="badge text-bg-light border me-1 mb-1">${escapeHTML(item.mecanico?.nome_funcionario || 'Membro')} · ${escapeHTML(item.especialidade)}</span>`).join('')
        : '<span class="text-muted">Nenhum membro associado.</span>';
      const linhasMecanicos = equipe.length
        ? equipe.map(item => `<div class="row g-2 align-items-end release-mechanic-line mb-2">
            <div class="col-7"><label class="form-label small">Membro da equipe</label><select class="form-select release-mechanic" required><option value="">Selecione...</option>${mecanicoOptions}</select></div>
            <div class="col-5"><label class="form-label small">Especialidade</label><input class="form-control release-specialty" maxlength="80" required value="${escapeHTML(item.especialidade)}" placeholder="Ex.: Eletricista"></div>
          </div>`).join('')
        : `<div class="row g-2 align-items-end release-mechanic-line mb-2">
            <div class="col-7"><label class="form-label small">Membro da equipe</label><select class="form-select release-mechanic" required><option value="">Selecione...</option>${mecanicoOptions}</select></div>
            <div class="col-5"><label class="form-label small">Especialidade</label><input class="form-control release-specialty" maxlength="80" required placeholder="Ex.: Eletricista"></div>
          </div>`;
      const dataAbertura = os.created_at ? new Date(os.created_at).toLocaleString('pt-BR') : '—';
      return `<article class="warehouse-release-card">
        <h3>${escapeHTML(placa)}</h3>
        <p class="small text-muted mb-1">OS #${escapeHTML(String(os.id).slice(-8))} · Aberta em ${escapeHTML(dataAbertura)}</p>
        <p class="small mb-2">${escapeHTML(os.descricao)}</p>
        <div class="small mb-2"><strong>Equipe:</strong><div>${equipeHtml}</div></div>
        <div class="warehouse-release-items"><strong>Peças liberadas</strong><br>${itensHtml}</div>
        <form class="warehouse-release-form" data-release-os="${escapeHTML(os.id)}">
          <label class="form-label">Equipe e especialidades</label>
          <div class="release-mechanics">${linhasMecanicos}</div>
          <button type="button" class="btn btn-sm btn-outline-secondary btn-add-mechanic mb-2">Adicionar membro</button>
          <div class="release-lines d-flex flex-column gap-2"></div>
          <div class="d-flex gap-2 mt-2">
            <button type="button" class="btn btn-sm btn-outline-secondary btn-add-release" ${pecaOptions ? '' : 'disabled'}><i class="bi bi-plus-lg me-1"></i>Adicionar peça</button>
            <button type="submit" class="btn btn-sm btn-warehouse">${itens.length ? 'Salvar equipe / liberar peças' : 'Salvar equipe e liberar peças'}</button>
          </div>
          <span class="form-feedback" aria-live="polite"></span>
        </form>
      </article>`;
    }).join('');

    container.querySelectorAll('[data-release-os]').forEach(form => {
      const os = ordens.find(ordem => ordem.id === form.dataset.releaseOs);
      (os?.ordens_servico_mecanicos || []).forEach((item, index) => {
        const select = form.querySelectorAll('.release-mechanic')[index];
        if (select) select.value = item.funcionario_id;
      });
    });
  }

  document.getElementById('lista-os-liberacao').addEventListener('change', event => {
    const select = event.target.closest('.release-mechanic');
    if (!select) return;
    const especialidade = select.selectedOptions[0]?.dataset.especialidade || '';
    if (especialidade) select.closest('.release-mechanic-line').querySelector('.release-specialty').value = especialidade;
  });

  document.getElementById('lista-os-liberacao').addEventListener('click', event => {
    const addMechanic = event.target.closest('.btn-add-mechanic');
    if (addMechanic) {
      const linhaBase = addMechanic.closest('form').querySelector('.release-mechanic-line');
      const linha = linhaBase.cloneNode(true);
      linha.querySelector('.release-mechanic').value = '';
      linha.querySelector('.release-specialty').value = '';
      addMechanic.closest('form').querySelector('.release-mechanics').appendChild(linha);
      return;
    }
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
    const linhasEquipe = [...form.querySelectorAll('.release-mechanic-line')];
    const mecanicos = linhasEquipe.map(linha => ({
      funcionario_id: linha.querySelector('.release-mechanic').value,
      especialidade: linha.querySelector('.release-specialty').value.trim()
    }));
    if (mecanicos.some(item => !item.funcionario_id || !item.especialidade)) {
      form.querySelector('.form-feedback').textContent = 'Selecione cada membro e informe sua especialidade.';
      return;
    }
    if (new Set(mecanicos.map(item => item.funcionario_id)).size !== mecanicos.length) {
      form.querySelector('.form-feedback').textContent = 'Não repita o mesmo membro na equipe.';
      return;
    }
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
      p_mecanicos: mecanicos,
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
    const funcionarioId = document.getElementById('funcionario-mecanico').value;
    if (!funcionarioId) {
      mensagem('msg-mecanico', 'Digite e selecione um funcionário cadastrado na lista.', 'error');
      document.getElementById('funcionario-mecanico-busca').focus();
      return;
    }
    const funcaoSelecionada = document.getElementById('funcao-oficina').value;
    button.disabled = true;
    mensagem('msg-mecanico', '', '');
    const { error } = await window.db.rpc('definir_funcionario_funcao', {
      p_funcionario_id: funcionarioId,
      p_funcao_id: funcaoSelecionada ? Number(funcaoSelecionada) : null
    });
    if (error) mensagem('msg-mecanico', error.message, 'error');
    else {
      mensagem('msg-mecanico', 'Função atualizada.', 'success');
      await carregarFuncionarios();
    }
    button.disabled = false;
  });
  document.getElementById('btn-nova-funcao').addEventListener('click', async () => {
    const button = document.getElementById('btn-nova-funcao');
    const input = document.getElementById('nova-funcao');
    const nome = input.value.trim();
    if (!nome) {
      mensagem('msg-funcao', 'Informe o nome da função.', 'error');
      return;
    }
    button.disabled = true;
    mensagem('msg-funcao', '', '');
    const { data, error } = await window.db.rpc('criar_funcao_oficina', { p_nome: nome });
    if (error) mensagem('msg-funcao', error.message, 'error');
    else {
      input.value = '';
      await carregarFuncoes();
      document.getElementById('funcao-oficina').value = String(data);
      mensagem('msg-funcao', `Função "${nome}" disponível. Selecione o funcionário e clique em Salvar.`, 'success');
    }
    button.disabled = false;
  });
  document.getElementById('btn-vincular-usuario').addEventListener('click', async () => {
    const button = document.getElementById('btn-vincular-usuario');
    const funcionarioId = document.getElementById('funcionario-mecanico').value;
    if (!funcionarioId) {
      mensagem('msg-vinculo', 'Selecione um funcionário acima.', 'error');
      return;
    }
    button.disabled = true;
    mensagem('msg-vinculo', '', '');
    const { error } = await window.db.rpc('definir_funcionario_vinculo', {
      p_funcionario_id: funcionarioId,
      p_user_id: document.getElementById('usuario-vinculo').value || null
    });
    if (error) mensagem('msg-vinculo', error.message, 'error');
    else {
      mensagem('msg-vinculo', 'Vínculo atualizado.', 'success');
      await carregarFuncionarios();
    }
    button.disabled = false;
  });
  document.getElementById('btn-sair').addEventListener('click', async () => {
    await window.db.auth.signOut();
    window.location.replace('login.html');
  });

  const cargas = [carregarPecas(), carregarMovimentacoes(), carregarCustosPorVeiculo()];
  if (perfil.role === 'admin') {
    await Promise.all([carregarFuncoes(), carregarUsuarios()]);
    cargas.push(carregarFuncionarios());
  }
  await Promise.all(cargas);
  await carregarOrdensLiberacao();
})();

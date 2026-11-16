// ============================================
// LOGIN
// ============================================
console.log('🟢 auth.js carregado');

function iniciarLogin() {
  const form = document.getElementById('form-login');
  if (!form) {
    console.error('❌ Formulário #form-login não encontrado.');
    return;
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault();

    const email = document.getElementById('email').value.trim();
    const senha = document.getElementById('senha').value;
    const msg   = document.getElementById('msg-erro');
    const btn   = document.getElementById('btn-entrar');

    msg.textContent = '';
    btn.disabled = true;
    btn.textContent = 'Entrando...';

    const { data, error } = await window.db.auth.signInWithPassword({
      email, password: senha
    });

    if (error) {
      console.error('Erro no login:', error);
      msg.textContent = 'Email ou senha inválidos.';
      btn.disabled = false;
      btn.textContent = 'Entrar';
      return;
    }

    const { data: perfil } = await window.db
      .from('profiles')
      .select('role')
      .eq('id', data.user.id)
      .single();

    const role = perfil?.role || 'motorista';

    if (role === 'admin' || role === 'manutencao') {
      window.location.replace('dashboard.html');
    } else if (role === 'porteiro') {
      window.location.replace('portaria.html');
    } else {
      window.location.replace('index.html');
    }
  });
}

if (window.__SUPABASE_PRONTO__ && window.db) {
  iniciarLogin();
} else {
  window.addEventListener('supabase-ready', iniciarLogin);
}
(() => {
  const sb = window.qashflowSupabase;
  if (!sb) return;
  const $ = (s, r=document) => r.querySelector(s);
  const $$ = (s, r=document) => [...r.querySelectorAll(s)];
  const money = n => `$${Number(n||0).toFixed(2)}`;
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));
  const fmt = d => d ? new Date(d).toLocaleString() : '—';
  const msg = e => e?.message || e?.error_description || 'Something went wrong.';
  const toast = m => window.showToast ? window.showToast(m) : alert(m);

  const authStyle = document.createElement('style');
  authStyle.textContent = `.qf-auth{position:fixed;inset:0;background:#020712cc;backdrop-filter:blur(12px);z-index:9999;display:none;align-items:center;justify-content:center;padding:18px}.qf-auth.show{display:flex}.qf-auth-box{width:min(430px,100%);background:#0d192a;border:1px solid #29415c;border-radius:20px;padding:24px;box-shadow:0 30px 100px #0008}.qf-auth-box h2{margin:0 0 6px}.qf-auth-box p{color:#8ea2bc;font-size:12px}.qf-auth-box input{width:100%;margin:7px 0;padding:12px;border-radius:10px;border:1px solid #29415c;background:#081423;color:#eef6ff}.qf-auth-actions{display:flex;gap:8px;margin-top:10px}.qf-auth-actions button{flex:1}.qf-auth-switch{background:none;border:0;color:#38e1e8;margin-top:12px;width:100%;font-size:12px}.qf-userbar{display:flex;align-items:center;gap:8px}.qf-logout{border:1px solid #29415c;background:#101f33;color:#cfe2f5;border-radius:9px;padding:7px 10px;font-size:11px}.qf-loading{opacity:.6;pointer-events:none}`;
  document.head.appendChild(authStyle);
  const auth = document.createElement('div'); auth.className='qf-auth';
  auth.innerHTML = `<div class="qf-auth-box"><h2 id="qfAuthTitle">Sign in</h2><p id="qfAuthHelp">Use your Qashflow account to continue.</p><input id="qfName" placeholder="Full name" style="display:none"><input id="qfReferral" placeholder="Referral code (optional)" style="display:none"><input id="qfEmail" type="email" placeholder="Email address"><input id="qfPassword" type="password" placeholder="Password (minimum 6 characters)"><div class="qf-auth-actions"><button class="secondary" id="qfAuthCancel">Cancel</button><button class="primary" id="qfAuthSubmit">Sign in</button></div><button class="qf-auth-switch" id="qfAuthSwitch">Create a new account</button></div>`;
  document.body.appendChild(auth);
  let signup=false;
  const setAuthMode = v => { signup=v; $('#qfAuthTitle').textContent=v?'Create account':'Sign in'; $('#qfAuthSubmit').textContent=v?'Create account':'Sign in'; $('#qfAuthSwitch').textContent=v?'Already have an account? Sign in':'Create a new account'; $('#qfName').style.display=v?'block':'none'; $('#qfReferral').style.display=v?'block':'none'; };
  $('#qfAuthCancel').onclick=()=>auth.classList.remove('show'); $('#qfAuthSwitch').onclick=()=>setAuthMode(!signup);
  const openAuth = () => { setAuthMode(false); auth.classList.add('show'); $('#qfEmail').focus(); };
  $('#qfAuthSubmit').onclick=async()=>{
    const email=$('#qfEmail').value.trim(), password=$('#qfPassword').value, name=$('#qfName').value.trim(), referral=$('#qfReferral').value.trim();
    if(!email||!password) return toast('Email and password are required.');
    $('#qfAuthSubmit').disabled=true;
    try {
      if(signup){ const {data,error}=await sb.auth.signUp({email,password,options:{data:{display_name:name,referral_code:referral||null}}}); if(error) throw error; if(!data.session) toast('Account created. Check your email if confirmation is enabled, then sign in.'); else toast('Account created successfully.'); }
      else { const {error}=await sb.auth.signInWithPassword({email,password}); if(error) throw error; toast('Signed in successfully.'); }
      auth.classList.remove('show'); await refresh();
    } catch(e){ toast(msg(e)); } finally { $('#qfAuthSubmit').disabled=false; }
  };

  function addLogout(){
    const top=$('.top-actions'); if(!top || $('.qf-logout',top)) return;
    const b=document.createElement('button'); b.className='qf-logout'; b.textContent='Sign out'; b.onclick=async()=>{await sb.auth.signOut(); toast('Signed out.'); openAuth();}; top.appendChild(b);
  }
  function setUser(profile,email){
    const labels=$$('.user-label'); labels.forEach(x=>{x.childNodes[0].textContent=(profile?.display_name||email?.split('@')[0]||'Member')+' '; const sp=x.querySelector('span'); if(sp) sp.textContent=profile?.referral_code||'Member';});
    $$('.avatar').forEach(x=>x.textContent=(profile?.display_name||'QF').split(/\s+/).map(v=>v[0]).join('').slice(0,2).toUpperCase());
    const ref=$('#refLink'); if(ref && profile?.referral_code) ref.value=`${location.origin}${location.pathname}?ref=${profile.referral_code}`;
  }
  async function session(){ const {data}=await sb.auth.getSession(); return data.session; }
  async function profile(uid){ const {data,error}=await sb.from('profiles').select('*').eq('id',uid).single(); if(error) throw error; return data; }
  async function requireAuth(){ const s=await session(); if(!s){openAuth();return null;} return s; }

  function pageRows(pageId){ const p=$('#'+pageId); return p ? $('tbody',p) : null; }
  function tableEmpty(tbody, text){tbody.innerHTML=`<tr><td colspan="5"><div class="empty-state"><h3>${esc(text)}</h3></div></td></tr>`;}

  async function loadDashboard(){
    const s=await session(); if(!s) return;
    const {data,error}=await sb.rpc('get_my_dashboard'); if(error) return toast(msg(error));
    const p=$('#page-dashboard'); const vals=$$('.stat-value',p); if(vals.length>=4){vals[0].textContent=money(data.balance);vals[1].textContent=data.active_plans;vals[2].textContent=money(data.earnings);vals[3].textContent=data.team_count;}
    const active=$('.status',p); if(active) active.textContent=data.active_plans?`${data.active_plans} active plan${data.active_plans>1?'s':''}`:'No active plans';
    const ref=$('#refLink'); if(ref) ref.disabled=false;
  }

  function bindDeposit(){
    const p=$('#page-deposit'); if(!p||p.dataset.bound)return; p.dataset.bound=1;
    const fields=$$('.field',p); const method=$('select',fields[0]), amount=$('input',fields[1]), hash=$('input',fields[2]), wallet=$('input',fields[3]);
    const btn=$$('button',p).find(b=>/submit deposit/i.test(b.textContent));
    btn?.addEventListener('click',async()=>{ if(!await requireAuth())return; const a=Number(amount.value); if(!a)return toast('Enter a deposit amount.'); const {error}=await sb.rpc('create_deposit_request',{p_amount:a,p_currency:'USD',p_payment_method:method.value,p_wallet_address:wallet.value,p_transaction_hash:hash.value}); if(error)return toast(msg(error)); amount.value='';hash.value='';wallet.value='';toast('Deposit request submitted.'); await loadDepositHistory(); });
  }
  async function loadDepositHistory(){ const s=await session();if(!s)return; const {data,error}=await sb.from('deposit_requests').select('*').eq('user_id',s.user.id).order('created_at',{ascending:false}).limit(100); if(error)return; const t=pageRows('page-deposit-history');if(!t)return;if(!data.length)return tableEmpty(t,'No deposit records');t.innerHTML=data.map(r=>`<tr><td>${esc(r.id.slice(0,8))}</td><td>${esc(r.payment_method)}</td><td>${money(r.amount)}</td><td>${fmt(r.created_at)}</td><td><span class="status">${esc(r.status)}</span></td></tr>`).join(''); }

  async function loadPlans(){ const s=await session();if(!s)return; const {data,error}=await sb.from('plans').select('*').eq('is_active',true).order('created_at'); if(error)return; const p=$('#page-plans'); const box=$('.section-grid',p); if(box){box.innerHTML=data.map((x,i)=>`<div class="card plan-card ${i===1?'featured':''}" data-plan-id="${x.id}"><div class="plan-tag">Package ${String(i+1).padStart(2,'0')}${i===1?' · Standard':''}</div><h3>${esc(x.name)}</h3><div class="plan-range">$${Number(x.min_amount).toFixed(0)} <small>— $${Number(x.max_amount).toFixed(0)}</small></div><p>Package duration: ${x.duration_days} days</p><div class="plan-features"><div><span class="check">✓</span> Separate plan record</div><div><span class="check">✓</span> Individual cycle tracking</div><div><span class="check">✓</span> Expiry date shown in account</div></div><button class="${i===1?'primary':'secondary'} qf-select-plan">Select package</button></div>`).join(''); $$('.qf-select-plan',box).forEach((b,i)=>b.onclick=async()=>{if(!await requireAuth())return;const plan=data[i];const amount=Number(prompt(`Enter amount for ${plan.name} (${plan.min_amount}-${plan.max_amount} USD):`));if(!amount)return;const {error}=await sb.rpc('activate_plan',{p_plan_id:plan.id,p_amount:amount});if(error)return toast(msg(error));toast('Plan activated successfully.');await refresh();}); }
    const {data:subs}=await sb.from('plan_subscriptions').select('*,plans(name)').eq('user_id',s.user.id).order('created_at',{ascending:false}); const activeBox=$('.empty-state',p)?.parentElement; if(activeBox&&subs?.length){activeBox.innerHTML=subs.map(x=>`<div class="activity"><div class="activity-info"><b>${esc(x.plans?.name||'Plan')}</b><span>${esc(x.status)} · ${fmt(x.activated_at)}</span></div><div class="activity-amount">${money(x.principal_amount)}<small>${x.expires_at?'Expires '+fmt(x.expires_at):''}</small></div></div>`).join('');}
  }

  function bindWithdrawal(){ const p=$('#page-withdraw');if(!p||p.dataset.bound)return;p.dataset.bound=1;const fields=$$('.field',p);const amount=$('input',fields[0]), network=$('select',fields[1]), dest=$('input',fields[2]);const btn=$$('button',p).find(b=>/submit withdrawal/i.test(b.textContent));btn?.addEventListener('click',async()=>{if(!await requireAuth())return;const a=Number(amount.value);if(!a)return toast('Enter a withdrawal amount.');const {error}=await sb.rpc('create_withdrawal_request',{p_amount:a,p_currency:'USD',p_destination_address:dest.value});if(error)return toast(msg(error));amount.value='';dest.value='';toast('Withdrawal request submitted.');await loadWithdrawalHistory();}); }
  async function loadWithdrawalHistory(){const s=await session();if(!s)return;const {data,error}=await sb.from('withdrawal_requests').select('*').eq('user_id',s.user.id).order('created_at',{ascending:false}).limit(100);if(error)return;const t=pageRows('page-withdraw-history');if(!t)return;if(!data.length)return tableEmpty(t,'No withdrawal records');t.innerHTML=data.map(r=>`<tr><td>${esc(r.id.slice(0,8))}</td><td>USD</td><td>${money(r.amount)}</td><td>${fmt(r.created_at)}</td><td><span class="status">${esc(r.status)}</span></td></tr>`).join('');}
  async function loadTransactions(){const s=await session();if(!s)return;const {data,error}=await sb.from('transaction_ledger').select('*').eq('user_id',s.user.id).order('created_at',{ascending:false}).limit(100);if(error)return;const t=pageRows('page-transactions');if(!t)return;if(!data.length)return tableEmpty(t,'No transactions to show');t.innerHTML=data.map(r=>`<tr><td>${esc(r.id.slice(0,8))}</td><td>${esc(r.entry_type)}</td><td class="${Number(r.amount)>=0?'positive':'negative'}">${money(r.amount)}</td><td>${fmt(r.created_at)}</td><td><span class="status">Recorded</span></td></tr>`).join('');}

  async function loadTeam(){const s=await session();if(!s)return;const {data,error}=await sb.rpc('get_my_dashboard');if(error)return;const p=$('#page-team');const vals=$$('.stat-value',p);if(vals.length>=4){vals[0].textContent=data.level1;vals[1].textContent=data.level2;vals[2].textContent=data.level3;const {data:com}=await sb.from('referral_commissions').select('amount').eq('beneficiary_user_id',s.user.id);vals[3].textContent=money((com||[]).reduce((a,x)=>a+Number(x.amount||0),0));} }
  async function loadRewards(){const s=await session();if(!s)return;const {data,error}=await sb.from('rewards').select('*').eq('is_active',true).order('required_active_members');if(error)return;const dash=await sb.rpc('get_my_dashboard');const current=dash.data?.team_count||0;const p=$('#page-rewards');const box=$('.section-grid',p);if(!box)return;box.innerHTML=data.map((r,i)=>`<div class="card plan-card ${i===2?'featured':''}" data-reward-id="${r.id}"><div class="reward-medal">${i%2?'✧':'✦'}</div><h3>${esc(r.name)}</h3><div class="plan-range">${money(r.reward_amount)}</div><p>Reach ${r.required_active_members} active team members.</p><div class="plan-features"><div><span class="check">✓</span> Required: ${r.required_active_members} active members</div><div><span>•</span> Current: ${current} members</div></div><button class="${i===2?'primary':'secondary'} qf-claim-reward">Claim reward</button></div>`).join('');$$('.qf-claim-reward',box).forEach((b,i)=>b.onclick=async()=>{if(!await requireAuth())return;const {error}=await sb.rpc('claim_reward',{p_reward_id:data[i].id});if(error)return toast(msg(error));toast('Reward claimed.');await refresh();});}
  async function loadProfile(){const s=await session();if(!s)return;const p=await profile(s.user.id);const page=$('#page-profile');const fields=$$('.field input',page);if(fields.length>=4){fields[0].value=p.display_name||'';fields[1].value=s.user.email||'';fields[2].value=p.id;fields[3].value=p.referral_code||'';}const btn=$$('button',page).find(b=>/save changes/i.test(b.textContent));if(btn&&!btn.dataset.bound){btn.dataset.bound=1;btn.onclick=async()=>{const {error}=await sb.from('profiles').update({display_name:fields[0].value.trim()}).eq('id',s.user.id);if(error)return toast(msg(error));toast('Profile saved.');await refresh();};}}
  async function bindSupport(){const p=$('#page-support');if(!p||p.dataset.bound)return;p.dataset.bound=1;const fields=$$('.field',p);const topic=$('select',fields[0]),ref=$('input',fields[1]),body=$('textarea',fields[2]),btn=$$('button',p).find(b=>/send message/i.test(b.textContent));btn?.addEventListener('click',async()=>{if(!await requireAuth())return;if(!body.value.trim())return toast('Write your message first.');const s=await session();const {error}=await sb.from('support_tickets').insert({user_id:s.user.id,topic:topic.value,transaction_reference:ref.value.trim()||null,message:body.value.trim()});if(error)return toast(msg(error));body.value='';ref.value='';toast('Support message sent.');});}

  async function refresh(){
    const s=await session(); if(!s){ setUser(null,null); return; }
    try { const p=await profile(s.user.id); setUser(p,s.user); addLogout(); await Promise.all([loadDashboard(),loadDepositHistory(),loadWithdrawalHistory(),loadTransactions(),loadPlans(),loadTeam(),loadRewards(),loadProfile()]); bindDeposit();bindWithdrawal();bindSupport(); } catch(e){ toast(msg(e)); }
  }
  $$('#copyRef').forEach(b=>b.addEventListener('click',()=>{const i=$('#refLink');if(!i?.value||i.value.startsWith('Sign in'))return openAuth();navigator.clipboard?.writeText(i.value).then(()=>toast('Referral link copied.')).catch(()=>{i.select();document.execCommand('copy');toast('Referral link copied.');});}));
  sb.auth.onAuthStateChange(()=>setTimeout(refresh,0));
  refresh();
})();

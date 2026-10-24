'use strict';

if ('serviceWorker' in navigator) {
 window.addEventListener('load', () => navigator.serviceWorker.register('/static/sw.js',{scope:'/'}).then(async rootReg=>{
  const regs=await navigator.serviceWorker.getRegistrations();
  await Promise.all(regs.filter(reg=>reg!==rootReg&&reg.scope===new URL('/static/',location.origin).href).map(reg=>reg.unregister()));
 }).catch(() => {}));
}

const $ = (q, root = document) => root.querySelector(q);
const $$ = (q, root = document) => [...root.querySelectorAll(q)];
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
 home:'M3 10 12 3l9 7M5 9v11h5v-6h4v6h5V9', heart:'M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z',
 photo:'M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1ZM3 16l6-6 6 6 3-3 3 3M16 7h.01',
 chat:'M21 11.5a8.5 8.5 0 0 1-8.5 8.5 10 10 0 0 1-4-.9L3 21l1.9-5.5a10 10 0 0 1-.9-4A8.5 8.5 0 0 1 12.5 3H13a8.5 8.5 0 0 1 8 8v.5Z',
 book:'M4 3h6a3 3 0 0 1 3 3v15a4 4 0 0 0-4-2H3V3h1Zm9 3a3 3 0 0 1 3-3h5v16h-4a4 4 0 0 0-4 2',
 plus:'M12 5v14M5 12h14', arrow:'m9 5 7 7-7 7', back:'m15 5-7 7 7 7', calendar:'M5 5h14a2 2 0 0 1 2 2v13H3V7a2 2 0 0 1 2-2ZM7 3v4M17 3v4M3 11h18M8 15h2M14 15h2',
 bell:'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4', lock:'M6 10V7a6 6 0 0 1 12 0v3M4 10h16v12H4V10Zm8 5v3',
 close:'m6 6 12 12M6 18 18 6', edit:'m16 3 5 5-12 12-6 1 1-6L16 3Zm-2 2 5 5', trash:'M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7',
 mic:'M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0V5ZM5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8', send:'m22 2-7 20-4-9-9-4 20-7ZM11 13 22 2',
 star:'m12 3 3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1 3-6', gear:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8ZM9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1 1-3', download:'M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5', clock:'M12 8v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z', check:'m5 12 4 4L19 6',
 moon:'M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z', sun:'M12 4V2M12 22v-2M4 12H2M22 12h-2M5 5 4 4M20 20l-1-1M19 5l1-1M4 20l1-1M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z', info:'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20Zm0-6v-4m0-4h.01',
 chat:'M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.4 8.4 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5Z'
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name] || paths.heart}"/></svg>`;
const state = {page:'home', tab:'', me:null, records:[], photos:[], notices:[], channels:[], deliveries:[], webpush:null, nativePush:null, dashboard:null, weekly:null, weekOffset:0, timelinePosts:[],timelineCursor:null,timelineHasMore:false,stream:null, online:navigator.onLine};
let modalCleanup = null, focusReturn = null, refreshing = false;

function clearUserLocalData(userId) {
 if (!userId) return;
 const prefixes = [`composer:${userId}:`, `pending-chat:${userId}`, `chat-text:${userId}`, `stickers:${userId}`];
 for (const key of Object.keys(localStorage)) if (prefixes.some(prefix => key.startsWith(prefix))) localStorage.removeItem(key);
}
async function clearPrivateSession(userId) {
 clearUserLocalData(userId);
 state.stream?.close(); state.stream=null;
 clearTimeout(state.sseTimer); clearTimeout(state.ntfyTimer);
 clearInterval(keepAliveTimer); keepAliveTimer=null;
 try { ntfyWs?.close(); } catch {}
 try {
  if (navigator.serviceWorker) {
   const reg=await navigator.serviceWorker.ready;
   (navigator.serviceWorker.controller||reg.active)?.postMessage({type:'CLEAR_PRIVATE_CACHE'});
  }
 } catch {}
 try {
  if (window.Capacitor?.isNativePlatform?.()) {
   const push=nativePushBridge();if(push?.clearTopic)await push.clearTopic();
   const bg=Capacitor.Plugins?.BackgroundMode;
   if (bg?.disable) await bg.disable();
  }
 } catch {}
 state.records=[]; state.photos=[]; state.notices=[]; state.channels=[]; state.deliveries=[];
}

async function api(path, options = {}) {
 const result = await fetch('/api' + path, {...options, headers:{'Content-Type':'application/json','X-Love-Space':'1',...(options.headers || {})}});
 if (!result.ok) {
  let data; try {data = await result.json();} catch {data = {};}
  if (result.status === 401 && state.me) {const userId=state.me.user.id;state.me=null;await clearPrivateSession(userId);await boot();}
  throw new Error(typeof data.detail === 'string' ? data.detail : '请检查输入，稍后再试');
 }
 return result.json();
}
const post = (path, data={}) => api(path,{method:'POST',body:JSON.stringify(data)});
const put = (path, data={}) => api(path,{method:'PUT',body:JSON.stringify(data)});
const del = path => api(path,{method:'DELETE'});
function toast(text) { const el=$('#toast'); el.textContent=text; el.classList.add('show'); clearTimeout(toast.timer); toast.timer=setTimeout(()=>el.classList.remove('show'),3500); }
const person = id => state.me?.users.find(u=>u.id===id) || {name:'亲爱的',id};
const avatar = (id, extra='') => {const u=person(id);return `<span class="avatar ${extra}">${u.avatar?`<img src="/media/${esc(u.avatar)}?preview=true" alt="${esc(u.name)}的头像">`:esc(u.name.slice(0,1))}</span>`;};
const dateLabel = timestamp => new Date(timestamp*1000).toLocaleString('zh-CN',{timeZone:state.me?.space.timezone || 'Asia/Shanghai',month:'long',day:'numeric',hour:'2-digit',minute:'2-digit'});
const today = () => new Intl.DateTimeFormat('sv-SE',{timeZone:state.me?.space.timezone || 'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const daysBetween = (a,b) => Math.round((new Date(b+'T00:00:00Z')-new Date(a+'T00:00:00Z'))/86400000);
const kindLabel = {post:'时光动态',diary:'私密日记',draft:'草稿',surprise:'定时惊喜',anniversary:'纪念日',wish:'共同愿望',personal_wish:'个人心愿',mood:'每日心情',note:'留言板',question:'情侣问答',habit:'共同打卡',chat:'聊天',album:'相册'};
const recordsOf = kind => state.records.filter(r=>r.kind===kind);
const uuid = () => crypto.randomUUID ? crypto.randomUUID() : ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g,c=>(c^crypto.getRandomValues(new Uint8Array(1))[0]&15>>c/4).toString(16));

const DARK_KEY = 'love-dark-mode';
// —— Android APK 状态栏适配：颜色跟随明暗主题（浏览器/PWA 无 Capacitor 时跳过）——
const _SB=(window.Capacitor&&window.Capacitor.Plugins)?window.Capacitor.Plugins.StatusBar:null;
async function syncStatusBar(){if(!_SB)return;try{const dark=document.documentElement.classList.contains('dark');await _SB.setOverlaysWebView({overlay:false});await _SB.setStyle({style:dark?'Dark':'Light'});await _SB.setBackgroundColor({color:dark?'#211a1e':'#f8e9ef'});}catch{}}
function applyDarkMode() {
  const pref = localStorage.getItem(DARK_KEY) || 'auto';
  const dark = pref === 'on' || (pref === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.toggle('dark', dark);
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#211a1e' : '#f8e9ef');
  refreshCustomColor();
  syncStatusBar();
}
window.matchMedia('(prefers-color-scheme: dark)').addEventListener?.('change', applyDarkMode);

function shade(hex, percent) {
  const n = parseInt(hex.slice(1), 16), f = percent < 0 ? 0 : 255, p = Math.abs(percent);
  const r = n >> 16, g = (n >> 8) & 255, b = n & 255;
  const mix = c => Math.round((f - c) * p) + c;
  return '#' + [mix(r), mix(g), mix(b)].map(v => v.toString(16).padStart(2, '0')).join('');
}
const luminance = hex => {const n=parseInt(hex.slice(1),16);return ((n>>16)*299+((n>>8)&255)*587+(n&255)*114)/1000/255;};
let currentCustom = null;
function refreshCustomColor(){ if(currentCustom) applyCustomColor(currentCustom.theme, currentCustom.color); }
function applyCustomColor(theme, color) {
  const root = document.documentElement;
  ['--primary', '--primary-dark', '--soft', '--soft-strong', '--on-primary'].forEach(v => root.style.removeProperty(v));
  currentCustom = theme === 'custom' && /^#[0-9a-fA-F]{6}$/.test(color) ? {theme, color} : null;
  if (!currentCustom) return;
  const dark = root.classList.contains('dark');
  let primary = color;
  // 极浅或极深的自定义色派生出可读的按钮色，保证白字对比度
  const lum = luminance(color);
  if (lum > 0.82) primary = shade(color, -0.4);
  else if (lum < 0.14) primary = shade(color, 0.42);
  root.style.setProperty('--primary', primary);
  root.style.setProperty('--primary-dark', shade(primary, -0.18));
  root.style.setProperty('--on-primary', luminance(primary) > 0.62 ? '#2b1520' : '#ffffff');
  if (dark) {
    // 夜间：柔和背景同步走深色，避免夜间出现浅色块
    root.style.setProperty('--soft', shade(primary, -0.74));
    root.style.setProperty('--soft-strong', shade(primary, -0.64));
  } else {
    root.style.setProperty('--soft', shade(primary, 0.9));
    root.style.setProperty('--soft-strong', shade(primary, 0.8));
  }
}
const button = (label,action,style='secondary',ico='',extra='') => `<button type="button" class="button ${style}" data-action="${action}" ${extra}>${ico?icon(ico):''}${label}</button>`;
const empty = (title,description,action='',label='留下第一份回忆',compact=false) => `<div class="empty ${compact?'compact':''}"><div class="empty-icon">♡</div><h3>${esc(title)}</h3><p>${esc(description)}</p>${action?button(label,action,'soft','plus'):''}</div>`;
function heading(title,description,action='',label='写点什么',ico='plus') {return `<div class="page-heading"><div><div class="eyebrow">OUR LITTLE WORLD</div><h1>${esc(title)}</h1><p>${esc(description)}</p></div>${action?button(label,action,'primary',ico):''}</div>`;}

async function boot() {
 try {
  applyDarkMode();
  const status = await api('/status');
  state.localVersion=status.version||'1.1.0';state.appVersion={version:status.version||'1.1.0',build:status.build||''};
  /* 原生 APK 版本（供关于页展示 + 应用内更新对比） */
  if(isNativeApp()){try{const version=await nativePushBridge()?.version?.();if(version?.version&&version.version!=='unknown')state.apkVersion=version.version;}catch{}}
  const invite = new URLSearchParams(location.search).get('invite');
  try {state.me = await api('/me');} catch {state.me=null;}
  if (!state.me) return renderAuth(status,invite);
  history.replaceState(null,'',location.pathname+location.hash);
  state.page=location.hash.slice(1).split('/')[0] || 'home';
  if (!['home','timeline','albums','messages','together','personal','settings','notices','channels','backups','imports','importdetail','dashboard','weekly'].includes(state.page)) state.page='home';
  await refreshData(); if(state.page==='timeline')await loadTimeline(true); renderShell(); connectEvents(); connectNtfy(); syncNativePush(); startKeepAlive();
 } catch(e) {$('#app').innerHTML=empty('暂时无法连接空间',e.message,'reload','重新连接');}
}

function renderAuth(status, invite) {
 const mode = !status.initialized ? 'setup' : invite ? 'join' : 'login';
 $('#app').innerHTML=`<main class="auth-page"><section class="auth-card"><div class="auth-art"><div class="brand"><img src="/static/icon.svg" alt=""><div><strong>恋爱空间</strong><small>LOVE, EVERY DAY</small></div></div><h1>把平凡的小日子，<br>收藏成我们的故事。</h1><img class="garden" src="/static/garden.svg" alt="两只小兔子在温暖的小屋前相伴"><p>一屋 · 两人 · 三餐 · 四季<br>这里，装着我们所有的小美好。</p></div><form id="auth-form" class="auth-form"><div class="eyebrow">JUST THE TWO OF US</div><h2>${mode==='setup'?'开启我们的小世界':mode==='join'?'赴一场两个人的约定':'好久不见，亲爱的'}</h2><p>${mode==='setup'?'先创建你的账号，再邀请另一半入住。':mode==='join'?'你的另一半正在这个小世界里等你。':'登录，继续书写属于你们的故事。'}</p>${mode!=='login'?'<label>你的昵称<input name="name" required maxlength="30" placeholder="希望 TA 怎么称呼你"></label>':''}<label>登录账号<input name="username" required minlength="3" maxlength="40" pattern="[a-zA-Z0-9_.@-]+" autocomplete="username" placeholder="英文、数字，至少 3 位"></label><label>密码<input name="password" type="password" required minlength="10" maxlength="128" autocomplete="${mode==='login'?'current-password':'new-password'}" placeholder="至少 10 个字符"></label>${mode==='setup'&&status.setup_token_required?'<label>初始化口令<input name="token" type="password" required placeholder="部署时设置的 SETUP_TOKEN"></label>':''}<div class="form-error" role="alert"></div><button class="button primary" type="submit">${mode==='login'?'回到我们的小世界':mode==='join'?'接受邀请，成为我们':'创建恋爱空间'} ${icon('arrow')}</button><div class="auth-foot">${icon('lock')} 私密记录 · 只属于彼此</div></form></section></main>`;
 $('#auth-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=$('button[type=submit]',form);b.disabled=true;try {const data=Object.fromEntries(new FormData(form));if(invite)data.token=invite;await post('/'+mode,data);await boot();}catch(err){$('.form-error',form).textContent=err.message;}finally{b.disabled=false;}};
}

async function refreshData() {
 [state.me,state.records,state.photos,state.notices]=await Promise.all([api('/me'),api('/records?kind='+Object.keys(kindLabel).join(',')+'&limit=300'),api('/photos'),api('/notices')]);
 syncNativePush();
}
async function loadTimeline(reset=false) {
 if(state.timelineLoading)return;
 state.timelineLoading=true;
 try {
  const f=state.filters||{},params=new URLSearchParams({kind:'post',limit:'61'});
  if(f.q)params.set('q',f.q);if(f.author)params.set('author',f.author);if(f.date)params.set('date',f.date);if(f.media)params.set('media_type',f.media);
  if(!reset&&state.timelineCursor){params.set('before',String(state.timelineCursor.created));params.set('before_id',state.timelineCursor.id);}
  const fetched=await api('/records?'+params.toString()),hasMore=fetched.length>60,page=fetched.slice(0,60);
  if(reset)state.timelinePosts=page;else state.timelinePosts.push(...page.filter(r=>!state.timelinePosts.some(x=>x.id===r.id)));
  const last=page.at(-1);state.timelineCursor=last?{created:last.created,id:last.id}:null;state.timelineHasMore=hasMore;
  const byId=new Map(state.records.filter(r=>r.kind!=='post').map(r=>[r.id,r]));for(const record of state.timelinePosts)byId.set(record.id,record);state.records=[...byId.values()];
 } finally {state.timelineLoading=false;}
}
function renderShell() {
 // 整页 innerHTML 替换会把滚动位置清零。SSE 每来一条就重渲染一次的话，
 // 正在翻相册/看时光的人会被不断弹回顶部——所以重渲染前后把位置接回去。
 // 主动切页时 navigate() 会在之后显式 scrollTo(0,0)，不受这里影响。
 const keepScroll=window.scrollY||0;
 const navs=[['home','home','首页'],['timeline','book','时光'],['albums','photo','相册'],['together','heart','我们']];
 const navActive=['personal','settings','channels','backups','notices','imports','importdetail'].includes(state.page)?'together':state.page;
 const navHtml=navs.map(([id,ico,label])=>`<button data-nav="${id}" class="${navActive===id?'active':''}" ${navActive===id?'aria-current="page"':''}>${icon(ico)}<span>${label}</span></button>`);navHtml.splice(2,0,`<button class="nav-fab" data-action="compose" aria-label="记录此刻">${icon('plus')}<span>记录</span></button>`);
 const themeClass='theme-'+state.me.space.theme,motion=state.me.space.motion?'':'reduced-motion',root=document.documentElement;
 [themeClass,'theme-rose','theme-peach','theme-lavender','theme-custom','reduced-motion'].forEach(c=>root.classList.remove(c));
 root.classList.add(state.me.space.theme==='peach'||state.me.space.theme==='lavender'||state.me.space.theme==='custom'?themeClass:'theme-rose');
 if(!state.me.space.motion)root.classList.add('reduced-motion');
 document.body.className=state.page==='messages'?'chat-full':(state.page==='together'&&state.tab==='calendar'?'cal-full':'');
 applyCustomColor(state.me.space.theme,state.me.space.custom_color);
 $('#app').innerHTML=`<div class="shell${state.page==='messages'?' chat-full':''}"><aside class="sidebar"><div class="brand"><img src="/static/icon.svg" alt=""><div><strong>恋爱空间</strong><small>LOVE, EVERY DAY</small></div></div><nav class="nav" aria-label="主要导航">${navHtml.join('')}</nav><div class="sidebar-bottom"><div class="little-note"><span>❀</span><br>把喜欢，写进每一天。<br>little things, lasting love</div><button class="profile-btn" data-nav="personal">${avatar(state.me.user.id)}<div><strong>${esc(state.me.user.name)}</strong><small>我的小角落 ${icon('arrow')}</small></div></button></div></aside><main class="main"><header class="topbar"><span class="desktop-date">${new Date().toLocaleDateString('zh-CN',{timeZone:state.me.space.timezone,month:'long',day:'numeric',weekday:'long'})} · 今天也要好好相爱</span><span class="mobile-brand"><img src="/static/icon.svg" alt="">恋爱空间</span><div class="topbar-right"><span class="pill">${icon('lock')} 双人私密空间</span><button class="icon-btn" id="dark-toggle" data-action="toggle-dark" aria-label="切换深浅色">${icon(document.documentElement.classList.contains('dark')?'sun':'moon')}</button><button class="icon-btn" data-nav="messages" aria-label="私聊">${icon('chat')}${state.me.chat_unread&&state.page!=='messages'?`<span class="badge">${state.me.chat_unread>99?'99+':state.me.chat_unread}</span>`:''}</button><button class="icon-btn" data-nav="notices" aria-label="通知">${icon('bell')}${state.me.unread?`<span class="badge">${state.me.unread>99?'99+':state.me.unread}</span>`:''}</button><details class="more-menu account-menu"><summary class="mobile-profile" aria-label="打开账号菜单" title="账号菜单">${avatar(state.me.user.id)}</summary><div class="menu-pop account-popover"><div class="account-menu-heading"><strong>${esc(state.me.user.name)}</strong><small>我的账号</small></div><button data-action="profile">${icon('edit')} 账号资料</button><button data-nav="personal">${icon('lock')} 个人小角落</button><button data-nav="settings">${icon('gear')} 设置</button><button data-action="logout" class="danger account-logout">${icon('arrow')} 退出登录</button></div></details></div></header>${!state.online?'<div class="offline-banner">网络暂时断开，正在等待重连。未发送的文字会为你保留。</div>':''}<div id="page"></div><p class="footer-note">♡ 有你在，平凡的日子也闪闪发光。</p></main></div>`;
 renderPage();
 if(keepScroll>0)window.scrollTo({top:keepScroll});
}

function renderPage() {
 const pages={home:homePage,timeline:timelinePage,albums:albumsPage,messages:messagesPage,together:togetherPage,personal:personalPage,settings:settingsPage,notices:noticesPage,channels:channelsPage,backups:backupsPage,imports:importsPage,importdetail:importDetailPage,dashboard:dashboardPage,weekly:weeklyPage};
 $('#page').innerHTML=(pages[state.page] || homePage)();
 if(state.page==='timeline'&&state.timelineHasMore)$('#timeline-list')?.insertAdjacentHTML('afterend',`<div class="timeline-more">${button('继续往前翻','load-more-timeline','secondary')}</div>`);
 if(state.page==='messages') {$('#chat-text').value=localStorage.getItem('chat-text:'+state.me.user.id)||'';autoGrow($('#chat-text'));scrollChat();$('#chat-text')?.addEventListener('focus',()=>{const d=$('#sticker-dock');if(d)d.hidden=true;});}
 if(state.page==='importdetail') initImportLog();
 if(state.page==='home'){loadOnThisDay();loadYearbook();}
 if(state.page==='together'&&state.tab==='calendar') loadCalendar();
}
/* state.me 还没到时不要渲染：boot() 是异步的，用户在首屏加载完之前点导航（或 hashchange 抢跑）
   会让 renderShell 读到 null.space 抛 TypeError，被 catch 成一条吓人的报错提示。
   直接返回即可——boot() 结束时会按 location.hash 渲染到正确的页面。 */
async function navigate(page,tab='') {if(!state.me)return;if(page!=='messages')state.chatReturn={page,tab};if(page==='messages'&&state.me){state.me.chat_unread=0;post('/notices/read?event=chat').catch(()=>{});}state.page=page;state.tab=tab;location.hash=page;try{if(page==='timeline')await loadTimeline(true);await loadSpecial();renderShell();window.scrollTo({top:0});}catch(e){toast(e.message);}}
async function loadSpecial(){
 if(state.page==='channels'){
  [state.channels,state.deliveries,state.webpush]=await Promise.all([api('/channels'),api('/deliveries'),api('/webpush')]);
  state.webpush.local=false;
  if(browserPushSupported()&&!isNativeApp()){try{state.webpush.local=Boolean(await (await navigator.serviceWorker.ready).pushManager.getSubscription());}catch{}}
  if(isNativeApp()){try{const push=nativePushBridge();state.nativePush=push?.status?await push.status():{available:false,error:'原生提醒插件不可用'};}catch{state.nativePush={available:false};}}
 }
 if(state.page==='backups'){state.backups=await api('/backups');try{state.storage=await api('/storage');}catch{state.storage=null;}}
 if(state.page==='personal'&&state.tab==='trash')state.trash=await api('/records?trash=true&kind='+Object.keys(kindLabel).join(','));
 if(state.page==='imports'||state.page==='importdetail')state.imports=await api('/imports');
 if(state.page==='dashboard')state.dashboard=await api('/dashboard');
 if(state.page==='weekly')state.weekly=await api('/weekly?offset='+(state.weekOffset||0));
}
async function refresh(render=true){if(refreshing){state.pendingRefresh=true;return;}refreshing=true;try{await refreshData();if(state.page==='timeline')await loadTimeline(true);await loadSpecial();if(render)renderShell();}finally{refreshing=false;}/* 刷新期间若有新事件被排队，完成后立刻补一轮，事件不再丢失 */if(state.pendingRefresh){state.pendingRefresh=false;handleServerEvent();}}

function nextAnniversary() {
 return recordsOf('anniversary').map(r=>{let date=r.body.date;if(r.body.annual===true){const year=Number(today().slice(0,4));date=year+date.slice(4);if(date.endsWith('02-29')&&new Date(year,1,29).getMonth()!==1)date=year+'-02-28';if(date<today()){date=(year+1)+r.body.date.slice(4);if(date.endsWith('02-29')&&new Date(year+1,1,29).getMonth()!==1)date=(year+1)+'-02-28';}}return {...r,due:date,days:daysBetween(today(),date)};}).filter(r=>r.days>=0).sort((a,b)=>a.days-b.days)[0];
}
function homePage() {
 const {space,user,users}=state.me,partner=users.find(u=>u.id!==user.id),days=space.since?Math.max(0,daysBetween(space.since,today())+1):null,anniversary=nextAnniversary(),posts=recordsOf('post').slice(0,3),wishes=recordsOf('wish');
 const moodRows=users.map(u=>{const m=recordsOf('mood').find(r=>r.author===u.id&&r.body.date===today());return `<div class="mood-row">${avatar(u.id)}<span>${esc(u.name)}</span><span class="mood-bubble">${m?esc(m.body.emoji)+' '+esc(m.body.content||'已记录'):'等一个好心情'}</span></div>`;}).join('');
 const heroCopy=`<section class="hero">${space.cover?`<img class="hero-art hero-cover" src="/media/${esc(space.cover)}?preview=true" alt="我们的合照封面">`:'<img class="hero-art" src="/static/garden.svg" alt="两只小兔子守着共同的小家">'}<div class="hero-mask"></div><div class="hero-copy"><div class="hero-main"><span class="hero-tag">${icon('heart')} ${esc(space.name)}</span><div class="couple-line"><div class="couple-avatars">${avatar(user.id)}<span class="heart-symbol">♥</span>${partner?avatar(partner.id,'partner'):'<span class="avatar partner">?</span>'}</div><span class="hero-names-text">${partner?`${esc(user.name)} & ${esc(partner.name)}`:'等你，把另一半邀请进来'}</span></div>${partner?'':`<button class="link-btn" data-action="invite">发送邀请，让 TA 住进来 →</button>`}<div class="hero-days"><small>我们相恋</small><strong>${days??'—'}<em>天</em></strong>${days===null?`<button class="link-btn" data-action="space">设置相恋日期 →</button>`:`<span class="meta">${esc(space.since)} · 今天也要好好相爱</span>`}</div></div></div></section>`;
 const todayCard=`<section class="today-card" aria-label="今天的陪伴"><div class="today-cell"><span class="tiny">${icon('sun')} 今天的心情</span><div class="mood-inline">${moodRows}</div></div><div class="today-cell"><span class="tiny">${icon('calendar')} 最近纪念日</span>${anniversary?`<div class="countdown-mini"><strong>${anniversary.days}</strong><span>天后 · ${esc(anniversary.body.title)}</span></div><p class="meta">${anniversary.due} · 别忘了给彼此一个拥抱</p>`:`<div class="countdown-mini"><strong>♡</strong><span>留一个日子，给仪式感</span></div>${button('添加纪念日','new-anniversary','small secondary')}`}</div></section>`;
 const composeCta=`<button class="compose-cta" data-action="compose">${icon('edit')} 记录此刻</button>`;
 const homeHeading=heading('我们的每一天','一半是生活，一半是你。','compose','记录此刻','edit').replace('page-heading','page-heading home-heading');
 return `${homeHeading}${heroCopy}${todayCard}${composeCta}
 <div class="home-grid"><div class="home-main"><section><div class="section-heading"><h2>${icon('book')} 最近的小美好</h2><button class="link-btn" data-nav="timeline">所有时光 ${icon('arrow')}</button></div>${posts.length?posts.map(recordCard).join(''):`<div class="card">${empty('故事，从这一刻开始','一张照片、一句想说的话，都是值得收藏的小美好。','compose')}</div>`}</section>
 <section class="on-this-day" id="on-this-day"><div class="loading-heart" style="font-size:24px">♡</div><p class="meta meta-center">正在翻看这一天的回忆…</p></section>
 <section class="yearbook" id="yearbook"><h2>📖 今年的我们</h2><div class="yearbook-summary"><p>点开看看，这一年我们一起写下了什么。</p><span class="yearbook-toggle-row">${button('展开小年报','expand-yearbook','soft small','arrow')}</span></div></section></div>
 <aside class="home-aside"><div class="card mood-card"><div class="section-heading"><h2>☀ 今天的心情</h2><button class="link-btn" data-action="mood-history">回顾 →</button></div>${moodRows}${button('分享今天的心情','mood','soft')}</div>
 <div class="card anniversary-card"><div class="tiny">${icon('calendar')} 下一个值得期待的日子</div>${anniversary?`<h3>${esc(anniversary.body.title)}</h3><div class="countdown">${anniversary.days}<small>天后</small></div><p>${anniversary.due} · 别忘了给彼此一个拥抱</p>`:`<h3>留一个日子，给仪式感</h3><div class="countdown">♡</div>${button('添加纪念日','new-anniversary','small secondary')}`}</div>
 <div class="card"><div class="section-heading"><h2>✧ 我们的小心愿</h2><button class="link-btn" data-action="tool-wish">全部 →</button></div>${wishes.length?wishes.slice(0,3).map(r=>`<button class="wish-line ${r.body.done?'done':''}" data-action="toggle-wish" data-id="${r.id}"><span class="check-circle"></span>${esc(r.body.title)}</button>`).join(''):empty('一起期待下一件小事','想去的地方，想做的事情，都记在这里。','new-wish','许个心愿',true)}</div></aside></div>`;
}

function mediaMarkup(media=[]) {
 if(!media.length)return '';
 const VOICE_ICON='<svg class="v-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 9.5v5c0 .55.45 1 1 1h3.2L12 19.4V4.6L7.2 8.5H4c-.55 0-1 .45-1 1Z" fill="currentColor"/><path class="v-w1" d="M15.5 8.7a4.7 4.7 0 0 1 0 6.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path class="v-w2" d="M18.2 6.2a8.4 8.4 0 0 1 0 11.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
 return `<div class="media-grid ${media.length===1?'single':''}">${media.map(m=>m.mime.startsWith('image/')?`<button data-action="photo" data-id="${m.id}" aria-label="查看照片 ${esc(m.name)}"><img loading="lazy" src="/media/${m.id}?preview=true" alt="${esc(m.name)}"></button>`:m.mime.startsWith('video/')?`<button class="media-video" data-action="video" data-id="${m.id}" aria-label="播放视频 ${esc(m.name)}"><video muted playsinline preload="metadata" poster="/media/${m.id}?poster=true" src="/media/${m.id}?preview=true"></video><span class="play-badge"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg></span></button>`:`<button type="button" class="voice-chip" data-voice-play aria-label="播放语音">${VOICE_ICON}<b class="voice-dur">--</b><audio class="voice-audio" preload="metadata" src="/media/${m.id}?preview=true"></audio></button>`).join('')}</div>`;
}
/* 微信式语音消息：点击整条气泡播放；原生 <audio controls> 在 Android WebView 里样式不可控，已弃用 */
const fmtVoiceTime=s=>{if(!isFinite(s)||s<=0)return "0''";return s<60?Math.round(s)+"''":Math.floor(s/60)+':'+String(Math.floor(s%60)).padStart(2,'0');};
document.addEventListener('click',e=>{
 const chip=e.target.closest('[data-voice-play]');if(!chip)return;
 const audio=chip.querySelector('audio');if(!audio)return;
 if(audio.paused){document.querySelectorAll('.voice-chip.playing audio').forEach(a=>{if(a!==audio)a.pause();});audio.play().catch(()=>toast('语音播放失败，请稍后再试'));}
 else audio.pause();
});
['loadedmetadata','durationchange','play','pause','ended'].forEach(ev=>document.addEventListener(ev,e=>{
 const t=e.target;if(!t||!t.classList||!t.classList.contains('voice-audio'))return;
 const chip=t.closest('.voice-chip');if(!chip)return;
 if(ev==='play')chip.classList.add('playing');
 if(ev==='pause'||ev==='ended')chip.classList.remove('playing');
 if(ev==='loadedmetadata'||ev==='durationchange'){
  chip.querySelector('.voice-dur').textContent=fmtVoiceTime(t.duration);
  if(isFinite(t.duration))chip.style.minWidth=(84+Math.min(t.duration,90)*2.2).toFixed(0)+'px';
 }
},true));
function recordCard(r) {
 if(r.kind==='personal_wish')return personalWishCard(r);
 const own=r.author===state.me.user.id,sharedEdit=['album','anniversary','wish','habit'].includes(r.kind),b=r.body;
 return `<article class="card" data-record="${r.id}"><div class="card-header">${avatar(r.author)}<div><strong>${esc(person(r.author).name)}</strong><small>${esc(b.date||dateLabel(r.created))}${['diary','draft','surprise'].includes(r.kind)?' · '+kindLabel[r.kind]:''}${b.was_surprise?' · 一份公开的惊喜':''}</small></div><div class="card-menu">${own||sharedEdit?`<details class="more-menu"><summary aria-label="更多操作" title="更多操作">⋯</summary><div class="menu-pop"><button data-action="edit-record" data-id="${r.id}">${icon('edit')} 编辑</button><button data-action="delete-record" data-id="${r.id}" class="danger">${icon('trash')} 删除</button></div></details>`:''}</div></div>${b.title?`<h3 class="card-title">${esc(b.title)}</h3>`:''}<p class="card-text">${esc(b.content||'')}</p>${mediaMarkup(r.media)}${r.kind==='surprise'?`<p class="hint">${icon('lock')} 将于 ${dateLabel(b.publish_at)} 公开，目前只有你能看见。</p>`:''}${r.kind==='anniversary'?`<p class="meta">${esc(b.date)} · ${b.annual==='lunar'?'每年农历日期':b.annual===false?'一次性纪念日':'每年公历日期'} · 提前 ${b.remind_days??1} 天提醒</p><div class="inline-actions">${button('回看这一天','anniversary-memories','small soft','calendar',`data-date="${esc(b.date)}"`)}</div>`:''}${r.kind==='wish'?`<p class="meta">${esc(b.category||'小心愿')}${b.target?' · 约定 '+esc(b.target):''}</p><div class="inline-actions">${button(b.done?'已完成 · 再次点亮期待':'完成这个心愿','toggle-wish','small soft','check',`data-id="${r.id}"`)}${b.done?button('记录实现的那一刻','wish-memory','small secondary','edit',`data-id="${r.id}"`):''}</div>`:''}${r.kind==='habit'?`<p class="meta">${(r.checks||[]).length} 次用心坚持 · 今天 ${new Set((r.checks||[]).filter(c=>c.day===today()).map(c=>c.author)).size}/2 人完成</p><div class="inline-actions">${button((r.checks||[]).some(c=>c.author===state.me.user.id&&c.day===today())?'今天已打卡':'今天也一起坚持','check','small soft','check',`data-id="${r.id}"`)}</div>`:''}${r.kind==='question'?`<p class="meta">${r.answer_count===2?'两个人的答案都到齐啦':'双方回答后，才会揭晓彼此的答案'}</p>${(r.answers||[]).map(a=>`<div class="answer-box"><strong>${esc(person(a.author).name)}</strong><br>${esc(a.content)}</div>`).join('')}<div class="inline-actions">${button('写下我的答案','answer','small soft','edit',`data-id="${r.id}"`)}</div>`:''}${r.kind==='mood'?`<div class="inline-actions">${esc(b.emoji||'☀')}</div>`:''}${r.kind==='draft'?`<div class="inline-actions">${button('继续编辑','edit-record','soft small','edit',`data-id="${r.id}"`)}</div>`:''}<div class="card-footer"><span class="date-tag">${icon('clock')} ${dateLabel(r.created)}</span>${!['draft','diary','surprise'].includes(r.kind)?`<button class="${r.likes.includes(state.me.user.id)?'liked':''}" data-action="like" data-id="${r.id}">${icon('heart')} ${r.likes.length||'喜欢'}</button><button data-action="comment" data-id="${r.id}">${icon('chat')} ${r.comments.length||'回复'}</button>`:`<span>${icon('lock')} 仅自己可见</span>`}</div>${r.comments.length?`<div class="comments">${r.comments.map(c=>`<div><strong>${esc(person(c.author).name)}：</strong>${esc(c.content)}${c.author===state.me.user.id?`<button class="comment-delete" data-action="delete-comment" data-id="${c.id}">删除</button>`:''}</div>`).join('')}</div>`:''}</article>`;
}

function timelinePage() {
 const f=state.filters||{},posts=state.timelinePosts||[];
 const active=[['author','作者'],['date','日期'],['media','类型']].filter(([k])=>f[k]).length+(f.q?1:0);
 const chips=[f.q?`<span class="filter-chip">“${esc(f.q)}”</span>`:'',f.author?`<span class="filter-chip">${esc(person(f.author).name)}</span>`:'',f.date?`<span class="filter-chip">${esc(f.date)}</span>`:'',f.media?`<span class="filter-chip">${{image:'照片',video:'视频',audio:'语音'}[f.media]}</span>`:''].join('');
 return `${heading('时光慢慢，爱意满满','那些一起走过的日子，都在这里。','compose','记录此刻','edit')}<div class="filters"><input id="filter-q" placeholder="搜索我们的故事…" value="${esc(f.q||'')}" aria-label="搜索动态"><details class="filter-box" ${(['author','date','media'].some(k=>f[k]))?'open':''}><summary>${icon('calendar')} 筛选${active?`<span class="filter-chip">${active}</span>`:''}</summary><div class="filter-body">${chips}<select id="filter-author" aria-label="按作者筛选"><option value="">两个人的时光</option>${state.me.users.map(u=>`<option value="${u.id}" ${f.author===u.id?'selected':''}>${esc(u.name)}</option>`).join('')}</select><input id="filter-date" type="date" value="${esc(f.date||'')}" aria-label="按日期筛选"><select id="filter-media" aria-label="按类型筛选"><option value="">所有记录</option>${[['image','照片'],['video','视频'],['audio','语音']].map(([id,label])=>`<option value="${id}" ${f.media===id?'selected':''}>${label}</option>`).join('')}</select>${active?button('清除筛选','clear-filters','small secondary'):''}</div></details></div><div id="timeline-list">${posts.length?posts.map(recordCard).join(''):empty(f.q||active?'没有符合条件的记录':'这一页，留给新的故事',f.q||active?'换个条件，或清除筛选再试试。':'可以发照片、文字、视频，或者留下一段声音。','compose')}</div>`;
}
function albumsPage() {
 const selected=state.album||'',photos=state.photos.filter(p=>!selected||state.records.find(r=>r.id===p.record_id)?.body.album===selected),albums=recordsOf('album');
 return `${heading('把喜欢的瞬间，装进口袋','照片留住的不只是风景，还有身边的你。','upload-album','上传照片','photo')}<div class="tabs"><button data-action="album-filter" data-id="" class="${selected?'':'active'}">全部照片 · ${state.photos.length}</button>${albums.map(a=>`<button data-action="album-filter" data-id="${a.id}" class="${selected===a.id?'active':''}">${esc(a.body.title)}</button>`).join('')}<button data-action="new-album">＋ 新建相册</button></div>${selected?`<div class="inline-actions" style="margin:0 0 18px">${button('编辑相册','edit-record','small secondary','edit',`data-id="${selected}"`)}${button('删除相册分类','delete-record','small secondary','trash',`data-id="${selected}"`)}</div>`:''}${photos.length?`<div class="photo-grid">${photos.map(p=>`<button class="photo-item" data-action="photo" data-id="${p.id}"><img loading="lazy" src="/media/${p.id}?preview=true" alt="${esc(p.caption||p.name)}"><span>${esc(p.date||'属于我们的瞬间')}</span></button>`).join('')}</div>`:empty('每一张，都是喜欢你的证据','直接上传，或在发布动态时添加照片，都会收藏在这里。','upload-album','上传第一张照片')}`;
}

function pendingChats() {try{return JSON.parse(localStorage.getItem('pending-chat:'+state.me.user.id)||'[]');}catch{return [];}}
function setPending(chats) {localStorage.setItem('pending-chat:'+state.me.user.id,JSON.stringify(chats));}
/* 微信式时间分隔：间隔超过 5 分钟或跨天时，在消息流中插入居中时间条 */
function chatTimeLabel(ts,last){
 if(last!=null&&ts-last<=300&&new Date(ts*1000).toDateString()===new Date(last*1000).toDateString())return '';
 const d=new Date(ts*1000),n=new Date(),hm=String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0');
 if(d.toDateString()===n.toDateString())return hm;
 if(d.toDateString()===new Date(n.getTime()-864e5).toDateString())return '昨天 '+hm;
 return (d.getFullYear()===n.getFullYear()?'':d.getFullYear()+'年')+(d.getMonth()+1)+'月'+d.getDate()+'日 '+hm;
}
function chatRows() {
 const chats=recordsOf('chat').sort((a,b)=>a.created-b.created),pending=pendingChats().filter(p=>!chats.some(c=>c.client_id===p.client_id));
 let lastTs=null;
 const rows=chats.map(r=>{
  const tl=chatTimeLabel(r.created,lastTs);lastTs=r.created;
  if(r.body.recalled)return `${tl?`<div class="chat-day">${tl}</div>`:''}<div class="chat-recall">${r.author===state.me.user.id?'你':'对方'}撤回了一条消息</div>`;
  const mine=r.author===state.me.user.id,hasText=!!(r.body.content||'').trim(),voiceOnly=(r.media||[]).some(m=>m.mime.startsWith('audio/'))&&!hasText;
  const sticker=r.body.sticker;
  const ops=(mine&&Date.now()/1000-r.created<120?`<button data-action="recall-chat" data-id="${r.id}">撤回</button>`:'')+`<button data-action="chat-to-draft" data-id="${r.id}">记入时光</button>`;
  const inner=sticker?`<div class="chat-sticker${sticker.endsWith('.webm')?' video':''}">${sticker.endsWith('.webm')?`<video src="${esc(sticker)}" autoplay loop muted playsinline></video>`:`<img src="${esc(sticker)}" alt="贴纸" loading="lazy">`}</div>`:`<div class="chat-bubble${voiceOnly?' voice':''}"><span style="white-space:pre-wrap">${esc(r.body.content)}</span>${mediaMarkup(r.media)}</div>`;
  return `${tl?`<div class="chat-day">${tl}</div>`:''}<div class="chat-line ${mine?'mine':''}">${avatar(r.author)}<div>${inner}${ops?`<div class="chat-time">${ops}</div>`:''}</div></div>`;
 }).join('');
 const pend=pending.map(p=>`<div class="chat-line mine">${avatar(state.me.user.id)}<div><div class="chat-bubble">${esc(p.body.content||'一个附件')}</div><div class="chat-time">尚未发送 <button data-action="retry-chat" data-id="${p.client_id}">点击重试</button></div></div></div>`).join('');
 return rows+pend||empty('今天，有什么想对 TA 说？','说说日常，也说说想念。');
}
/* 聊天壁纸：预设用 CSS 渐变/纹理，'photo' 用自己上传的照片。
   dim 是压在图上的遮罩强度（百分比）——它存在的意义只有一个：保证气泡文字在任何底图上都读得清。 */
const CHAT_BG_PRESETS=[['','默认'],['sakura','樱粉'],['cream','奶油'],['mint','薄荷'],['stars','星光'],['night','夜幕'],['photo','用照片']];
function wallpaperDim(){return Math.min(80,Math.max(0,Number(state.me?.space?.chat_bg_dim??35)));}
function chatWallpaper(){
 const s=state.me?.space||{},bg=s.chat_bg||'';
 if(!bg)return '';
 const style=`--chat-bg-dim:${wallpaperDim()/100}`;
 if(bg==='photo')return s.chat_bg_media?`<div class="chat-wallpaper photo" aria-hidden="true" style="${style};background-image:url('/media/${esc(s.chat_bg_media)}?preview=true')"></div>`:'';
 return `<div class="chat-wallpaper" data-bg="${esc(bg)}" aria-hidden="true" style="${style}"></div>`;
}
function messagesPage() {
 const partner=state.me.users.find(u=>u.id!==state.me.user.id);
 return `<section class="chat-panel"><header class="chat-header"><button class="icon-btn" data-action="chat-back" aria-label="返回">${icon('back')}</button>${partner?avatar(partner.id):'<span class="avatar">♡</span>'}<div><h3>${partner?esc(partner.name):'等待另一半加入'}</h3><small>我们的悄悄话 · 仅彼此可见</small></div><button class="icon-btn" data-nav="imports" aria-label="聊天记录" style="margin-left:auto">${icon('book')}</button></header><div class="chat-body">${chatWallpaper()}<div id="chat-log" class="chat-log" aria-live="polite">${chatRows()}</div></div><div id="sticker-dock" class="sticker-dock" hidden></div><form id="chat-form" class="chat-compose"><button type="button" class="icon-btn" data-action="sticker-panel" aria-label="表情">😊</button><button type="button" class="icon-btn" data-action="chat-attachment" aria-label="添加图片、视频或语音">${icon('plus')}</button><textarea id="chat-text" name="content" placeholder="想说的话，想分享的日常…" rows="1" maxlength="20000" aria-label="聊天内容"></textarea><button class="button primary" type="submit" aria-label="发送消息">${icon('send')}</button></form></section>`;
}
function scrollChat(){const log=$('#chat-log');if(log)log.scrollTop=log.scrollHeight;}

/* ── 表情包：内置 emoji 两组（日常 / 涩涩）+ 个人自定义表情包（存本机，上传即存服务器媒体库） ── */
const CUTE_EMOJI=['😊','😄','🥰','😘','😗','💋','❤️','🧡','💕','💞','🤗','😳','🙈','✨','🌹','🍰','🍜','☕','🌙','⭐','🍀','🎁','📷','🎵','💤','🫶','🏠','🌈','☀️','🌧️'];
const SPICY_EMOJI=['😈','🫦','😏','💗','🍑','🍌','🍆','💦','👅','🔥','🛌','🙈','💋','🤫','💞','🌙'];
/* 内置贴纸包：静态文件打包于 static/stickers/<dir>/0..n.<ext>，双方登录即可用 */
const STICKER_PACKS=[
 {id:'pk-dancer',label:'🕺 舞动',dir:'musicfuckdancer3',ext:'webm',count:50},
 {id:'pk-tsrj8',label:'🫧 TSRJ8',dir:'tsrj8',ext:'webm',count:120},
 {id:'pk-lolitax',label:'🎀 Lolitax',dir:'lolitax',ext:'webp',count:119},
];
const stickerKey=()=>'stickers:'+state.me.user.id;
function myStickers(){try{return JSON.parse(localStorage.getItem(stickerKey())||'[]');}catch{return[];}}
function setStickers(list){localStorage.setItem(stickerKey(),JSON.stringify(list.slice(0,100)));}
function insertStickerText(em){const ta=$('#chat-text');if(!ta)return;if(document.activeElement===ta){const s=ta.selectionStart??ta.value.length,e=ta.selectionEnd??s;ta.value=ta.value.slice(0,s)+em+ta.value.slice(e);ta.selectionStart=ta.selectionEnd=s+em.length;}else ta.value+=em;autoGrow(ta);}
/* 微信式输入框：初始一行，输入后自动长高，超过约 4 行内部滚动 */
function autoGrow(ta){if(!ta)return;ta.style.height='auto';ta.style.height=Math.min(ta.scrollHeight,100)+'px';}
/* 表情面板：内嵌于输入栏上方（输入框始终可见），点击按钮开合；点 emoji 只插入文本不弹键盘 */
function stickerPanel(){
 const dock=$('#sticker-dock');if(!dock)return;
 if(!dock.hidden){dock.hidden=true;return;}
 state.stickerTab=state.stickerTab||'cute';
 dock.innerHTML=`<div class="sticker-tabs" id="sticker-tabs"></div><div class="sticker-body" id="sticker-body"></div>`;
 dock.hidden=false;
 if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();
 renderStickerTabs();
}
function renderStickerTabs(){
 const box=$('#sticker-tabs');if(!box)return;
 const tabs=[['cute','💕 日常'],['spicy','🔥 涩涩'],['mine','🌟 我的']].concat(STICKER_PACKS.map(p=>[p.id,p.label]));
 box.innerHTML=tabs.map(([id,label])=>`<button data-action="sticker-tab" data-id="${id}" class="${state.stickerTab===id?'active':''}">${label}</button>`).join('');
 $('#sticker-body').innerHTML=stickerTabHTML(state.stickerTab);
 lazyStickerVideos();
}
function stickerTabHTML(tab){
 if(tab==='mine'){
  const list=myStickers();
  return `${list.length?`<div class="sticker-grid mine">${list.map(s=>`<button type="button" class="sticker-cell" data-action="sticker-send" data-id="${s.mid}" aria-label="发送表情包"><img loading="lazy" src="/media/${s.mid}?preview=true" alt="${esc(s.name||'表情包')}"><span class="sticker-del" data-action="sticker-del" data-id="${s.mid}" aria-label="删除这张表情包">×</span></button>`).join('')}</div>`:`<p class="meta meta-center" style="padding:26px 0 10px">还没有专属表情包<br><small>点下面收第一张，一点就能发给 TA</small></p>`}<label class="sticker-add">＋ 添加表情包<input type="file" id="sticker-file" accept="image/jpeg,image/png,image/webp,image/gif" hidden></label><p class="small-note" style="text-align:center;margin-top:8px">只存于本机列表 · 图片保存在你们的空间里</p>`;
 }
 const pack=STICKER_PACKS.find(p=>p.id===tab);
 if(pack){
  const cells=Array.from({length:pack.count},(_,i)=>{
   const path=`/static/stickers/${pack.dir}/${i}.${pack.ext}`;
   const inner=pack.ext==='webm'?`<video muted loop playsinline data-src="${path}"></video>`:`<img src="${path}" loading="lazy" alt="贴纸">`;
   return `<button type="button" class="sticker-cell" data-action="sticker-pack-send" data-id="${path}" aria-label="发送贴纸">${inner}</button>`;
  }).join('');
  return `<div class="sticker-grid pack">${cells}</div><p class="small-note" style="text-align:center;margin-top:10px">点一下，直接发给 TA</p>`;
 }
 const list=tab==='spicy'?SPICY_EMOJI:CUTE_EMOJI;
 return `<div class="sticker-grid">${list.map(em=>`<button type="button" class="sticker-cell" data-action="sticker-emoji" data-id="${em}" aria-label="插入表情">${em}</button>`).join('')}</div><p class="small-note" style="text-align:center;margin-top:10px">${tab==='spicy'?'这些只属于你们两个人的小秘密 🔒':'点一下，就能打进输入框'}</p>`;
}
/* 视频贴纸懒加载：滚进可视区才加载 src 并循环播放，滚出即暂停，避免几十个视频同时解码 */
function lazyStickerVideos(){
 const root=$('#sticker-body');
 // 每次渲染贴纸面板都会重建 DOM，旧的 observer 必须先断开：否则切几次标签页就
 // 攒下几十个 observer 一起回调，白耗主线程，还会让已销毁的视频继续被 observe
 if(root&&root._stickerObserver){root._stickerObserver.disconnect();}
 const io=new IntersectionObserver(entries=>{
  entries.forEach(en=>{
   const v=en.target;
   if(en.isIntersecting){
    if(v.dataset.src&&!v.getAttribute('src'))v.src=v.dataset.src;
    v.play().catch(()=>{});
   }else{v.pause();}
  });
 },{root:root||null,rootMargin:'160px'});
 if(root)root._stickerObserver=io;
 document.querySelectorAll('.sticker-cell video[data-src]').forEach(v=>io.observe(v));
}
/* 点击表情面板与输入栏以外的区域时收起面板 */
document.addEventListener('click',e=>{const d=$('#sticker-dock');if(d&&!d.hidden&&!e.target.closest('#sticker-dock')&&!e.target.closest('.chat-compose')&&!e.target.closest('[data-action="sticker-panel"]'))d.hidden=true;},true);
document.addEventListener('change',e=>{
 if(e.target.id!=='sticker-file'||!e.target.files[0])return;
 const file=e.target.files[0];e.target.value='';
 uploadFile(file).then(m=>{const list=myStickers();if(list.some(s=>s.mid===m.id))return;setStickers([{mid:m.id,name:m.name||'表情包'},...list]);renderStickerTabs();toast('已加入我的表情包');}).catch(err=>toast(err.message));
});

const platformLabel={auto:'聊天记录',wechat:'微信',qq:'QQ',douyin:'抖音'};
const kindPlaceholder={image:'[图片]',voice:'[语音]',video:'[视频]',sticker:'[表情]',system:'[互动消息]'};
const dateShort = ts => new Date(ts*1000).toLocaleDateString('zh-CN',{timeZone:state.me?.space.timezone || 'Asia/Shanghai',year:'numeric',month:'short',day:'numeric'});
function importsPage(){
 const list=state.imports||[];
 return `${heading('收藏我们的聊天记录','把微信、QQ、抖音里的回忆，也安放在这里。','import-chat','导入聊天记录','download')}${list.length?list.map(i=>`<button class="card import-card" data-action="open-import" data-id="${i.id}"><div class="import-head"><span class="import-platform">${platformLabel[i.platform]||'聊天'}</span><strong>${esc(i.title)}</strong></div><p class="meta">${i.message_count} 条记录${i.start_at?` · ${dateShort(i.start_at)}${i.end_at?' ~ '+dateShort(i.end_at):''}`:''}</p>${i.last?`<p class="import-last">${esc(i.last.slice(0,60))}</p>`:''}<small class="meta">两人共享 · 由 ${esc(person(i.author).name)} 导入</small></button>`).join(''):empty('这里还空着','支持微信、QQ、抖音导出的 txt / csv / json / zip 文件，导入后两人都能看到。','import-chat','导入第一份聊天记录')}`;
}
function importDetailPage(){
 const i=(state.imports||[]).find(x=>x.id===state.importId)||{};
 // 聊天记录是两人共享的：谁都能看、谁都能删，所以这里不再按 author 判断权限
 return `<div class="page-heading"><div><div class="eyebrow">${platformLabel[i.platform]||'CHAT ARCHIVE'}</div><h1>${esc(i.title||'聊天记录')}</h1><p>${i.message_count||0} 条记录 · 我们两人共享${i.author?` · 由 ${esc(person(i.author).name)} 导入`:''}</p></div>${button('返回列表','imports-back','secondary','arrow')}</div><div class="filters"><input id="import-q" placeholder="搜索聊天内容…" aria-label="搜索聊天内容"><input id="import-day" type="date" aria-label="跳转到日期"></div><div id="import-log" class="chat-log import-log"><div class="loading"><span class="loading-heart">♡</span></div></div><div class="inline-actions" style="justify-content:center"><button class="button soft small" id="import-earlier">加载更早的记录</button></div><div class="form-actions">${button('删除这份聊天记录','delete-import','secondary small','trash',`data-id="${i.id}"`)}</div>`;
}
function importMsgRows(items){
 let lastDay='';
 return items.map(m=>{
  let sep='';
  if(m.day&&m.day!==lastDay){lastDay=m.day;sep=`<div class="chat-day">${m.day}</div>`;}else if(m.day){lastDay=m.day;}
  const body=m.kind==='text'?esc(m.content):(m.media_id?`<img class="import-msg-image" src="/media/${m.media_id}?preview=true" alt="聊天图片" loading="lazy">`:`<span class="import-placeholder">${kindPlaceholder[m.kind]||esc(m.content)}</span>`);
  const toDraft=m.kind==='text'&&m.content?`<button data-action="import-to-draft" data-content="${esc(m.content.slice(0,500))}" data-day="${m.day||''}">记入时光</button>`:'';
  return sep+`<div class="chat-line ${m.mine?'mine':''}"><span class="avatar">${esc((m.sender||'?').slice(0,1))}</span><div><div class="chat-bubble"><span style="white-space:pre-wrap">${body}</span></div><div class="chat-time">${esc(m.sender)}${m.sent_at?' · '+dateLabel(m.sent_at):''}${toDraft}</div></div></div>`;
 }).join('');
}
async function initImportLog(){
 const log=$('#import-log');if(!log||!state.importId)return;
 let cursor=0,query='',day='',loading=false;
 const earlier=$('#import-earlier');
 async function load(reset=false){
  if(loading)return;loading=true;
  try{
   const params=new URLSearchParams({limit:'100'});
   if(query)params.set('q',query);
   if(day)params.set('day',day);
   if(!reset&&cursor)params.set('cursor',cursor);
   const data=await api('/imports/'+state.importId+'/messages?'+params);
   if(reset){log.innerHTML='';if(!data.messages.length){log.innerHTML=empty('没有找到相关记录','换个关键词，或换个日期试试。','','',true);}}
   log.insertAdjacentHTML('afterbegin',importMsgRows(data.messages));
   cursor=data.earliest||cursor;
   earlier.style.display=data.has_more?'':'none';
   if(reset)log.scrollTop=log.scrollHeight;
  }catch(e){toast(e.message);}finally{loading=false;}
 }
 load(true);
 earlier.onclick=()=>load();
 let timer;
 $('#import-q').oninput=e=>{clearTimeout(timer);timer=setTimeout(()=>{query=e.target.value.trim();cursor=0;load(true);},400);};
 $('#import-day').onchange=e=>{day=e.target.value;cursor=0;load(true);};
}
function postForm(path,formData,onProgress){
 // 用 XHR 而不是 fetch，只为了拿到上传进度：几十 MB 的导出文件在手机网络上
 // 要走很久，没有进度条用户会以为卡死了
 return new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest();xhr.open('POST','/api'+path);xhr.setRequestHeader('X-Love-Space','1');
  if(onProgress&&xhr.upload)xhr.upload.onprogress=e=>{if(e.lengthComputable)onProgress(e.loaded/e.total);};
  xhr.onload=()=>{let data;try{data=JSON.parse(xhr.responseText);}catch{return reject(new Error('服务暂时不可用，请重试'));}if(xhr.status>=200&&xhr.status<300)resolve(data);else reject(new Error(typeof data.detail==='string'?data.detail:'请求失败，请重试'));};
  xhr.onerror=()=>reject(new Error('网络中断，请检查连接后重试'));
  xhr.ontimeout=()=>reject(new Error('上传超时，文件可能过大或网络不稳定'));
  xhr.send(formData);});
}
function yearbookBody(data){
 const highlights=[['📝','时光动态',data.by_kind?.post||0],['📷','收藏照片',data.photos],['☀','心情记录',data.moods],['✨','完成心愿',data.wishes_done],['📅','纪念日',data.anniversaries]].filter(x=>x[2]>0);
 return `<div class="yearbook-grid"><div class="yearbook-stat"><strong>${data.total}</strong><small>条记录</small></div><div class="yearbook-stat"><strong>${data.photos}</strong><small>张照片</small></div><div class="yearbook-stat"><strong>${data.moods}</strong><small>次心情</small></div><div class="yearbook-stat"><strong>${data.wishes_done}</strong><small>个心愿</small></div></div>${highlights.length?`<div class="yearbook-highlights">${highlights.map(([e,l,n])=>`<div class="yearbook-highlight"><span class="hl-emoji">${e}</span><span class="hl-text">${l}</span><span class="hl-num">${n}</span></div>`).join('')}</div>`:'<p class="meta">这一年，还在慢慢写下我们的故事…</p>'}`;
}
async function loadYearbook(){
 const box=$('#yearbook');if(!box)return;
 try{
  const data=await api('/yearbook');
  state.yearbookData=data;
  box.innerHTML=`<h2>📖 ${data.is_current?'今年':' '+data.year+' 年'}的我们</h2><div class="yearbook-summary"><p>${data.total} 条记录 · ${data.photos} 张照片 · ${data.moods} 次心情</p><span class="yearbook-toggle-row">${button('展开小年报','expand-yearbook','soft small','arrow')}</span></div>`;
 }catch(e){box.innerHTML='<p class="meta">年报暂时打不开，请稍后再试。</p>';}
}
async function loadCalendar(force){
 if(!state.calMonth){const d=new Date();state.calMonth=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');}
 // 已加载当月数据时直接返回，避免 renderPage → loadCalendar → renderPage 循环重绘（点击日期闪烁的根因）
 if(!force && state.calLoadedMonth===state.calMonth && state.calDays) return;
 try{const data=await api('/calendar?month='+state.calMonth);state.calDays=data.days;state.calLoadedMonth=state.calMonth;renderPage();}catch(e){toast(e.message);}
}
async function loadOnThisDay(){
 const box=$('#on-this-day');if(!box)return;
 try{
  const groups=await api('/on-this-day');
  if(!groups.length){box.innerHTML='<h2>📖 历史上的今天</h2><p class="otd-empty">这一天的回忆，正在被我们一起写下。<br>未来再回来翻看，时光会记得我们走过的每一程。</p>';return;}
  box.innerHTML='<h2>📖 历史上的今天 · 我们的小时光</h2>'+groups.slice(0,4).map(g=>g.items.map(it=>`<button class="otd-item" data-action="otd-detail" data-id="${it.id}"><span class="otd-year">${g.is_today?'今天':g.year}</span><span class="otd-snippet">${esc(it.body.title||it.body.content||kindLabel[it.kind]||'一份回忆')}</span></button>`).join('')).join('');
 }catch(e){box.innerHTML='<p class="meta">回忆暂时打不开，请稍后再试。</p>';}
}
const IMPORT_MAX_BYTES=50*1024*1024;
const IMPORT_EXTS=['.txt','.csv','.json','.zip'];
function importChatModal(){
 openModal('导入聊天记录',`<form id="import-form" class="modal-form">${selectField('来自哪个平台','platform',[['auto','自动识别'],['wechat','微信'],['qq','QQ'],['douyin','抖音']],'auto')}${field('给这份记录起个名字（可选）','title','','text','maxlength="60" placeholder="如：和小兔的微信记录"')}<label class="import-file-tile"><span class="upload-ico">📄</span><b>选择导出的文件</b><small>txt / csv / json / zip，最大 50MB</small><input type="file" id="import-file" accept=".txt,.csv,.json,.zip" required><span id="import-file-name" class="import-file-name">支持微信、QQ、抖音等导出的聊天记录；zip 可带图片</span></label><p class="small-note">微信可用「留痕」等工具导出 txt / csv；QQ 用消息管理器导出 txt；抖音用第三方工具导出 csv / json。文件只在我们自己的服务器上解析，导入后两人都能看到这份记录。</p><div id="import-preview"></div><div id="import-progress" class="import-progress" hidden><div class="bar-track"><div class="bar-fill" id="import-bar" style="width:0%"></div></div><small class="meta" id="import-progress-text">准备中…</small></div><div class="form-error" role="alert"></div><div class="form-actions"><button class="button secondary" type="button" id="import-preview-btn">解析预览</button><button class="button primary" type="submit" id="import-submit" disabled>确认导入</button></div></form>`);
 const form=$('#import-form'),error=$('.form-error',form),previewBox=$('#import-preview');
 const submit=$('#import-submit'),previewBtn=$('#import-preview-btn');
 const progressBox=$('#import-progress'),bar=$('#import-bar'),progressText=$('#import-progress-text');
 let preview=null;
 const showError=msg=>{error.textContent=msg;};
 const resetPreview=()=>{preview=null;previewBox.innerHTML='';submit.disabled=true;};
 // 上传进度只有上传阶段有数字，服务器解析阶段只能给不确定态，别写成假的 100%
 const setProgress=(ratio,text)=>{progressBox.hidden=false;bar.style.width=Math.round((ratio??0)*100)+'%';bar.classList.toggle('indeterminate',ratio==null);progressText.textContent=text;};
 const hideProgress=()=>{progressBox.hidden=true;bar.classList.remove('indeterminate');};
 // 先看本地能查的：扩展名和体积。等到 50MB 传完再被服务器拒掉，用户已经白等一分钟
 const checkFile=file=>{
  if(!file)return '请先选择文件';
  const lower=file.name.toLowerCase();
  if(IMPORT_EXTS.every(ext=>!lower.endsWith(ext)))return `不支持 ${lower.slice(lower.lastIndexOf('.'))} 文件，请导出为 txt / csv / json / zip`;
  if(file.size>IMPORT_MAX_BYTES)return `文件 ${(file.size/1048576).toFixed(1)}MB，超过 50MB 上限，请先拆分`;
  return '';
 };
 $('#import-file').onchange=e=>{
  const file=e.target.files[0];const box=$('#import-file-name');
  if(box)box.textContent=file?file.name:'支持微信、QQ、抖音等导出的聊天记录；zip 可带图片';
  resetPreview();hideProgress();error.textContent='';
  const bad=file?checkFile(file):'';
  if(bad){showError(bad);previewBtn.disabled=true;return;}
  previewBtn.disabled=false;
  if(file)showError('');
 };
 previewBtn.onclick=async()=>{
  const file=$('#import-file').files[0];
  const bad=checkFile(file);if(bad){showError(bad);return;}
  showError('');previewBtn.disabled=true;previewBtn.textContent='解析中…';
  previewBox.innerHTML='<p class="meta">正在解析…</p>';
  const data=new FormData();data.append('file',file);
  setProgress(null,'正在上传并解析…');
  try{
   preview=await postForm('/imports/preview',data,
    r=>setProgress(r,`上传中 ${Math.round(r*100)}%`));
   hideProgress();
   const range=preview.start_at?`${dateLabel(preview.start_at)} ~ ${dateLabel(preview.end_at)}`:'时间未知';
   previewBox.innerHTML=`<div class="import-preview-box"><p>识别到 <strong>${preview.count}</strong> 条记录 · ${range}</p><p class="meta">参与人：${preview.participants.map(esc).join('、')||'未识别'}</p>${preview.media_count?`<p class="meta">其中 ${preview.media_count} 张图片会一并导入</p>`:''}${selectField('这里哪个昵称是我（显示在右侧）','me',preview.participants.map(p=>[p,p]),preview.participants[0]||'')}</div>`;
   submit.disabled=false;
  }catch(e){
   resetPreview();hideProgress();showError(e.message);
  }finally{previewBtn.disabled=false;previewBtn.textContent='解析预览';}
 };
 form.onsubmit=async e=>{
  e.preventDefault();
  if(!preview){showError('请先点「解析预览」确认内容');return;}
  const file=$('#import-file').files[0];
  const bad=checkFile(file);if(bad){showError(bad);return;}
  showError('');submit.disabled=true;submit.textContent='导入中…';
  const data=new FormData();data.append('file',file);
  data.append('platform',form.platform.value);data.append('title',form.title.value);
  data.append('me',form.me?form.me.value:'');
  setProgress(0,'上传中 0%');
  try{
   const result=await postForm('/imports',data,r=>{
    if(r>=1)setProgress(null,`已上传完，正在写入 ${preview.count} 条记录…`);
    else setProgress(r,`上传中 ${Math.round(r*100)}%`);
   });
   hideProgress();
   state.importId=result.id;closeModal();await refresh();navigate('imports');
   toast(`已导入 ${result.count} 条聊天记录${result.media_count?`，含 ${result.media_count} 张图片`:''}`);
  }catch(err){
   hideProgress();showError(err.message);
  }finally{submit.disabled=false;submit.textContent='确认导入';}
 };
}

function calDetailHTML(){
 const [y,m]=state.calMonth.split('-').map(Number);
 const days=state.calDays||{},person=id=>state.me.users.find(u=>u.id===id);
 const selected=state.calSelected;
 if(!selected)return '';
 const sel=days[selected]||null;
 return `<div class="card"><h3>${y}-${m}-${selected} 这一天</h3>${sel?(sel.anniversaries||[]).map(a=>`<div class="otd-item"><span class="otd-year">纪念</span><button class="link-btn" data-action="otd-detail" data-id="${a.id}">${esc(a.title)}</button></div>`).join('')+(sel.moods||[]).map(md=>`<div class="otd-item"><span class="otd-year">心情</span><span class="meta">${esc(person(md.author)?.name||'')}: ${esc(md.emoji)}</span></div>`).join('')+(sel.posts||[]).map(p=>`<div class="otd-item"><span class="otd-year">动态</span><button class="link-btn" data-action="otd-detail" data-id="${p.id}">${esc(p.title||'一份回忆')}</button></div>`).join('')+(sel.checks?.length?`<div class="otd-item"><span class="otd-year">打卡</span><span class="meta">${sel.checks.length} 人完成</span></div>`:''):'<p class="meta">这一天还没有记录。</p>'}</div>`;
}
function calendarPage(){
 if(!state.calMonth){const d=new Date();state.calMonth=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');}
 const [y,m]=state.calMonth.split('-').map(Number);
 const first=new Date(y,m-1,1),start=first.getDay(),daysInMonth=new Date(y,m,0).getDate();
 const cells=[];for(let i=0;i<start;i++)cells.push('');
 for(let d=1;d<=daysInMonth;d++)cells.push(String(d).padStart(2,'0'));
 const days=state.calDays||{};
 const selected=state.calSelected;
 const t=today(),todayDay=t.startsWith(`${y}-${String(m).padStart(2,'0')}`)?String(Number(t.slice(8))):'';
 return `<div class="calendar-page">${heading('共同年历','重要的日子，一眼看清。','')}<div class="tabs"><button data-action="tools-back">← 回到我们</button></div><div class="calendar-head"><button class="icon-btn" data-action="cal-prev" aria-label="上个月"><svg class="icon" viewBox="0 0 24 24" style="transform:scaleX(-1)"><path d="${'M9 6 15 12 9 18'}"/></svg></button><strong>${y} 年 ${m} 月</strong><button class="icon-btn" data-action="cal-next" aria-label="下个月">${icon('arrow')}</button></div><div class="calendar-grid">${['日','一','二','三','四','五','六'].map(w=>`<span class="cal-week">${w}</span>`).join('')}${cells.map(d=>{if(!d)return '<span></span>';const info=days[d],dots=info?[['anniversaries','var(--primary)','纪念日'],['moods','var(--green)','心情'],['posts','var(--primary-dark)','动态'],['checks','var(--primary)','打卡']].filter(([k])=>info[k]?.length).map(([k,c,t])=>`<i class="cal-dot" style="background:${c}" title="${t}"></i>`).join(''):'';return `<button class="cal-day ${selected===d?'selected':''} ${info?'has-events':''} ${String(Number(d))===todayDay?'is-today':''}" data-action="cal-day" data-id="${d}" aria-label="${m} 月 ${Number(d)} 日${info?'，有记录':''}"><span>${Number(d)}</span><span class="cal-dots">${dots}</span></button>`;}).join('')}</div><div id="cal-detail">${calDetailHTML()}</div></div>`;
}
const toolsList=[['calendar','🗓️','共同年历','重要的日子，一眼看清'],['anniversary','📅','纪念日','每个重要的日子，都认真对待'],['wish','✨','共同愿望','把一起想做的事，一件件实现'],['personal-wish','💝','个人心愿','对方看得到心愿名称，输入一次密码后就能读到内容'],['mood','🌤','心情手记','晴天雨天，都想陪着你'],['note','💌','悄悄留言','有些喜欢，值得慢慢读'],['question','💭','情侣问答','每天再多了解彼此一点'],['habit','🌱','共同打卡','和你一起，成为更好的我们']];
function togetherPage() {
 if(state.tab==='calendar')return calendarPage();
 if(state.tab==='personal-wish')return personalWishPage();
 if(state.tab){const meta=toolsList.find(x=>x[0]===state.tab);if(meta)return `${heading(meta[2],meta[3],'new-'+state.tab,'添加'+({anniversary:'纪念日',wish:'愿望',mood:'心情',note:'留言',question:'问题',habit:'目标'}[state.tab]))}<div class="tabs"><button data-action="tools-back">← 回到我们</button></div>${state.tab==='question'?'<p class="hint">可以写下自己的问题，也可以从内置题目里挑一个。双方回答后才揭晓彼此的答案。</p>':''}${recordsOf(state.tab).length?recordsOf(state.tab).map(recordCard).join(''):empty('给我们，多一点小小的仪式感',meta[3],'new-'+state.tab,'现在开始')}`;}
 return `${heading('关于我们，还有好多好多','把喜欢落在实处，把日子过成纪念。')}<div class="tools-grid"><button class="tool-card" data-nav="dashboard"><span class="tool-emoji">📊</span><h3>数据看板</h3><p>我们的点滴，都在这里</p></button><button class="tool-card" data-nav="weekly"><span class="tool-emoji">✉️</span><h3>回忆周报</h3><p>把这一周，收进一封信</p></button>${toolsList.map(([id,emoji,title,desc])=>`<button class="tool-card" data-action="tool-${id}"><span class="tool-emoji">${emoji}</span><h3>${title}</h3><p>${desc}</p></button>`).join('')}</div><div class="section-heading settings-section-heading"><h2>${icon('gear')} 设置</h2></div><div class="tools-grid settings-tools"><button class="tool-card" data-action="space"><span class="tool-emoji">🏡</span><h3>空间设置</h3><p>空间名称、封面与相恋日期</p></button>${state.me.users.length<2?`<button class="tool-card" data-action="invite"><span class="tool-emoji">💌</span><h3>邀请另一半入住</h3><p>把你们的专属空间分享给 TA</p></button>`:''}<button class="tool-card" data-nav="channels"><span class="tool-emoji">🔔</span><h3>提醒设置</h3><p>通知渠道与提醒偏好</p></button><button class="tool-card" data-nav="settings"><span class="tool-emoji">⚙️</span><h3>全部设置</h3><p>账号资料、数据导出与备份</p></button></div>`;
}
function personalWishPage(){const wishes=recordsOf('personal_wish');return `${heading('个人心愿','写下的人可以直接回看，对方输入一次密码后就能一直看到。','new-personal-wish','许下心愿','heart')}<div class="tabs"><button data-action="tools-back">← 回到我们</button></div><p class="hint">心愿名称彼此可见。密码至少 6 位（建议纯数字），每条心愿都要不同；告诉对方后，对方解锁一次即可永久查看。</p>${wishes.length?wishes.map(personalWishCard).join(''):empty('留一份只差密码就能打开的心愿','对方能看见心愿名称，具体内容仍由你掌握。','new-personal-wish','许下第一份心愿')}`;}
function dashboardPage(){
 const d=state.dashboard;
 const back='<div class="tabs"><button data-action="tools-back">← 回到我们</button></div>';
 if(!d)return `${heading('数据看板','我们的点点滴滴，都在这里。')}${back}<p class="hint">正在整理数据…</p>`;
 const months=d.months||[],peak=Math.max(1,...months.map(m=>m.count));
 const bars=months.length?months.map(m=>`<div class="bar" title="${esc(m.month)} · ${m.count} 条"><i style="height:${Math.max(4,Math.round(m.count/peak*100))}%"></i><span>${Number(m.month.slice(5))}月</span></div>`).join(''):'<p class="meta">还没有记录，写下第一条就会出现在这里。</p>';
 const total=Math.max(1,d.total||0);
 const kinds=Object.entries(d.by_kind||{}).filter(([k])=>kindLabel[k]).sort((a,b)=>b[1]-a[1]);
 const kindRows=kinds.length?kinds.map(([k,n])=>`<div class="stat-row"><span>${kindLabel[k]}</span><div class="stat-bar"><i style="width:${Math.round(n/total*100)}%"></i></div><b>${n}</b></div>`).join(''):'<p class="meta">还没有记录。</p>';
 const moods=Object.entries(d.moods||{}).sort((a,b)=>b[1]-a[1]),peakMood=Math.max(1,...moods.map(x=>x[1]));
 const moodRows=moods.length?moods.map(([e,n])=>`<div class="mood-stat"><span class="mood-emoji">${esc(e)}</span><div class="stat-bar"><i style="width:${Math.round(n/peakMood*100)}%"></i></div><b>${n}</b></div>`).join(''):'<p class="meta">还没有心情记录。</p>';
 const wn=d.wishes_total||0,wd=d.wishes_done||0,wp=wn?Math.round(wd/wn*100):0;
 return `${heading('数据看板','把日子过成数据，也过成回忆。')}${back}<div class="stats-hero"><div class="stat-card"><span>在一起</span><strong>${d.days_together==null?'—':d.days_together}<em>天</em></strong></div><div class="stat-card"><span>共同记录</span><strong>${d.total}<em>条</em></strong></div><div class="stat-card"><span>照片</span><strong>${d.photos}<em>张</em></strong></div><div class="stat-card"><span>互动</span><strong>${(d.likes||0)+(d.comments||0)}<em>次</em></strong></div></div><div class="grid-2"><section class="card"><div class="section-heading"><h2>${icon('book')} 最近一年</h2></div><div class="bars">${bars}</div><p class="small-note">每个月写下的记录条数</p></section><section class="card"><div class="section-heading"><h2>${icon('heart')} 愿望进度</h2></div>${wn?`<p class="meta">已实现 <strong>${wd}</strong> / ${wn} 个共同愿望</p><div class="stat-bar big"><i style="width:${wp}%"></i></div><p class="small-note">完成度 ${wp}%</p>`:'<p class="meta">还没有共同愿望，去许一个吧。</p>'}</section></div><div class="grid-2"><section class="card"><div class="section-heading"><h2>记录构成</h2></div>${kindRows}</section><section class="card"><div class="section-heading"><h2>心情分布</h2></div>${moodRows}</section></div><section class="card"><div class="section-heading"><h2>${icon('chat')} 互动小结</h2></div><div class="stats-hero" style="grid-template-columns:repeat(2,minmax(0,1fr));margin:0"><div class="stat-card"><span>喜欢</span><strong>${d.likes||0}<em>次</em></strong></div><div class="stat-card"><span>留言与评论</span><strong>${d.comments||0}<em>条</em></strong></div></div><p class="small-note">私密日记、草稿与定时惊喜只统计你自己的，另一半看不到；这里的数字只包含你能看到的内容。</p></section>`;
}
function weeklyPage(){
 const w=state.weekly;
 const back='<div class="tabs"><button data-action="tools-back">← 回到我们</button></div>';
 if(!w)return `${heading('回忆周报','把这一周，收进一封小小的信。')}${back}<p class="hint">正在整理这一周…</p>`;
 const off=w.offset||0,short=d=>d.slice(5).replace('-','.');
 const delta=w.delta>0?`比上一周多写了 ${w.delta} 条`:w.delta<0?`比上一周少了 ${-w.delta} 条`:'和上一周一样多';
 const kinds=Object.entries(w.by_kind||{}).filter(([k])=>kindLabel[k]).sort((a,b)=>b[1]-a[1]),total=Math.max(1,w.total||0);
 const kindRows=kinds.length?kinds.map(([k,n])=>`<div class="stat-row"><span>${kindLabel[k]}</span><div class="stat-bar"><i style="width:${Math.round(n/total*100)}%"></i></div><b>${n}</b></div>`).join(''):'<p class="meta">这一周还没有记录。</p>';
 const moods=Object.entries(w.moods||{}).sort((a,b)=>b[1]-a[1]),peak=Math.max(1,...moods.map(x=>x[1]));
 const moodRows=moods.length?moods.map(([e,n])=>`<div class="mood-stat"><span class="mood-emoji">${esc(e)}</span><div class="stat-bar"><i style="width:${Math.round(n/peak*100)}%"></i></div><b>${n}</b></div>`).join(''):'<p class="meta">这一周还没有心情记录。</p>';
 return `${heading('回忆周报','把这一周，收进一封小小的信。')}${back}<div class="tabs week-switch"><button data-action="week-prev">← 上一周</button><span class="week-range">${w.start.slice(0,4)} 年 · ${short(w.start)} – ${short(w.end)}</span><button data-action="week-next" ${off>=0?'disabled':''}>下一周 →</button></div><section class="card week-hero"><div class="eyebrow">WEEKLY LETTER</div><h2>${esc(w.message)}</h2><p class="meta">${esc(delta)}${w.top_mood?` · 这周最常见的心情是 ${esc(w.top_mood)}`:''}</p></section><div class="stats-hero"><div class="stat-card"><span>记录</span><strong>${w.total}<em>条</em></strong></div><div class="stat-card"><span>有记录的天数</span><strong>${w.days_active}<em>天</em></strong></div><div class="stat-card"><span>照片</span><strong>${w.photos}<em>张</em></strong></div><div class="stat-card"><span>互动</span><strong>${(w.likes||0)+(w.comments||0)}<em>次</em></strong></div></div><div class="grid-2"><section class="card"><div class="section-heading"><h2>这一周写了什么</h2></div>${kindRows}</section><section class="card"><div class="section-heading"><h2>心情分布</h2></div>${moodRows}</section></div>${w.highlights.length?`<div class="section-heading"><h2>${icon('heart')} 本周精选</h2></div>${w.highlights.map(recordCard).join('')}`:empty('这一周的信封还是空的','写下一点什么，下一封周报就会有了。','compose','记录此刻')}<div class="inline-actions" style="margin-top:16px">${button('复制文字版','week-copy','small soft','download')}${button('回到我们','tools-back','small secondary')}</div>`;
}
function settingsPage() {
 const v=state.appVersion||{};
 return `${heading('设置','管理空间、账号和数据。')}<div class="settings-grid"><section class="card"><h2>${icon('home')} 空间设置</h2><div class="setting-list"><button data-action="space">名称、封面与主题 ${icon('arrow')}</button>${state.me.users.length<2?`<button data-action="invite">邀请另一半 ${icon('arrow')}</button>`:''}<button data-nav="channels">通知渠道与提醒偏好 ${icon('arrow')}</button></div></section><section class="card"><h2>${icon('gear')} 我的账号</h2><div class="setting-list"><button data-action="profile">头像、昵称与密码 ${icon('arrow')}</button><button data-action="logout">退出登录 ${icon('arrow')}</button></div></section><section class="card"><h2>${icon('download')} 数据管理</h2><div class="setting-list"><a href="/api/export" download>导出我有权查看的记录与原文件 ${icon('download')}</a>${state.me.user.admin?`<button data-nav="backups">完整备份与迁移 ${icon('arrow')}</button>`:''}</div><p class="small-note">私密日记按账号隔离，完整备份由服务器管理员管理。</p></section><section class="card"><h2>${icon('info')} 关于</h2><div class="setting-list"><div style="display:flex;align-items:center;gap:10px;padding:12px 0"><span class="stat-icon" style="font-size:28px">💕</span><div><h3 style="margin:0;font-size:15px">恋爱空间</h3><p class="meta" style="margin:2px 0 0">${v.version?'v'+v.version+' · '+v.build+(state.apkVersion?' · APK v'+state.apkVersion:''):'加载中…'}</p></div></div><button data-action="check-update">检查更新 ${icon('arrow')}</button></div><p class="small-note">网页功能自动更新；原生功能（如后台通知）需下载新版 APK，可在检查更新中获取。</p></section></div>`;
}
function personalPage() {
 const tab=state.tab||'diary',tabs=[['diary','私密日记'],['draft','草稿箱'],['surprise','定时惊喜'],['trash','回收站']];
 let content='';
 if(tab==='settings')return settingsPage();
 if(tab==='trash')content=`<p class="hint">删除的内容保留三十天，你可以恢复自己的记录。</p>${(state.trash||[]).length?state.trash.map(r=>`<article class="card"><h3>${esc(r.body.title||r.body.content||kindLabel[r.kind])}</h3><p class="meta">${kindLabel[r.kind]} · ${dateLabel(r.deleted)} 删除</p><div class="inline-actions">${button('恢复这份回忆','restore','soft small','clock',`data-id="${r.id}"`)}</div></article>`).join(''):empty('回收站是空的','你的回忆都在好好保存。')}`;
 else content=`<p class="hint">${icon('lock')} ${tab==='surprise'?'到约定的时间，惊喜才会被另一半看见。':'这个角落只有你能看见。草稿主动发布后，才会进入共同空间。'}</p>${recordsOf(tab).length?recordsOf(tab).map(recordCard).join(''):empty(tab==='diary'?'给自己，留一点心里话':tab==='draft'?'还没写完的故事，在这里等你':'提前准备一份温柔的惊喜','慢慢写，不着急。',tab==='draft'?'compose':'new-'+tab,tab==='draft'?'写一份草稿':'开始记录')}`;
 return `${heading('我的小角落','有些心事留给自己，有些惊喜留给未来。',['diary','surprise'].includes(tab)?'new-'+tab:'',tab==='surprise'?'准备惊喜':'写日记')}<div class="tabs">${tabs.map(([id,label])=>`<button data-action="personal-tab" data-id="${id}" class="${tab===id?'active':''}">${label}</button>`).join('')}</div>${content}`;
}
function noticesPage(){const sysNotices=state.notices.filter(n=>n.event!=='chat'),readCount=sysNotices.filter(n=>n.seen).length;return `${heading('小小的提醒','每一份回应，都值得被看见。','read-notices','全部已读','check')}${readCount?`<div class="inline-actions" style="justify-content:flex-end;margin:-8px 0 16px">${button('删除已读提醒（'+readCount+'）','delete-read-notices','small secondary','trash')}</div>`:''}<div class="card">${sysNotices.length?sysNotices.map(n=>`<div class="notice ${n.seen?'':'unread'}"><span class="stat-icon">${icon(n.event==='chat'?'chat':'bell')}</span><div><p>${esc(n.title)}</p><small class="meta">${dateLabel(n.created)}</small></div>${n.record_id?`<button class="link-btn" style="margin-left:auto" data-action="notice-detail" data-id="${n.record_id}">查看 ${icon('arrow')}</button>`:''}</div>`).join(''):empty('还没有新的提醒','收到留言、互动和纪念日提醒时，会出现在这里。聊天消息请在私聊中查看。')}</div>`;}
const channelNames={smtp:'邮件',bark:'Bark',serverchan:'Server酱',pushplus:'PushPlus',wecom:'企业微信机器人',webhook:'自定义 Webhook',telegram:'Telegram',dingtalk:'钉钉机器人',feishu:'飞书机器人',ntfy:'ntfy'};
const eventNames={chat:'聊天消息',comment:'点赞与评论',note:'留言',activity:'新动态与互动',anniversary:'纪念日',wish:'愿望到期',surprise:'惊喜公开',backup:'备份失败',storage:'空间不足',system:'系统消息'};
function nativePushCard(){
 return '<section class="card"><div class="section-heading"><h2>'+icon('bell')+' 安卓后台提醒</h2><span class="status-pill pending">已停用</span></div><p class="meta">手机端弹窗/锁屏系统通知已停用，提醒改由第三方渠道（如企业微信机器人）或电脑浏览器的系统通知送达。请在上方「添加渠道」配置；聊天消息会合并通知（如「你有 N 条新消息」），在聊天页停留时不再重复推送。</p></section>';
}
function channelsPage(){
 const native=isNativeApp(),supported=browserPushSupported();
 const webpushCard=native?'':`<section class="card webpush-card"><div class="section-heading"><h2>${icon('bell')} 浏览器系统通知</h2><span class="status-pill ${state.webpush?.local?'sent':'pending'}">${state.webpush?.local?'本设备已开启':(state.webpush?.devices?`已绑定 ${state.webpush.devices} 台设备`:'尚未开启')}</span></div><p class="meta">网页关闭或切到后台时，也可由系统送达提醒。锁屏通知只显示通用提示，不包含聊天或心愿内容。${/iphone|ipad|ipod/i.test(navigator.userAgent)?' iPhone/iPad 请先将恋爱空间添加到主屏幕，再开启通知。':''}</p>${!supported?'<p class="small-note">当前浏览器不支持网页系统通知，请使用支持通知的浏览器或配置其他通知渠道。</p>':state.webpush?.local?`<div class="inline-actions">${button('发送测试通知','test-webpush','small soft','bell')}${button('关闭本设备通知','disable-webpush','small secondary')}</div>`:button('开启本设备通知','enable-webpush','small primary','bell')}</section>`;
 return `${heading('不错过，每一份在意','让想念与提醒，抵达你喜欢的地方。','new-channel','添加渠道','bell')}${native?nativePushCard():''}${webpushCard}<p class="hint">可同时启用多个渠道，各自设置事件和免打扰时间。外部通知只发送提醒摘要，详情请登录空间查看。测试发送会跳过免打扰。</p><div class="channel-list">${state.channels.length?state.channels.map(c=>`<div class="card"><span class="stat-icon">${icon('bell')}</span><div><h3>${esc(c.name)}</h3><p class="meta">${channelNames[c.kind]} · ${c.quiet_start===c.quiet_end?'全天接收':c.quiet_start+':00–'+c.quiet_end+':00 免打扰'}<br>${c.events.map(x=>eventNames[x]).join('、')}</p></div><div class="inline-actions">${button('测试','test-channel','small soft','',`data-id="${c.id}"`)}${button('移除','delete-channel','small secondary','',`data-id="${c.id}"`)}</div></div>`).join(''):empty('选择你的提醒方式','支持邮件、Bark、Server酱、PushPlus、企业微信、Telegram、钉钉、飞书、ntfy 和 Webhook。','new-channel','添加第一个渠道')}</div><section class="card"><div class="section-heading"><h2>最近发送记录</h2>${button('刷新','refresh','small secondary')}</div>${state.deliveries.length?state.deliveries.map(d=>`<div class="delivery"><div><p>${esc(d.title)} · ${esc(d.name)}</p><small class="meta">${d.error?esc(d.error):d.sent_at?dateLabel(d.sent_at):'等待发送'} · 尝试 ${d.attempts} 次</small></div><span class="status-pill ${d.status}">${({sent:'已发送',pending:'待发送',sending:'发送中',failed:'失败',merged:'已合并',skipped:'已跳过'})[d.status]}</span>${d.status==='failed'?button('重试','retry-delivery','small secondary','',`data-id="${d.id}"`):''}</div>`).join(''):'<p class="meta">配置好渠道后，点击测试即可验证能否收到通知。</p>'}</section>`;
}
function backupsPage(){const s=state.storage||{};const fmt=b=>b>=1073741824?(b/1073741824).toFixed(2)+' GB':(b/1048576).toFixed(1)+' MB';const pct=s.disk_total?Math.round((1-s.disk_free/s.disk_total)*100):0;const kindBars=[['image','照片'],['video','视频'],['audio','语音']].map(([k,l])=>{const v=s.media_by_kind?.[k]||0;const total=s.media_by_kind?Object.values(s.media_by_kind).reduce((a,b)=>a+b,0):0;return `<div class="storage-bar"><span>${l}</span><div class="bar-track"><div class="bar-fill" style="width:${total?Math.round(v/total*100):0}%"></div></div><span class="meta">${fmt(v)}</span></div>`;}).join('');return `${heading('让回忆，有一个安心的家','完整备份、迁移和恢复。','backup','立即备份','download')}<section class="card storage-panel"><div class="section-heading"><h2>${icon('gear')} 存储占用</h2></div><div class="storage-overview"><div class="storage-stat"><strong>${fmt(s.total||0)}</strong><small>已使用</small></div><div class="storage-stat"><strong>${fmt(s.disk_free||0)}</strong><small>可用空间</small></div><div class="storage-stat"><strong>${pct}%</strong><small>磁盘占用率</small></div></div>${kindBars}<div class="storage-meta"><p class="meta">数据库 ${fmt(s.db||0)} · 备份 ${fmt(s.backups||0)} · ${s.record_count||0} 条记录 · ${s.media_count||0} 个媒体文件</p></div></section><p class="hint">每天自动备份，保留最近七份成功备份。完整备份包含双方数据与渠道密钥，仅供服务器管理员妥善保管。恢复操作通过服务器命令进行，并恢复到新的空目录。</p><section class="card">${(state.backups||[]).length?state.backups.map(b=>`<div class="delivery"><div class="backup-name"><p>${esc(b.name)}${b.encrypted?' <span class="status-pill sent">🔒 已加密</span>':''}</p><small class="meta">${dateLabel(b.created)} · ${(b.size/1024/1024).toFixed(2)} MB</small></div><a class="button secondary small" href="/api/backups/${encodeURIComponent(b.name)}" download>${icon('download')} 下载</a></div>`).join(''):empty('备份还未生成','可以现在创建第一份完整备份。')}</section>`;}

function openModal(title,content,{wide=false,sheet=false,cleanup=null}={}) {
 closeModal(); focusReturn=document.activeElement;
 $('#modal-root').innerHTML=`<div class="modal-overlay${sheet?' sheet':''}"><section class="modal ${wide?'wide':''}${sheet?' sheet':''}" role="dialog" aria-modal="true" aria-labelledby="modal-title"><header class="modal-header"><h2 id="modal-title">${esc(title)}</h2><button class="icon-btn" data-action="close-modal" aria-label="关闭">${icon('close')}</button></header>${content}</section></div>`;
 modalCleanup=cleanup;document.body.style.overflow='hidden';setTimeout(()=>$('.modal input:not([type=checkbox]),.modal textarea,.modal button')?.focus(),50);
}
function closeModal(){if(modalCleanup){modalCleanup();modalCleanup=null;}$('#modal-root').innerHTML='';document.body.style.overflow='';focusReturn?.focus?.();}
function field(label,name,value='',type='text',extra=''){return `<label>${label}<input name="${name}" type="${type}" value="${esc(value)}" ${extra}></label>`;}
function selectField(label,name,options,value){return `<label>${label}<select name="${name}">${options.map(([v,l])=>`<option value="${esc(v)}" ${String(value)===String(v)?'selected':''}>${esc(l)}</option>`).join('')}</select></label>`;}
function simpleForm(title,fields,onSubmit,label='保存') {
 openModal(title,`<form class="modal-form" id="simple-form">${fields}<div class="form-error" role="alert"></div><div class="form-actions">${button('取消','close-modal')}<button class="button primary" type="submit">${label}</button></div></form>`);
 $('#simple-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=$('button[type=submit]',form);b.disabled=true;try{await onSubmit(Object.fromEntries(new FormData(form)),form);closeModal();await refresh();toast('已保存这份小美好');}catch(err){$('.form-error',form).textContent=err.message;}finally{b.disabled=false;}};
}
function personalWishForm(){const clientId=uuid();openModal('许下一份个人心愿',`<form class="modal-form" id="personal-wish-form"><label>心愿名称（对方可见）<input name="title" required maxlength="100" placeholder="例如：有一天想和你去看海"></label><label>具体心愿内容（需要密码才能查看）<textarea name="content" required maxlength="20000" placeholder="写下想留给自己的心愿…"></textarea></label><label>这条心愿的独立密码<input name="password" type="password" required minlength="6" maxlength="128" inputmode="numeric" autocomplete="new-password" placeholder="至少 6 位，建议纯数字"></label><p class="small-note">每条心愿都要设置不同密码。写下心愿的你可以直接回看内容；把密码告诉对方后，对方输入一次就能看到，之后不必再输。忘记密码无法找回。</p><div class="form-error" role="alert"></div><div class="form-actions">${button('取消','close-modal')}<button class="button primary" type="submit">加密保存</button></div></form>`);$('#personal-wish-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);submit.disabled=true;try{await post('/personal-wishes',{...Object.fromEntries(new FormData(form)),client_id:clientId});closeModal();await refresh();toast('这份个人心愿已加密保存');}catch(err){$('.form-error',form).textContent=err.message;}finally{submit.disabled=false;}};}
function unlockPersonalWish(rid){const wish=state.records.find(r=>r.id===rid);if(!wish)return;openModal('打开这份个人心愿',`<form class="modal-form" id="unlock-personal-wish-form"><p class="meta">「${esc(wish.body.title)}」的内容已加密，请输入心愿本人交给你的密码。</p><label>心愿密码<input name="password" type="password" required maxlength="128" autocomplete="current-password" placeholder="向心愿本人获取这条心愿的密码"></label><div class="form-error" role="alert"></div><div class="form-actions">${button('取消','close-modal')}<button class="button primary" type="submit">解锁心愿</button></div></form>`);$('#unlock-personal-wish-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);submit.disabled=true;try{await post('/personal-wishes/'+encodeURIComponent(rid)+'/unlock',Object.fromEntries(new FormData(form)));closeModal();await refresh();toast('已解锁，内容现在直接显示在心愿卡片里');}catch(err){$('.form-error',form).textContent=err.message;}finally{submit.disabled=false;}};}
async function confirmAction(title,text,callback) {openModal(title,`<p class="meta">${esc(text)}</p><div class="form-actions" style="margin-top:25px">${button('再想想','close-modal')}<button class="button danger" id="confirm-yes">确认</button></div>`);$('#confirm-yes').onclick=async e=>{e.currentTarget.disabled=true;try{await callback();closeModal();await refresh();}catch(err){toast(err.message);e.target.disabled=false;}};}

function uploadFile(file,onProgress=()=>{}) {return new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest(),data=new FormData();data.append('file',file);xhr.open('POST','/api/media');xhr.setRequestHeader('X-Love-Space','1');xhr.upload.onprogress=e=>{if(e.lengthComputable)onProgress(Math.round(e.loaded/e.total*100));};xhr.onload=()=>{let result;try{result=JSON.parse(xhr.responseText);}catch{return reject(new Error('上传失败，请重试'));}if(xhr.status>=200&&xhr.status<300)resolve(result);else reject(new Error(result.detail||'上传失败'));};xhr.onerror=()=>reject(new Error('网络中断，文字和已上传附件已保留，可重新选择文件上传'));xhr.send(data);});}

function composer(kind='post',record=null,prefill={}) {
 const key='composer:'+state.me.user.id+':'+(record?.id||kind);
 let saved={};try{saved=JSON.parse(localStorage.getItem(key)||'{}');}catch{}
 let data={date:today(),media:[],...prefill,...(record?.body||{}),...saved},media=[...(saved.mediaObjects||record?.media||prefill.mediaObjects||[])],recording=null,stream=null,uploading=false,closed=false;
 const draftKind=record?.kind==='draft';
 const actualKind=record?.kind||kind;
 let commitId=saved.client_id||uuid();
 const persist=()=>{const form=$('#composer-form');if(!form)return;const vals=Object.fromEntries(new FormData(form));localStorage.setItem(key,JSON.stringify({...vals,media:media.map(m=>m.id),mediaObjects:media,client_id:commitId}));};
 openModal(actualKind==='chat'?'分享一个瞬间':record?'继续写我们的故事':kind==='diary'?'给自己的心里话':kind==='surprise'?'藏一份未来的惊喜':'记录此刻的小美好',`<form id="composer-form" class="modal-form">${actualKind!=='chat'?field('给这份回忆一个小标题（可选）','title',data.title||'','text','maxlength="200"'):''}<label>${actualKind==='diary'?'只有你能看见，放心写吧':'这一刻，想说些什么？'}<textarea name="content" maxlength="20000" placeholder="今天的小事，也值得认真收藏…">${esc(data.content||'')}</textarea></label>${actualKind!=='chat'?`<div class="form-row">${field('事情发生的日期','date',data.date,'date','required')}${selectField('收进相册','album',[['','暂不分类'],...recordsOf('album').map(a=>[a.id,a.body.title])],data.album||state.album||'')}</div>`:''}${kind==='surprise'||actualKind==='surprise'?field('给 TA 看见的时间','publish_at',data.publish_at?localDateTime(data.publish_at):'','datetime-local','required'):''}<div class="upload-zone"><div class="upload-main"><label class="upload-tile"><span class="upload-ico">🖼️</span><b>照片 / 视频</b><small>选图或拍摄</small><input type="file" id="composer-files" accept="image/jpeg,image/png,image/webp,image/gif,image/heic,image/heif,video/mp4,video/quicktime,video/webm" multiple></label><label class="upload-tile"><span class="upload-ico">🎵</span><b>语音</b><small>上传已有音频</small><input type="file" id="composer-audio" accept="audio/*"></label><button type="button" class="upload-tile" data-action="record-audio"><span class="upload-ico">🎙️</span><b>录音</b><small>现场说两句</small></button></div><p class="small-note">原文件会被保留 · 最多三十个附件，可调整顺序，也支持把文件拖进来</p></div><div class="upload-preview" id="upload-preview"></div><div class="switch-row"><span id="upload-progress" class="progress"></span></div><div class="form-error" role="alert"></div><p class="small-note">编辑内容自动暂存于当前浏览器。点击保存草稿，可同步到服务器。</p><div class="form-actions">${actualKind!=='chat'&&!record?.id?'<button class="button secondary" type="submit" name="mode" value="draft">保存草稿</button>':''}${draftKind?'<button class="button secondary" type="submit" name="mode" value="draft">继续存草稿</button>':''}<button class="button primary" type="submit" name="mode" value="${draftKind?'post':kind}">${actualKind==='chat'?'发送':kind==='diary'?'保存日记':kind==='surprise'?'藏好这份惊喜':record&&!draftKind?'保存修改':'发布到我们的时光'}</button></div></form>`,{cleanup:()=>{persist();closed=true;if(recording&&recording.state!=='inactive')recording.stop();stream?.getTracks().forEach(t=>t.stop());},sheet:actualKind==='post'||actualKind==='diary'||actualKind==='draft'||actualKind==='surprise'||actualKind==='chat'});
 const form=$('#composer-form'),progress=$('#upload-progress');
 function previews(){if(closed)return;$('#upload-preview').innerHTML=media.map((m,i)=>`<div class="upload-chip">${m.mime.startsWith('image/')?`<img src="/media/${m.id}?preview=true" alt="附件预览">`:''}<span class="filename">${esc(m.name)}</span><button type="button" data-move="${i}" aria-label="向前移动">←</button><button type="button" data-remove="${i}" aria-label="移除附件">移除</button></div>`).join('');persist();}
 async function addFiles(files){uploading=true;$$('button[type=submit]',form).forEach(b=>b.disabled=true);try{for(const file of files){if(closed)break;if(media.length>=30)throw new Error('每条记录最多三十个附件');progress.textContent='正在上传 '+file.name;const m=await uploadFile(file,p=>progress.textContent=`上传中 ${p}% · ${file.name}`);media.push(m);previews();}progress.textContent='附件已保存';}catch(e){$('.form-error',form).textContent=e.message;}finally{uploading=false;$$('button[type=submit]',form).forEach(b=>b.disabled=false);}}
 $('#composer-files').onchange=e=>{addFiles([...e.target.files]);e.target.value='';};
 $('#composer-audio').onchange=e=>{addFiles([...e.target.files]);e.target.value='';};
 const zone=$('.upload-zone',form);zone.ondragover=e=>{e.preventDefault();zone.classList.add('dragging');};zone.ondragleave=()=>zone.classList.remove('dragging');zone.ondrop=e=>{e.preventDefault();zone.classList.remove('dragging');if(e.dataTransfer?.files.length)addFiles([...e.dataTransfer.files]);};
 form.oninput=persist;
 $('#upload-preview').onclick=e=>{const move=e.target.closest('[data-move]'),remove=e.target.closest('[data-remove]');if(move){const i=Number(move.dataset.move);if(i>0)[media[i-1],media[i]]=[media[i],media[i-1]];}if(remove)media.splice(Number(remove.dataset.remove),1);previews();};
 $('[data-action="record-audio"]').onclick=async e=>{e.stopPropagation();const btn=e.currentTarget;if(recording&&recording.state==='recording'){recording.stop();btn.classList.remove('recording');btn.innerHTML='<span class="upload-ico">🎙️</span><b>录音</b><small>现场说两句</small>';return;}try{if(!navigator.mediaDevices?.getUserMedia||!window.isSecureContext)throw new Error('录音需要 HTTPS 环境；当前是非安全上下文，请改用公网 https:// 地址访问，或直接上传手机已有的音频文件');stream=await navigator.mediaDevices.getUserMedia({audio:true});const mime=['audio/webm','audio/mp4','audio/ogg'].find(m=>MediaRecorder.isTypeSupported(m));recording=new MediaRecorder(stream,mime?{mimeType:mime}:{});const chunks=[];recording.ondataavailable=event=>chunks.push(event.data);recording.onstop=()=>{stream.getTracks().forEach(t=>t.stop());if(!closed){const type=recording.mimeType.split(';')[0],ext=type.includes('mp4')?'m4a':type.includes('ogg')?'ogg':'webm';addFiles([new File(chunks,'语音记录.'+ext,{type})]);}};recording.start();btn.classList.add('recording');btn.innerHTML='<span class="upload-ico">⏹</span><b>完成录音</b><small>再点一次结束</small>';}catch(err){$('.form-error',form).textContent=err.message;toast(err.message);}};
 form.onsubmit=async e=>{e.preventDefault();if(uploading)return;const buttons=$$('button[type=submit]',form);buttons.forEach(b=>b.disabled=true);const selected=e.submitter?.value||kind;try{const values=Object.fromEntries(new FormData(form));delete values.mode;values.media=media.map(m=>m.id);if(values.publish_at)values.publish_at=new Date(values.publish_at).getTime()/1000;if(actualKind==='chat'){await sendChat(values,commitId);}else {const payload={kind:selected,body:values,client_id:commitId};if(record)await put('/records/'+record.id,payload);else await post('/records',payload);}modalCleanup=()=>{closed=true;stream?.getTracks().forEach(t=>t.stop());};localStorage.removeItem(key);closeModal();await refresh();toast(actualKind==='chat'?'已发送':'这一刻，已经好好收藏');}catch(err){persist();$('.form-error',form).textContent=err.message;}finally{buttons.forEach(b=>b.disabled=false);}};
 previews();
}
function localDateTime(timestamp){const d=new Date(timestamp*1000);return new Date(d-d.getTimezoneOffset()*60000).toISOString().slice(0,16);}

function recordForm(kind,record=null) {
 if(['post','diary','draft','surprise','chat'].includes(kind))return composer(kind,record);
 const b=record?.body||{};let fields='';
 if(kind==='mood')fields=selectField('今天的心情','emoji',[['☀️','☀️ 开心'],['🥰','🥰 想你'],['😌','😌 平静'],['☁️','☁️ 有点低落'],['🌧️','🌧️ 想要抱抱'],['🌱','🌱 充满期待']],b.emoji||'☀️')+field('心情日期','date',b.date||today(),'date','required');
 else if(kind!=='note')fields+=field(kind==='question'?'想问 TA 的问题':'标题','title',b.title||'','text','required maxlength="200"');
 if(kind==='question')fields+='<label>或挑选一个内置问题<select id="preset-question"><option value="">选择一个问题…</option><option>第一次心动，是哪个瞬间？</option><option>今年最想和我一起完成什么事？</option><option>什么样的陪伴让你最有安全感？</option><option>如果可以重温一天，你会选哪天？</option></select></label>';
 if(kind==='anniversary')fields+=`<div class="form-row">${field('日期','date',b.date||today(),'date','required')}${field('提前几天提醒','remind_days',b.remind_days??1,'number','min="0" max="365"')}</div><label class="switch-row">重复方式<select name="annual"><option value="true" ${b.annual===true||b.annual===undefined?'selected':''}>每年公历日期</option><option value="lunar" ${b.annual==='lunar'?'selected':''}>每年农历日期</option><option value="false" ${b.annual===false?'selected':''}>只纪念一次</option></select></label>`;
 if(kind==='wish')fields+=`<div class="form-row">${selectField('分类','category',[['日常','日常'],['旅行','旅行'],['美食','美食'],['约会','约会'],['其他','其他']],b.category||'日常')}${field('约定日期（可选）','target',b.target||'','date')}</div>`;
 if(kind!=='album')fields+=`<label>${kind==='mood'?'再说一句今天的心情':kind==='note'?'想对 TA 说的话':'补充一些小细节（可选）'}<textarea name="content" maxlength="20000" ${kind==='note'?'required':''}>${esc(b.content||'')}</textarea></label>`;
 simpleForm(record?'编辑'+kindLabel[kind]:'添加'+kindLabel[kind],fields,async(data)=>{data={...b,...data};if(kind==='anniversary'){const annVal=data.annual;data.annual=annVal==='true'?true:annVal==='lunar'?'lunar':false;data.remind_days=Number(data.remind_days);}if(record)await put('/records/'+record.id,{kind,body:data});else await post('/records',{kind,body:data,client_id:uuid()});});
 if(kind==='question')$('#preset-question').onchange=e=>{$('#simple-form [name=title]').value=e.target.value;};
}

function spaceForm() {
 const s=state.me.space;
 const darkPref=localStorage.getItem(DARK_KEY)||'auto';
 const bg=s.chat_bg||'',dim=s.chat_bg_dim??35,wm=s.chat_bg_media||'';
 /* 壁纸色卡：预设直接复用 .chat-wallpaper 的样式，所见即所得；选「用照片」时先弹文件选择 */
 const swatches=CHAT_BG_PRESETS.map(([key,label])=>{
  const on=key===bg;
  const art=key==='photo'
   ?(wm?`<span class="chat-wallpaper" aria-hidden="true" style="background-image:url('/media/${esc(wm)}?preview=true')"></span>`:'<span class="pico" aria-hidden="true">📷</span>')
   :(key?`<span class="chat-wallpaper" data-bg="${key}" aria-hidden="true"></span>`:'');
  return `<button type="button" class="wallpaper-swatch${on?' selected':''}${key==='photo'&&!wm?' photo-empty':''}" data-bg="${key}" aria-pressed="${on}">${art}<b>${label}</b></button>`;
 }).join('');
 simpleForm('空间设置',field('空间名称','name',s.name,'text','required maxlength="60"')+field('从哪一天开始相爱','since',s.since,'date')+`<div class="form-row">${selectField('主题色','theme',[['rose','草莓牛奶'],['peach','蜜桃奶油'],['lavender','香芋云朵'],['custom','自定义']],s.theme)}${selectField('夜间模式','dark',[['auto','跟随系统'],['on','始终开启'],['off','始终关闭']],darkPref)}</div><label>自定义颜色（主题选「自定义」时生效）<input type="color" name="custom_color" value="${s.custom_color||'#c6748a'}"></label><div class="file-picker"><span class="file-picker-title">更换封面照片</span><label class="upload-tile file-picker-tile"><span class="upload-ico">🖼️</span><b>选择封面照片</b><small id="cover-file-name">${s.cover?'已设置封面，可重新选择':'选择一张照片作为我们的空间封面'}</small><input type="file" id="cover-file" accept="image/jpeg,image/png,image/webp"></label></div><div class="wallpaper-picker"><span class="file-picker-title">聊天壁纸</span><div class="wallpaper-swatches" id="wallpaper-swatches">${swatches}</div><label class="wallpaper-dim-row">背景遮罩 <input type="range" name="chat_bg_dim" id="wallpaper-dim" min="0" max="80" step="5" value="${dim}"><span id="wallpaper-dim-val">${dim}%</span></label><label class="upload-tile file-picker-tile"><span class="upload-ico">🖼️</span><b>用你们的照片</b><small id="wallpaper-file-name">${wm?'已设置背景照片，可重新选择':'选一张照片铺在聊天背景上'}</small><input type="file" id="wallpaper-file" accept="image/jpeg,image/png,image/webp"></label><input type="hidden" name="chat_bg" value="${esc(bg)}"><input type="hidden" name="chat_bg_media" value="${esc(wm)}"><p class="small-note">遮罩越强，背景越淡、文字越清楚。壁纸对你们两个人同时生效。</p></div><label class="switch-row">启用轻柔动效<input name="motion" type="checkbox" ${s.motion?'checked':''}></label>`,async(data,form)=>{let cover=s.cover;const file=$('#cover-file').files[0];if(file)cover=(await uploadFile(file)).id;let wallpaper=data.chat_bg_media||'';const wfile=$('#wallpaper-file').files[0];if(wfile){wallpaper=(await uploadFile(wfile)).id;data.chat_bg='photo';}localStorage.setItem(DARK_KEY,data.dark);applyDarkMode();delete data.dark;if(data.theme!=='custom')data.custom_color='';if(data.theme==='custom'&&!data.custom_color)data.custom_color=s.custom_color||'#c6748a';data.chat_bg_dim=Math.min(80,Math.max(0,Number(data.chat_bg_dim)||0));await put('/space',{...data,cover,chat_bg_media:wallpaper,motion:$('[name=motion]',form).checked});applyCustomColor(data.theme,data.custom_color);});
 $('#cover-file').onchange=e=>{$('#cover-file-name').textContent=e.target.files[0]?.name||'选择一张照片作为我们的空间封面';};
 /* 色卡点选：「用照片」在还没有照片时先弹文件框，避免存下一个没有图的 photo 壁纸 */
 $('#wallpaper-swatches').onclick=e=>{
  const btn=e.target.closest('.wallpaper-swatch');if(!btn)return;
  const key=btn.dataset.bg;
  if(key==='photo'&&!$('#simple-form [name=chat_bg_media]').value){$('#wallpaper-file').click();return;}
  $('#simple-form [name=chat_bg]').value=key;
  $$('.wallpaper-swatch').forEach(b=>{const on=b===btn;b.classList.toggle('selected',on);b.setAttribute('aria-pressed',String(on));});
 };
 $('#wallpaper-file').onchange=e=>{
  const f=e.target.files[0];if(!f)return;
  $('#wallpaper-file-name').textContent=f.name;
  $('#simple-form [name=chat_bg]').value='photo';
  $$('.wallpaper-swatch').forEach(b=>{const on=b.dataset.bg==='photo';b.classList.toggle('selected',on);b.setAttribute('aria-pressed',String(on));b.classList.remove('photo-empty');});
 };
 $('#wallpaper-dim').oninput=e=>{$('#wallpaper-dim-val').textContent=e.target.value+'%';};
}
function personalWishCard(r){const own=r.author===state.me.user.id,open=r.body.locked===false;return `<article class="card personal-wish-card${open?' opened':''}"><div class="card-header">${avatar(r.author)}<div><strong>${own?'你':'TA'}的个人心愿</strong><small>${open?'已解锁 · 内容只有你们两人能看见':'具体内容已加密保存'}</small></div>${own?`<div class="card-menu"><details class="more-menu"><summary aria-label="更多操作" title="更多操作">⋯</summary><div class="menu-pop"><button data-action="delete-record" data-id="${r.id}" class="danger">${icon('trash')} 删除</button></div></details></div>`:''}</div><h3 class="card-title">${esc(r.body.title)}</h3>${open?`<p class="card-text wish-plain">${esc(r.body.content||'')}</p>`:`<p class="card-text">${own?'这是你写下的个人心愿，输入密码即可回看内容。':'TA 留了一份心愿给你，输入一次密码后就能一直读到内容。'}</p><div class="inline-actions">${button('输入密码查看','unlock-personal-wish','soft','lock',`data-id="${r.id}"`)}</div>`}</article>`;}
function profileForm(){const u=state.me.user;simpleForm('让 TA 一眼认出你',field('昵称','name',u.name,'text','required maxlength="30"')+`<div class="file-picker"><span class="file-picker-title">头像照片</span><label class="upload-tile file-picker-tile"><span class="upload-ico">🖼️</span><b>选择头像照片</b><small id="avatar-file-name">${u.avatar?'已设置头像，可重新选择':'上传一张照片，让 TA 一眼认出你'}</small><input type="file" id="avatar-file" accept="image/jpeg,image/png,image/webp"></label></div>`+field('原密码（修改密码时填写）','old_password','','password')+field('新密码（不修改请留空）','new_password','','password','minlength="10"'),async(data)=>{let avatarId=u.avatar;const file=$('#avatar-file').files[0];if(file)avatarId=(await uploadFile(file)).id;const res=await put('/profile',{...data,avatar:avatarId});if(res.login_required){state.me=null;state.stream?.close();closeModal();await boot();}});$('#avatar-file').onchange=e=>{$('#avatar-file-name').textContent=e.target.files[0]?.name||'上传一张照片，让 TA 一眼认出你';};}
async function inviteModal(){const data=await post('/invite');const url=location.origin+'/?invite='+encodeURIComponent(data.token);openModal('邀请你，住进我的小世界',`<p class="meta">把这个链接私下发给另一半。邀请仅可使用一次，二十四小时内有效；重新生成会让旧链接失效。</p><label style="margin-top:18px">专属邀请链接<input id="invite-url" readonly value="${esc(url)}"></label><div class="form-actions" style="margin-top:18px">${button('复制邀请链接','copy-invite','primary')}</div>`);}
let photoIndex = 0;
function preloadPhoto(id){ if(!id) return; const im = new Image(); im.src = `/media/${id}?preview=true`; }
function photoBodyHtml(){
 const photos = state.photos || [];
 if (!photos.length) return '';
 if (photoIndex < 0) photoIndex = 0;
 if (photoIndex >= photos.length) photoIndex = photos.length - 1;
 const p = photos[photoIndex];
 const arrows = `${photoIndex > 0 ? `<button type="button" class="photo-arrow left" data-action="photo-prev" aria-label="上一张">${icon('back')}</button>` : ''}${photoIndex < photos.length - 1 ? `<button type="button" class="photo-arrow right" data-action="photo-next" aria-label="下一张">${icon('arrow')}</button>` : ''}`;
 const caption = (p.caption || '').trim();
 return `<div class="lightbox-wrap"><img class="lightbox-image" src="/media/${p.id}?preview=true" alt="${esc(p.caption||'我们的照片')}">${arrows}</div>${caption ? `<p class="lightbox-caption">${esc(caption)}</p>` : ''}<p class="lightbox-count">${photoIndex + 1} / ${photos.length}</p><div class="photo-detail-actions"><a class="button secondary small" href="/media/${p.id}?download=true" download>${icon('download')} 下载原文件</a>${button('回到这条时光','notice-detail','small soft','book',`data-id="${p.record_id}"`)}</div>`;
}
function renderPhotoModal(){
 const photos = state.photos || [];
 if (!photos.length) return;
 openModal('收藏的瞬间', `<div class="lightbox-body">${photoBodyHtml()}</div>`, {wide:true});
 preloadPhoto(photos[photoIndex - 1]?.id);
 preloadPhoto(photos[photoIndex + 1]?.id);
}
function updatePhotoModal(){
 const photos = state.photos || [];
 if (!photos.length) return;
 if (photoIndex < 0) photoIndex = 0;
 if (photoIndex >= photos.length) photoIndex = photos.length - 1;
 const body = $('.lightbox-body');
 if (!body) { renderPhotoModal(); return; }
 const p = photos[photoIndex];
 // 原地换图：保持 <img> 元素稳定，避免弹窗 collapse→expand 的闪烁
 const img = $('.lightbox-image', body);
 if (img) { img.src = `/media/${p.id}?preview=true`; img.alt = p.caption || '我们的照片'; }
 // 文案
 const caption = (p.caption || '').trim();
 let cap = $('.lightbox-caption', body);
 if (caption) {
  if (!cap) { cap = document.createElement('p'); cap.className = 'lightbox-caption'; $('.lightbox-wrap', body).after(cap); }
  cap.textContent = caption;
 } else if (cap) cap.remove();
 // 计数
 const cnt = $('.lightbox-count', body);
 if (cnt) cnt.textContent = `${photoIndex + 1} / ${photos.length}`;
 // 上/下一张箭头
 const wrap = $('.lightbox-wrap', body);
 if (wrap) {
  wrap.querySelectorAll('.photo-arrow').forEach(b => b.remove());
  if (photoIndex > 0) wrap.insertAdjacentHTML('beforeend', `<button type="button" class="photo-arrow left" data-action="photo-prev" aria-label="上一张">${icon('back')}</button>`);
  if (photoIndex < photos.length - 1) wrap.insertAdjacentHTML('beforeend', `<button type="button" class="photo-arrow right" data-action="photo-next" aria-label="下一张">${icon('arrow')}</button>`);
 }
 // 下载原文件 + 回到这条时光
 const dl = $('.photo-detail-actions a[download]', body);
 if (dl) dl.setAttribute('href', `/media/${p.id}?download=true`);
 const back = $('.photo-detail-actions [data-action="notice-detail"]', body);
 if (back) back.setAttribute('data-id', p.record_id || '');
 // 预加载相邻，保证连续切换零等待
 preloadPhoto(photos[photoIndex - 1]?.id);
 preloadPhoto(photos[photoIndex + 1]?.id);
}
function photoModal(mid){
 const idx = (state.photos || []).findIndex(p => p.id === mid);
 photoIndex = idx < 0 ? 0 : idx;
 renderPhotoModal();
}
function videoModal(id){
 const m = (state.records || []).flatMap(r => r.media || []).find(x => x.id === id);
 openModal(m?.name || '视频', `<video class="lightbox-video" controls autoplay playsinline src="/media/${id}?preview=true"></video>`, {wide:true});
}

function channelForm() {
 const configs={smtp:[['host','SMTP 主机','text'],['port','端口：465 或 587','number'],['username','登录用户名','text'],['password','邮箱授权码','password'],['from','发件邮箱','email'],['to','收件邮箱','email']],bark:[['key','设备 Key','password'],['url','服务地址（默认 https://api.day.app）','url']],serverchan:[['key','SendKey','password']],pushplus:[['token','Token','password']],wecom:[['url','企业微信机器人 Webhook 地址','url']],webhook:[['url','HTTPS Webhook 地址','url'],['token','Bearer Token（可选）','password']],telegram:[['token','Bot Token（数字:字母）','password'],['chat_id','Chat ID（群组为负数）','text']],dingtalk:[['token','access_token','password'],['secret','加签 secret（SEC 开头）','password']],feishu:[['token','Webhook token','password'],['secret','签名校验 secret','password']],ntfy:[['host','服务地址（如 https://ntfy.sh）','url'],['topic','Topic 名称','text']]};
 simpleForm('添加一个通知渠道',selectField('渠道类型','kind',Object.entries(channelNames),'smtp')+field('给渠道起个名字','name','','text','required')+'<div id="channel-config" class="modal-form"></div><label>接收哪些提醒</label><div class="form-row">'+Object.entries(eventNames).map(([id,label])=>`<label class="switch-row">${label}<input type="checkbox" name="event-${id}" checked></label>`).join('')+'</div><div class="form-row">'+field('免打扰开始（小时）','quiet_start',22,'number','min="0" max="23" required')+field('免打扰结束（小时）','quiet_end',8,'number','min="0" max="23" required')+'</div>'+field('最短发送间隔（秒）','interval',300,'number','min="0" max="86400" required')+'<p class="small-note">开始与结束相同表示全天接收。聊天消息会合并提醒。保存后可发送测试消息。</p>',async(data,form)=>{const config={};configs[data.kind].forEach(([id])=>{if(data['config-'+id])config[id]=data['config-'+id];});await post('/channels',{kind:data.kind,name:data.name,config,events:Object.keys(eventNames).filter(id=>data['event-'+id]),quiet_start:Number(data.quiet_start),quiet_end:Number(data.quiet_end),interval:Number(data.interval),enabled:true});});
 const update=()=>{const kind=$('[name=kind]',$('#simple-form')).value;$('#channel-config').innerHTML=configs[kind].map(([id,label,type])=>field(label,'config-'+id,id==='port'?'465':'',type,(kind==='bark'&&id==='url')||(kind==='webhook'&&id==='token')?'':'required')).join('');};$('[name=kind]',$('#simple-form')).onchange=update;update();
}

async function sendChat(body,clientId=uuid()) {
 const pending=pendingChats();if(!pending.some(p=>p.client_id===clientId)){pending.push({client_id:clientId,body});setPending(pending);}
 try {await post('/records',{kind:'chat',body,client_id:clientId});setPending(pendingChats().filter(p=>p.client_id!==clientId));}catch(e){if($('#chat-log')){$('#chat-log').innerHTML=chatRows();scrollChat();}throw e;}
}

async function act(action,id,el) {
 const r=state.records.find(x=>x.id===id);
 if(action==='reload')return boot();
 if(action==='load-more-timeline'){await loadTimeline(false);return renderPage();}
 if(action==='week-prev'||action==='week-next'){const next=(state.weekOffset||0)+(action==='week-prev'?-1:1);if(next>0)return;state.weekOffset=next;state.weekly=null;renderPage();await loadSpecial();return renderPage();}
 if(action==='week-copy'){const w=state.weekly;if(!w)return;const text=[`${w.label}的回忆周报（${w.start} 至 ${w.end}）`,w.message,`记录 ${w.total} 条 · 照片 ${w.photos} 张 · 有记录 ${w.days_active} 天`,`喜欢 ${w.likes} 次 · 留言与评论 ${w.comments} 条`].join('\n');try{await navigator.clipboard.writeText(text);toast('周报文字已复制');}catch{toast('复制失败，请手动选择文字');}return;}
 if(action==='toggle-dark'){const pref=localStorage.getItem(DARK_KEY)||'auto';const isDark=document.documentElement.classList.contains('dark');localStorage.setItem(DARK_KEY,isDark?'off':'on');applyDarkMode();const btn=el||$('#dark-toggle');if(btn)btn.innerHTML=icon(document.documentElement.classList.contains('dark')?'sun':'moon');return;}
 if(action==='close-modal')return closeModal();
 if(action==='record-audio')return;
 if(action==='compose')return composer();
 if(action==='upload-album')return composer('post',null,{album:state.album||''});
 if(action.startsWith('new-')){const kind=action.slice(4);return kind==='channel'?channelForm():kind==='personal-wish'?personalWishForm():recordForm(kind);}
 if(action==='unlock-personal-wish')return unlockPersonalWish(id);
 if(action.startsWith('tool-'))return navigate('together',action.slice(5));
 if(action==='tools-back')return navigate('together');
 if(action==='mood')return recordForm('mood');
 if(action==='mood-history')return navigate('together','mood');
 if(action==='personal-tab')return id==='settings'?navigate('settings'):navigate('personal',id);
 if(action==='album-filter'){state.album=id;return renderPage();}
 if(action==='edit-record')return recordForm(r.kind,r);
 if(action==='delete-record')return confirmAction('暂时收起这份回忆？',r.kind==='album'?'只删除相册分类，里面的照片仍会保留在全部照片中。':'记录会进入作者的回收站，三十天内可以恢复。',async()=>{await del('/records/'+id);if(state.album===id)state.album='';});
 if(action==='restore'){await post('/records/'+id+'/restore');await refresh();return toast('回忆已恢复');}
 if(action==='like'){await post('/records/'+id+'/like');return refresh();}
 if(action==='comment')return simpleForm('留一句温柔的回应','<label>你的回复<textarea name="content" required maxlength="5000"></textarea></label>',data=>post('/records/'+id+'/comments',data),'发送回复');
 if(action==='delete-comment')return confirmAction('删除这条回复？','删除后无法恢复。',()=>del('/comments/'+id));
 if(action==='answer'){const old=(r.answers||[]).find(a=>a.author===state.me.user.id);return simpleForm(r.body.title,`<label>我的答案<textarea name="content" required maxlength="5000">${esc(old?.content||'')}</textarea></label>`,data=>post('/records/'+id+'/answer',data));}
 if(action==='check'){await post('/records/'+id+'/check');await refresh();return toast('今天也一起向前了一小步');}
 if(action==='toggle-wish'){await put('/records/'+id,{kind:'wish',body:{...r.body,done:!r.body.done}});return refresh();}
 if(action==='wish-memory')return composer('post',null,{title:'一起实现：'+r.body.title,content:r.body.content||'',completion_post:r.id});
 if(action==='anniversary-memories'){state.filters={date:el.dataset.date};return navigate('timeline');}
 if(action==='photo')return photoModal(id);
 if(action==='video')return videoModal(id);
 if(action==='photo-prev'||action==='photo-next'){photoIndex += action==='photo-next' ? 1 : -1; return updatePhotoModal();}
 if(action==='space')return spaceForm();
 if(action==='profile')return profileForm();
 if(action==='invite')return inviteModal();
 if(action==='copy-invite'){const input=$('#invite-url');input.select();try{await navigator.clipboard.writeText(input.value);toast('邀请链接已复制');}catch{toast('请长按或按 Ctrl+C 复制链接');}return;}
 if(action==='logout'){const userId=state.me?.user.id;if(browserPushSupported()&&!isNativeApp()){try{await disableBrowserPush({silent:true});}catch{}}if(isNativeApp()){try{const push=nativePushBridge();if(push?.clearTopic)await push.clearTopic();nativePushTopic=null;}catch{}}await post('/logout');state.me=null;await clearPrivateSession(userId);closeModal();return boot();}
 if(action==='read-notices'){await post('/notices/read');return refresh();}
 if(action==='delete-read-notices'){const count=state.notices.filter(n=>n.event!=='chat'&&n.seen).length;if(!count)return toast('没有可删除的已读提醒');return confirmAction('删除已读提醒？',`将删除 ${count} 条已读提醒，不会影响未读提醒、动态或聊天记录。`,async()=>{const result=await api('/notices/read',{method:'DELETE'});toast(`已删除 ${result.deleted||0} 条已读提醒`);});}
 if(action==='check-update'){try{const s=await api('/status');state.appVersion={version:s.version,build:s.build};renderShell();
  if(window.Capacitor&&Capacitor.isNativePlatform&&Capacitor.isNativePlatform()){
   /* APK：对比原生版本与服务器托管的 apk_version，新版本直接下载安装 */
   try{let nv='unknown';try{const version=await nativePushBridge()?.version?.();if(typeof version?.version==='string'&&/^\d+(?:\.\d+){1,2}$/.test(version.version))nv=version.version;}catch{}
    state.apkVersion=nv;
    if(s.apk_version&&s.apk_url&&(nv==='unknown'||newerVer(s.apk_version,nv))){const installed=nv==='unknown'?'当前版本暂不可读取':`当前 v${nv}`;openModal('发现新版本',`<div style="text-align:center;padding:10px 0"><div style="font-size:48px;margin-bottom:12px">⬇️</div><p>新版本 <strong>v${s.apk_version}</strong> 已发布（${installed}）</p><p class="meta">下载完成后点击通知安装；如果 App 内下载没有反应，请复制下载地址后用手机浏览器打开。</p><div class="form-actions"><button class="button" data-action="close-modal">稍后再说</button><button class="button primary" id="apk-dl">下载新版本</button></div></div>`);setTimeout(()=>{const b=$('#apk-dl');if(b)b.onclick=()=>{closeModal();toast('正在打开 APK 下载地址');location.href=new URL(s.apk_url,location.origin).href;};},50);}
    else if(nv==='unknown')toast('无法读取当前 APK 版本，请从手机浏览器重新安装最新版 v'+s.apk_version);
    else toast('已是最新版本 v'+nv+'（网页 v'+s.version+'）');
   }catch{toast('检查更新失败，请稍后再试');}
  } else toast(s.version===state.localVersion?'已是最新版本 v'+s.version:'发现新版本 v'+s.version+'，请刷新页面更新');
 }catch{toast('检查更新失败，请稍后再试');}return;}
 if(action==='notice-detail'){closeModal();const detail=await api('/records/'+id);const unread=state.notices.filter(n=>n.record_id===id&&!n.seen);if(unread.length){try{await post('/notices/read?record_id='+encodeURIComponent(id));await refresh();}catch{}}if(detail.kind==='chat')return navigate('messages');openModal('这一刻的故事',recordCard(detail),{wide:true});return;}
 if(action==='chat-attachment')return composer('chat');
 if(action==='chat-to-draft')return composer('post',null,{...r.body,mediaObjects:r.media});
 if(action==='retry-chat'){const p=pendingChats().find(p=>p.client_id===id);if(p){await sendChat(p.body,p.client_id);await refresh();}return;}
 if(action==='recall-chat')return confirmAction('撤回这条悄悄话？','撤回后双方都不会再看到这条消息。',async()=>{await post('/records/'+id+'/recall');await refresh();return toast('已撤回');});
 if(action==='sticker-panel')return stickerPanel();
 if(action==='sticker-tab'){state.stickerTab=id;return renderStickerTabs();}
 if(action==='sticker-emoji')return insertStickerText(id);
 if(action==='sticker-del'){setStickers(myStickers().filter(s=>s.mid!==id));return renderStickerTabs();}
 if(action==='sticker-send'){const dock=$('#sticker-dock');if(dock)dock.hidden=true;await sendChat({content:'',media:[id]});await refresh();scrollChat();return;}
 if(action==='sticker-pack-send'){const dock=$('#sticker-dock');if(dock)dock.hidden=true;await sendChat({content:'',sticker:id});await refresh();scrollChat();return;}
 if(action==='chat-back'){const ret=state.chatReturn||{page:'home',tab:''};return navigate(ret.page,ret.tab||'');}
 if(action==='test-channel'){await post('/channels/'+id+'/test');toast('测试已加入发送队列，请稍后刷新日志');return;}
 if(action==='delete-channel')return confirmAction('移除这个通知渠道？','该渠道的配置和发送日志会一并移除。',()=>del('/channels/'+id));
 if(action==='retry-delivery'){await post('/deliveries/'+id+'/retry');return refresh();}
 if(action==='enable-webpush')return enableBrowserPush();
 if(action==='disable-webpush')return disableBrowserPush();
 if(action==='test-webpush'){await post('/webpush/test');toast('测试提醒已加入发送队列，请稍等片刻');return;}
 if(action.startsWith('native-push-')){
  if(!isNativeApp())return toast('此项仅适用于安卓 App');
  const PB=nativePushBridge();
  if(!PB)return toast('安卓原生提醒组件未就绪，请重新打开 App');
  try{
   if(action==='native-push-battery'){await PB.openBatterySettings();return;}
   if(action==='native-push-notif-settings'){await PB.openNotificationSettings();return;}
   if(action==='native-push-test'){await initNotify();await PB.testNotification();return toast('测试提醒已发出，请查看系统通知栏');}
   if(action==='native-push-network-test'){await post('/native-push/test');return toast('测试提醒已加入后台队列，请将 App 切到后台验证系统通知');}
   if(action==='native-push-browser'){await PB.openWebPushBrowser({url:location.origin+'/#channels'});return;}
   if(action==='native-push-restart'){
    if(state.me?.ntfy_topic)await PB.setTopic({topic:state.me.ntfy_topic,server:state.me.ntfy_server});
    await PB.restart();state.nativePush=await PB.status();renderPage();return toast('后台提醒已重连');
   }
   if(action==='native-push-refresh'){await syncNativePush();state.nativePush=await PB.status();renderPage();return;}
  }catch(e){return toast(e.message||'操作失败，请稍后重试');}
 }
 if(action==='backup'){el.disabled=true;try{await post('/backups');await refresh();toast('完整备份已生成');}finally{el.disabled=false;}return;}
 if(action==='refresh')return refresh();
 if(action==='expand-yearbook'||action==='collapse-yearbook'){
  const box=$('#yearbook');if(!box)return;
  if(!state.yearbookData){try{state.yearbookData=await api('/yearbook');}catch(e){return toast(e.message);}}
  const data=state.yearbookData,open=action==='expand-yearbook';
  box.innerHTML=`<h2>📖 ${data.is_current?'今年':' '+data.year+' 年'}的我们</h2>${open?yearbookBody(data)+`<div class="yearbook-toggle-row">${button('收起年报','collapse-yearbook','secondary small','arrow')}</div>`:`<div class="yearbook-summary"><p>${data.total} 条记录 · ${data.photos} 张照片 · ${data.moods} 次心情</p><span class="yearbook-toggle-row">${button('展开小年报','expand-yearbook','soft small','arrow')}</span></div>`}`;
  return;
 }
 if(action==='clear-filters'){state.filters={};state.timelineCursor=null;await loadTimeline(true);return renderPage();}
 if(action==='otd-detail'){const detail=await api('/records/'+id);if(detail.kind==='chat')return navigate('messages');openModal('这一刻的故事',recordCard(detail),{wide:true});return;}
 if(action==='cal-day'){
  state.calSelected=state.calSelected===id?'':id;
  $$('.cal-day',$('#page')).forEach(b=>b.classList.toggle('selected',b.dataset.id===state.calSelected));
  const detail=$('#cal-detail');if(detail)detail.innerHTML=calDetailHTML();
  return;}
 if(action==='cal-prev'||action==='cal-next'){if(!state.calMonth){const d=new Date();state.calMonth=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');}const [y,m]=state.calMonth.split('-').map(Number);const d=new Date(y,m-1+(action==='cal-next'?1:-1),1);state.calMonth=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');state.calSelected='';return loadCalendar(true);}
 if(action==='import-to-draft')return composer('post',null,{content:el.dataset.content,date:el.dataset.day||today()});
 if(action==='import-chat')return importChatModal();
 if(action==='open-import'){state.importId=id;return navigate('importdetail');}
 if(action==='imports-back')return navigate('imports');
 if(action==='delete-import')return confirmAction('删除这份聊天记录？','这是我们两人共用的记录，删除后双方都看不到，无法恢复。',async()=>{await del('/imports/'+id);state.importId='';navigate('imports');return toast('已删除这份聊天记录');});
}

document.addEventListener('click',async e=>{$$('.more-menu[open]').forEach(d=>{if(!d.contains(e.target))d.removeAttribute('open');});const nav=e.target.closest('[data-nav]'),el=e.target.closest('[data-action]');try{if(nav||el)e.target.closest('.account-menu')?.removeAttribute('open');if(nav)return await navigate(nav.dataset.nav);if(el)await act(el.dataset.action,el.dataset.id||'',el);}catch(err){toast(err.message);}});
document.addEventListener('submit',async e=>{if(e.target.id!=='chat-form')return;e.preventDefault();const input=$('#chat-text'),content=input.value.trim();if(!content)return;const btn=$('button[type=submit]',e.target);btn.disabled=true;try{await sendChat({content,date:today(),media:[]});input.value='';autoGrow(input);localStorage.removeItem('chat-text:'+state.me.user.id);await refresh();}catch(err){toast(err.message);}finally{btn.disabled=false;}});
document.addEventListener('input',e=>{if(e.target.id==='chat-text'){localStorage.setItem('chat-text:'+state.me.user.id,e.target.value);autoGrow(e.target);}if(e.target.id==='filter-q'){state.filters={...(state.filters||{}),q:e.target.value};clearTimeout(state.filterTimer);state.filterTimer=setTimeout(async()=>{const pos=$('#filter-q')?.selectionStart;try{await loadTimeline(true);renderPage();$('#filter-q')?.focus();$('#filter-q')?.setSelectionRange(pos,pos);}catch(err){toast(err.message);}},250);}});
document.addEventListener('change',e=>{const map={'filter-author':'author','filter-date':'date','filter-media':'media'};if(map[e.target.id]){state.filters={...(state.filters||{}),[map[e.target.id]]:e.target.value};state.timelineCursor=null;loadTimeline(true).then(renderPage).catch(err=>toast(err.message));}});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){const menu=$('.more-menu[open]');if(menu){menu.removeAttribute('open');$('summary',menu)?.focus();}}if(e.key==='Escape'&&$('.modal'))closeModal();if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing&&e.target?.id==='chat-text'){e.preventDefault();const form=$('#chat-form'),btn=form&&$('button[type=submit]',form);if(form&&btn&&!btn.disabled)form.requestSubmit();}if(e.key==='Tab'&&$('.modal')){const els=$$('button,input,textarea,select,a[href]',$('.modal')).filter(el=>!el.disabled),first=els[0],last=els.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}});
// —— Android APK 系统通知桥（浏览器/PWA 无 Capacitor 时自动跳过，零影响）——
function isNativeApp(){return Boolean(window.Capacitor&&Capacitor.isNativePlatform&&Capacitor.isNativePlatform());}
function nativePushBridge(){return window.Capacitor?.Plugins?.PushBridge||null;}
function browserPushSupported(){return 'serviceWorker' in navigator&&'PushManager' in window&&'Notification' in window;}
function fromBase64Url(value){const padded=value.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-value.length%4)%4);return Uint8Array.from(atob(padded),c=>c.charCodeAt(0));}
async function enableBrowserPush(){
 if(!browserPushSupported())throw new Error('当前浏览器不支持系统通知');
 const ios=/iphone|ipad|ipod/i.test(navigator.userAgent),standalone=navigator.standalone||matchMedia('(display-mode: standalone)').matches;
 if(ios&&!standalone)throw new Error('请先将恋爱空间添加到 iPhone/iPad 主屏幕，再从主屏幕打开并开启通知');
 const permission=await Notification.requestPermission();if(permission!=='granted')throw new Error('通知权限未开启，请在浏览器或系统设置中允许通知');
 const config=await api('/webpush'),registration=await navigator.serviceWorker.ready;
 let subscription=await registration.pushManager.getSubscription();
 if(!subscription)subscription=await registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:fromBase64Url(config.public_key)});
 const result=await put('/webpush/subscription',subscription.toJSON());
 state.webpush={...config,devices:result.devices,local:true};renderPage();toast('本设备的系统通知已开启');
}
async function disableBrowserPush({silent=false}={}){
 const registration=await navigator.serviceWorker.ready,subscription=await registration.pushManager.getSubscription();
 if(subscription){await post('/webpush/unsubscribe',{endpoint:subscription.endpoint});await subscription.unsubscribe();}
 if(state.webpush){state.webpush.local=false;state.webpush.devices=Math.max(0,(state.webpush.devices||0)-(subscription?1:0));renderPage();}
 if(!silent)toast('已关闭本设备通知');
}
const _LN=(window.Capacitor&&window.Capacitor.Plugins)?window.Capacitor.Plugins.LocalNotifications:null;let _notifySeq=Date.now()%100000;
const NOTIFY_CHANNEL={id:'love-v2',name:'恋爱空间',description:'新消息与提醒',importance:'HIGH',visibility:'PUBLIC'};
/* 启动即建高优先级渠道并请求通知权限：Android 13+ 需运行时授权；渠道 importance 创建后不可改，故换新 id love-v2 确保横幅+锁屏生效 */
async function initNotify(){if(!_LN)return;try{await _LN.createChannel(NOTIFY_CHANNEL);const p=await _LN.checkPermissions();if(p.display!=='granted')await _LN.requestPermissions();}catch{}}
async function nativeNotify(title,body){if(!_LN)return;try{const perm=await _LN.checkPermissions();if(perm.display!=='granted'){const req=await _LN.requestPermissions();if(req.display!=='granted')return;}await _LN.createChannel(NOTIFY_CHANNEL);_notifySeq+=1;await _LN.schedule({notifications:[{id:_notifySeq,title:String(title||'恋爱空间').slice(0,60),body:String(body||'').slice(0,120),channelId:'love-v2'}]});}catch{}}
/* 首次打开权限引导：仅在 Capacitor APK 中弹一次（localStorage 标记），通知和后台权限由用户主动选择 */
function requestFirstLaunchPermissions(){if(!window.Capacitor||!window.Capacitor.Plugins)return;const done=localStorage.getItem('perm_guide_done');if(done)return;openModal('开启通知提醒',`<div style="text-align:center;padding:10px 0"><div style="font-size:48px;margin-bottom:12px">🔔</div><p>为了不错过对方的消息，请允许以下权限：</p><div class="setting-list" style="text-align:left;margin:16px 0"><button data-action="perm-notify">${icon('bell')} 通知权限<span class="meta">接收消息提醒</span></button><button data-action="perm-battery">${icon('gear')} 后台运行权限<span class="meta">允许 App 在后台保持提醒</span></button></div><div class="form-actions">${button('稍后再说','close-modal')}<button class="button primary" id="perm-done">我知道了</button></div></div>`);
 $('#perm-done').onclick=()=>{localStorage.setItem('perm_guide_done','1');closeModal();};
 /* 权限由用户主动选择；电池设置页在返回后可于提醒设置中查看状态 */
 setTimeout(()=>{const nb=$('[data-action="perm-notify"]');if(nb)nb.onclick=async e=>{e.preventDefault();await initNotify();toast('请确认系统通知权限');};const bb=$('[data-action="perm-battery"]');if(bb)bb.onclick=async e=>{e.preventDefault();try{await nativePushBridge()?.openBatterySettings?.();}catch{toast('请在系统设置中为恋爱空间开启后台运行');}};},100);}
/* 内置 ntfy 备份通道：服务端发消息时同时 POST 到 ntfy.sh，WebView 里 WebSocket 监听。
   作为 SSE 的第二条独立通道——两条同时断的概率远低于一条。用户零配置（topic 服务端自动生成）。 */
/* 把 ntfy topic 交给原生层：APK 后台时 WebView 可能被冻结，由原生长连接接收并弹系统通知 */
let nativePushSync=null,nativePushTopic=null;
/* topic 由服务端下发；服务端停用内置 ntfy 后会变成 null —— 此时调 clearTopic 停掉原生前台服务并清掉常驻通知 */
function syncNativePush(){
 if(state.me&&!state.me.ntfy_topic&&nativePushTopic){try{nativePushBridge()?.clearTopic?.();}catch{}nativePushTopic=null;}
 if(!window.Capacitor||!Capacitor.isNativePlatform||!Capacitor.isNativePlatform()||!state.me)return;
 if(nativePushSync)return nativePushSync;
 const PB=nativePushBridge(),topic=state.me.ntfy_topic;
 if(!PB){state.nativePush={available:false,error:'未找到安卓原生提醒插件'};return null;}
 nativePushSync=(async()=>{
  try{
   if(topic!==nativePushTopic){if(topic)await PB.setTopic({topic,server:state.me.ntfy_server});else await PB.clearTopic();nativePushTopic=topic;}
   state.nativePush=await PB.status();
   if(state.page==='channels')renderPage();
  }catch(e){state.nativePush={available:false,error:e.message||'无法连接原生提醒服务'};}
 })().finally(()=>{nativePushSync=null;});
 return nativePushSync;
}
/* 原生流健康判断：服务在跑且流已连上时，后台消息交给原生系统通知，避免与 WebView 弹窗重复 */
function nativeStreamHealthy(){const np=state.nativePush;return Boolean(np&&np.service_running&&np.stream_connected);}
/* 后台保活 + 自愈看门狗（仅 APK）：
   ① BackgroundMode 让 WebView 的 SSE/ntfy WS 退到后台后继续运行，新消息到达即由 handleServerEvent 弹系统通知；
   ② 每 60s 检查一次连接：SSE/WS 死了立即重建；syncNativePush 会经 PushBridge.setTopic 检测原生服务——
      服务被系统杀死（serviceActive=false）时 setTopic 会自动把它重启拉起，覆盖「通知链容易断、只有重开 App 才恢复」的根因场景。 */
let keepAliveTimer=null;
function startKeepAlive(){
 if(!window.Capacitor||!Capacitor.isNativePlatform||!Capacitor.isNativePlatform||!state.me)return;
 if(keepAliveTimer)return;
 try{
  const bg=Capacitor.Plugins?.BackgroundMode;
  if(bg?.enable){
   const p=bg.enable({title:'恋爱空间',text:'正在守护你们的小空间，保持消息及时送达'});
   if(p&&typeof p.catch==='function')p.catch(()=>{});
  }
 }catch{}
 keepAliveTimer=setInterval(()=>{
  if(!state.me)return;
  if(!state.stream||state.stream.readyState===EventSource.CLOSED)connectEvents();
  if(!ntfyWs||ntfyWs.readyState!==WebSocket.OPEN)connectNtfy();
  syncNativePush();
 },60000);
}
/* 语义化版本比较：a > b 返回 true（如 1.2.0 > 1.1.9） */
function newerVer(a,b){const x=a.split('.').map(Number),y=b.split('.').map(Number);for(let i=0;i<Math.max(x.length,y.length);i++){const d=(x[i]||0)-(y[i]||0);if(d>0)return true;if(d<0)return false;}return false;}
let ntfyWs=null,ntfyRetry=0;
function connectNtfy(){const topic=state.me?.ntfy_topic;
 /* 服务端已停用内置 ntfy（NTFY_ENABLED=0）时不再下发 topic：关掉残留连接，避免空转的 wss */
 if(!topic){clearTimeout(state.ntfyTimer);try{ntfyWs?.close();}catch{}ntfyWs=null;return;}
 /* 关键：握手途中的连接不能重复建也不能关。旧写法无条件 close()，60s 巡检又会在 CONNECTING 状态下
    再建一次，于是控制台反复刷 "WebSocket is closed before the connection is established"。 */
 if(ntfyWs&&(ntfyWs.readyState===WebSocket.CONNECTING||ntfyWs.readyState===WebSocket.OPEN))return;
 clearTimeout(state.ntfyTimer);
 try{if(ntfyWs&&(ntfyWs.readyState===WebSocket.OPEN||ntfyWs.readyState===WebSocket.CLOSING))ntfyWs.close();}catch{}
 ntfyWs=null;try{const endpoint=new URL(state.me.ntfy_server||'https://ntfy.350921.xyz');if(endpoint.protocol!=='https:')return;endpoint.protocol='wss:';endpoint.pathname=endpoint.pathname.replace(/\/+$/,'')+'/'+encodeURIComponent(topic)+'/ws';endpoint.search='';endpoint.hash='';const ws=new WebSocket(endpoint);ntfyWs=ws;ws.onopen=()=>{ntfyRetry=0;};ws.onmessage=()=>scheduleServerEvent('');ws.onerror=()=>{};ws.onclose=()=>{if(ntfyWs!==ws||!state.me)return;ntfyWs=null;clearTimeout(state.ntfyTimer);ntfyRetry=ntfyRetry?Math.min(ntfyRetry*2,60):2;state.ntfyTimer=setTimeout(()=>{if(state.me)connectNtfy();},ntfyRetry*1000);};}catch{}}
/* 服务端事件合并：SSE 每 5s 一条心跳、ntfy 与 SSE 又是两条独立通道，
   点赞+评论+通知常常在同一瞬间到达。不做合并会把一轮变化放大成三四次
   「拉 4 个全量接口 + 整页 innerHTML 替换」，滚动位置和视频贴纸全被冲掉。 */
let lastRev=null,eventTimer=null,pendingRev='';
function scheduleServerEvent(rev){
 pendingRev=(typeof rev==='string')?rev:'';  // ntfy 那条通道不带 revision，留空即强制刷新
 clearTimeout(eventTimer);
 eventTimer=setTimeout(async()=>{
  const rev=pendingRev;pendingRev='';
  if(rev&&rev===lastRev)return;  // 数据没变，这一轮可以直接跳过
  try{await handleServerEvent();if(rev)lastRev=rev;}catch{}
 },500);
}
async function handleServerEvent(){if(!state.me)return;if(refreshing){state.pendingRefresh=true;return;}try{const oldNotice=state.notices[0]?.id||null;const focused=document.activeElement,canRender=!$('.modal')&&!$('.more-menu[open]')&&!['INPUT','TEXTAREA','SELECT'].includes(focused?.tagName);await refresh(false);if(state.page==='messages'&&$('#chat-log')){const log=$('#chat-log'),atBottom=log.scrollHeight-log.scrollTop-log.clientHeight<100;log.innerHTML=chatRows();if(atBottom)scrollChat();state.me.chat_unread=0;post('/notices/read?event=chat').catch(()=>{});}else if(canRender)renderShell();/* 系统弹窗/锁屏通知已停用：手机端通知改由第三方渠道（企业微信等）+ 浏览器 Web Push 送达；在聊天页停留时消息即时标记已读，后端不再推送 */}catch{};}
let sseRetry=0;
function connectEvents(){clearTimeout(state.sseTimer);state.stream?.close();const es=new EventSource('/api/events');state.stream=es;es.onopen=()=>{sseRetry=0;};es.onmessage=e=>{let rev='';try{rev=(JSON.parse(e.data||'{}').rev)||'';}catch{}scheduleServerEvent(rev);};/* 断线兜底：浏览器只自动重连“可恢复”断线（readyState=CONNECTING）；致命断流（401/代理掐断）进 CLOSED 后永不自愈 → 指数退避手动重建，1s 起步、30s 封顶，连上即清零 */
es.onerror=()=>{if(es.readyState!==EventSource.CLOSED)return;state.stream=null;clearTimeout(state.sseTimer);sseRetry=sseRetry?Math.min(sseRetry*2,30):1;state.sseTimer=setTimeout(()=>{if(state.me)connectEvents();},sseRetry*1000);};}
/* 回前台：SSE 可能已被系统挂死（尤其安卓 WebView 后台冻结）→ 死流重建 + 立即补刷一轮，兜住后台错过的消息 */
document.addEventListener('visibilitychange',()=>{if(document.hidden||!state.me)return;syncNativePush();if(!state.stream||state.stream.readyState===EventSource.CLOSED)connectEvents();if(!ntfyWs||ntfyWs.readyState!==WebSocket.OPEN)connectNtfy();handleServerEvent();});
window.addEventListener('focus',()=>{if(document.hidden||!state.me)return;if(!state.stream||state.stream.readyState===EventSource.CLOSED){connectEvents();handleServerEvent();}});
window.addEventListener('online',async()=>{state.online=true;try{await refresh();connectEvents();syncNativePush();}catch{}});
window.addEventListener('offline',()=>{state.online=false;toast('网络断开，未发送内容会保留');});
window.addEventListener('hashchange',()=>{const page=location.hash.slice(1);if(page&&page!==state.page)navigate(page);});
boot();

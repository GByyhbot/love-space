'use strict';

// SW 脚本地址带上本文件自己的 ?v=：Cloudflare 会把无参数的 /static/sw.js 缓存 4 小时，
// 不带版本时浏览器拿到的还是旧 worker，修复要等缓存过期才落地（2026-11-01 踩过——
// 旧 worker 把子页面导航写进了 '/' 缓存键，主站弱网回退时整页变成了图库）。
const SW_SRC = (document.currentScript && document.currentScript.src) || '';
const SW_VER = (SW_SRC.match(/[?&]v=(\d+)/) || [])[1] || '';

if ('serviceWorker' in navigator) {
 window.addEventListener('load', () => navigator.serviceWorker.register('/static/sw.js' + (SW_VER ? `?v=${SW_VER}` : ''),{scope:'/'}).then(async rootReg=>{
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
 play:'m8 5 12 7-12 7V5Z', pause:'M8 5h3v14H8V5Zm5 0h3v14h-3V5Z', music:'M9 18V6l10-2v12M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm10-2a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z', image:'M4 4h16v16H4V4Zm2 12 4-4 3 3 2-2 3 3',
 chat:'M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.4 8.4 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5Z',
 search:'M21 21l-4.35-4.35M10 18a8 8 0 1 1 0-16 8 8 0 0 1 0 16Z',
 grid:'M4 4h6v6H4V4Zm10 0h6v6h-6V4ZM4 14h6v6H4v-6Zm10 0h6v6h-6v-6Z',
 smile:'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM9 10h.01M15 10h.01M8.5 15a4.6 4.6 0 0 0 7 0',
 camera:'M3 7h4l2-3h6l2 3h4v13H3V7Zm9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z',
 phone:'M6 3h3l2 5-2 2a12 12 0 0 0 5 5l2-2 5 2v3a2 2 0 0 1-2 2A17 17 0 0 1 4 5a2 2 0 0 1 2-2Z',
 location:'M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Zm0-8a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z',
 gift:'M4 4h16v16H4V4Zm0 0 8 7 8-7M12 11v9',
 transfer:'M4 8h13l-3-3M20 16H7l3 3',
 film:'M3 5h18v14H3V5Zm7 3.2v7.6L16 12l-6-3.8Z',
 game:'M7 9h10a4 4 0 0 1 4 4v2a3 3 0 0 1-5 2l-1-1H9l-1 1a3 3 0 0 1-5-2v-2a4 4 0 0 1 4-4Zm0 3v3M5.5 12.5h3M16 12h.01M18 14h.01'
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name] || paths.heart}"/></svg>`;
const state = {page:'home', tab:'', me:null, records:[], photos:[], notices:[], channels:[], deliveries:[], webpush:null, nativePush:null, dashboard:null, weekly:null, weekOffset:0, periodDay:'', timelinePosts:[],timelineCursor:null,timelineHasMore:false,stream:null, online:navigator.onLine, linkRoutes:null, linkProbing:false};
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
const kindLabel = {post:'时光动态',diary:'私密日记',draft:'草稿',surprise:'定时惊喜',anniversary:'纪念日',wish:'共同愿望',personal_wish:'个人心愿',mood:'每日心情',note:'留言板',question:'情侣问答',habit:'共同打卡',chat:'聊天',album:'相册',quest:'恋爱清单',ledger:'共同账本',period:'生理期',music:'共同歌单'};
/* 心情的六种表情：首页快捷记录和心情手记的完整表单共用同一份，选项别分叉 */
const MOOD_OPTIONS=[['☀️','☀️ 开心'],['🥰','🥰 想你'],['😌','😌 平静'],['✨','✨ 小确幸'],['☁️','☁️ 有点低落'],['🌧️','🌧️ 想要抱抱'],['🌱','🌱 充满期待'],['🌊','🌊 疲惫'],['😵','😵 压力大'],['🥱','🥱 无聊']];
const recordsOf = kind => state.records.filter(r=>r.kind===kind);
const uuid = () => crypto.randomUUID ? crypto.randomUUID() : ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g,c=>(c^crypto.getRandomValues(new Uint8Array(1))[0]&15>>c/4).toString(16));

const DARK_KEY = 'love-dark-mode';
const FONT_KEY = 'love-font-scale';
/* 七套内置主题：`THEME_IDS` 是唯一白名单。renderShell 加 class、themeForm 出色卡、
   themeMeta 查名字都走这一份——别再在页面里散落写死 theme-rose/peach/lavender，
   以前就是那么漏的（新增主题时总有一处忘改，界面停在旧配色）。 */
const THEME_IDS = ['rose','peach','lemon','mint','sky','lavender','cocoa'];
const THEME_META = {
 rose:{name:'草莓牛奶',desc:'莓果粉，最经典的那一版',light:['#953753','#F7EBEF','#FAF8F9'],dark:['#DA8BA3','#4F2E38','#231B1D']},
 peach:{name:'蜜桃奶油',desc:'暖橘调，傍晚的光',light:['#975935','#F7EFEB','#FAF9F8'],dark:['#DCA789','#4F3A2E','#231E1B']},
 lemon:{name:'柠檬挞',desc:'一点酸甜的黄油色',light:['#936E2F','#F8F3EA','#FAF9F8'],dark:['#DFBE86','#4F432E','#23201B']},
 mint:{name:'薄荷气泡',desc:'清透的青绿',light:['#3A826D','#ECF6F3','#F8FAF9'],dark:['#91D4C0','#2E4F45','#1B2320']},
 sky:{name:'海盐汽水',desc:'安稳的雾蓝',light:['#396993','#EBF1F7','#F8F9FA'],dark:['#8CB5D9','#2E404F','#1B1F23']},
 lavender:{name:'香芋云朵',desc:'软软的薰衣草',light:['#644389','#F1ECF6','#F9F8FA'],dark:['#B094D1','#3D2E4F','#1E1B23']},
 cocoa:{name:'焦糖可可',desc:'低饱和的暖棕，安静耐看',light:['#7C5D50','#F4F0EE','#F9F9F8'],dark:['#C8AA9D','#4F382E','#231D1B']}
};
const CUSTOM_FALLBACK = '#9A6B5A';
/* 主题色卡上的三个色块：主色 / 柔和底 / 页面底。夜间取另一组——
   否则夜里打开选择器会看到七块惨白，跟实际效果完全对不上。 */
function themeMeta(id, customColor) {
 const dark = document.documentElement.classList.contains('dark');
 if (THEME_META[id]) {const m=THEME_META[id];return {id, name:m.name, desc:m.desc, swatch:dark?m.dark:m.light};}
 const c = /^#[0-9a-fA-F]{6}$/.test(customColor||'') ? customColor : CUSTOM_FALLBACK;
 return {id:'custom', name:'自定义', desc:'从你喜欢的颜色生成',
  swatch:[c, shade(c, dark?-0.72:0.9), dark?shade(c,-0.94):shade(c,0.96)]};
}
/* 字号：只改 html[data-fs]，CSS 那边换 --fs-scale 一个乘数，12 级刻度自动等比放大 */
function applyFontScale() {
 const pref = localStorage.getItem(FONT_KEY) || 'std';
 const root = document.documentElement;
 if (pref === 'large' || pref === 'xl') root.dataset.fs = pref; else delete root.dataset.fs;
}
/* 手机浏览器的地址栏 / APK 状态栏颜色跟着主题走，别再写死一粉一黑 */
function themeBgColor() {
 const bg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim();
 return /^#[0-9a-fA-F]{6}$/.test(bg) ? bg : (document.documentElement.classList.contains('dark') ? '#211a1e' : '#f8e9ef');
}
function syncMetaThemeColor() {
 document.querySelector('meta[name="theme-color"]')?.setAttribute('content', themeBgColor());
}
// —— Android APK 状态栏适配：颜色跟随明暗主题（浏览器/PWA 无 Capacitor 时跳过）——
const _SB=(window.Capacitor&&window.Capacitor.Plugins)?window.Capacitor.Plugins.StatusBar:null;
async function syncStatusBar(){if(!_SB)return;try{const dark=document.documentElement.classList.contains('dark');await _SB.setOverlaysWebView({overlay:false});await _SB.setStyle({style:dark?'Dark':'Light'});await _SB.setBackgroundColor({color:themeBgColor()});}catch{}}
/* APK 上让聊天页延伸到状态栏底下：其它页面内容不该被状态栏压住，所以只在
   「聊天页 + 照片壁纸」时才开 overlay，离开立刻恢复。浏览器/PWA 无此插件，自动跳过。 */
let _sbOverlay = false;
async function syncStatusBarOverlay(){
 if(!_SB)return;
 const want = state.page === 'messages' && chatBgIsPhoto();
 if(want === _sbOverlay)return;
 _sbOverlay = want;
 try{
  if(!want){await syncStatusBar();return;}
  await _SB.setOverlaysWebView({overlay:true});
  await _SB.setBackgroundColor({color:'#00000000'});
  await _SB.setStyle({style:'Dark'});
 }catch{}
}
function applyDarkMode() {
  const pref = localStorage.getItem(DARK_KEY) || 'auto';
  const dark = pref === 'on' || (pref === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.toggle('dark', dark);
  refreshCustomColor();
  syncMetaThemeColor();
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
/* 十六进制 → "r,g,b"，写进 --primary-rgb 供 rgba(var(--primary-rgb), a) 用 */
const hexToRgb = hex => {const n=parseInt(hex.slice(1),16);return `${n>>16},${(n>>8)&255},${n&255}`;};
let currentCustom = null;
function refreshCustomColor(){ if(currentCustom) applyCustomColor(currentCustom.theme, currentCustom.color); }
function applyCustomColor(theme, color) {
  const root = document.documentElement;
  ['--primary', '--primary-dark', '--primary-rgb', '--soft', '--soft-strong', '--on-primary'].forEach(v => root.style.removeProperty(v));
  currentCustom = theme === 'custom' && /^#[0-9a-fA-F]{6}$/.test(color) ? {theme, color} : null;
  if (!currentCustom) return;
  const dark = root.classList.contains('dark');
  let primary = color;
  // 极浅或极深的自定义色派生出可读的按钮色，保证白字对比度
  const lum = luminance(color);
  if (lum > 0.82) primary = shade(color, -0.4);
  else if (lum < 0.14) primary = shade(color, 0.42);
  root.style.setProperty('--primary', primary);
  root.style.setProperty('--primary-rgb', hexToRgb(primary));
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
/* 弹窗表单的通用收尾件：错误提示行 + 「取消 / 主按钮」一行。
   十几个弹窗（日记、经期、音乐、心愿、主题、搜片源…）都是同一个骨架，
   收敛成组件后调样式或改文案只需动这一处，不会再各写各的。 */
const formError = () => '<div class="form-error" role="alert"></div>';
const modalActions = (label='保存') => `<div class="form-actions">${button('取消','close-modal')}<button class="button primary" type="submit">${label}</button></div>`;
const empty = (title,description,action='',label='留下第一份回忆',compact=false) => `<div class="empty ${compact?'compact':''}"><div class="empty-icon">♡</div><h3>${esc(title)}</h3><p>${esc(description)}</p>${action?button(label,action,'soft','plus'):''}</div>`;
function heading(title,description,action='',label='写点什么',ico='plus',extra='') {return `<div class="page-heading"><div><h1>${esc(title)}</h1><p>${esc(description)}</p></div>${action?button(label,action,'primary',ico,extra):''}</div>`;}

async function boot() {
 try {
  applyDarkMode();
  const status = await api('/status');
  state.localVersion=status.version||'1.1.0';state.localBuild=status.build||'';state.appVersion={version:status.version||'1.1.0',build:status.build||''};state.apkLatest=String(status.apk_version||'').trim();state.apkUrl=status.apk_url||'';state.apkMirror=status.apk_mirror||'';state.apkUrlDirect=status.apk_url_direct||'';state.apkNotes=status.apk_notes||'';
  /* 原生 APK 版本（供关于页展示 + 应用内更新对比） */
  if(isNativeApp()){const nv=await detectAppVersion();if(nv!=='unknown')state.apkVersion=nv;}
  const invite = new URLSearchParams(location.search).get('invite');
  try {state.me = await api('/me');} catch {state.me=null;}
  if (!state.me) return renderAuth(status,invite);
  history.replaceState(null,'',location.pathname+location.hash);
  state.page=location.hash.slice(1).split('/')[0] || 'home';
  if (!['home','timeline','albums','messages','together','personal','settings','notices','channels','backups','imports','importdetail','dashboard','weekly','figure','linkcheck','watch'].includes(state.page)) state.page='home';
  await refreshData(); if(state.page==='timeline')await loadTimeline(true); renderShell(); connectEvents(); connectNtfy(); syncNativePush(); startKeepAlive();
 } catch(e) {$('#app').innerHTML=empty('暂时无法连接空间',e.message,'reload','重新连接');}
}

function renderAuth(status, invite) {
 const mode = !status.initialized ? 'setup' : invite ? 'join' : 'login';
 $('#app').innerHTML=`<main class="auth-page"><section class="auth-card"><div class="auth-art"><div class="brand"><img src="/static/icon.svg" alt=""><div><strong>恋爱空间</strong><small>LOVE, EVERY DAY</small></div></div><h1>把平凡的小日子，<br>收藏成我们的故事。</h1><img class="garden" src="/static/garden.svg" alt="两只小兔子在温暖的小屋前相伴"><p>一屋 · 两人 · 三餐 · 四季<br>这里，装着我们所有的小美好。</p></div><form id="auth-form" class="auth-form"><h2>${mode==='setup'?'开启我们的小世界':mode==='join'?'赴一场两个人的约定':'好久不见，亲爱的'}</h2><p>${mode==='setup'?'先创建你的账号，再邀请另一半入住。':mode==='join'?'你的另一半正在这个小世界里等你。':'登录，继续书写属于你们的故事。'}</p>${mode!=='login'?'<label>你的昵称<input name="name" required maxlength="30" placeholder="希望 TA 怎么称呼你"></label>':''}<label>登录账号<input name="username" required minlength="3" maxlength="40" pattern="[a-zA-Z0-9_.@-]+" autocomplete="username" placeholder="英文、数字，至少 3 位"></label><label>密码<input name="password" type="password" required minlength="10" maxlength="128" autocomplete="${mode==='login'?'current-password':'new-password'}" placeholder="至少 10 个字符"></label>${mode==='setup'&&status.setup_token_required?'<label>初始化口令<input name="token" type="password" required placeholder="部署时设置的 SETUP_TOKEN"></label>':''}<div class="form-error" role="alert"></div><button class="button primary" type="submit">${mode==='login'?'回到我们的小世界':mode==='join'?'接受邀请，成为我们':'创建恋爱空间'} ${icon('arrow')}</button><div class="auth-foot">${icon('lock')} 私密记录 · 只属于彼此</div></form></section></main>`;
 $('#auth-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=$('button[type=submit]',form);b.disabled=true;try {const data=Object.fromEntries(new FormData(form));if(invite)data.token=invite;await post('/'+mode,data);await boot();}catch(err){$('.form-error',form).textContent=err.message;}finally{b.disabled=false;}};
}

async function refreshData() {
 /* 首屏分两窗拉，别让聊天把别的记录挤掉：
    chat 是唯一会无限增长的类型（实测占 88%），却和纪念日/清单/账本抢同一个 limit 窗口，
    窗口一满，最早的纪念日就先消失。现在 chat 单独留最近 200 条（聊天页本来就只显示这么多），
    其他类型走独立的 1000 条窗口——它们都是人工添加，增长很慢。 */
 const [me,others,chats,photos,notices]=await Promise.all([
   api('/me'),
   api('/records?kind='+Object.keys(kindLabel).join(',')+'&exclude=chat&limit=1000'),
   api('/records?kind=chat&limit=200'),
   api('/photos'),
   api('/notices'),
 ]);
 state.me=me;
 const byId=new Map(others.map(r=>[r.id,r]));
 for(const chat of chats)byId.set(chat.id,chat);
 state.records=[...byId.values()];
 state.photos=photos; state.notices=notices;
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
 // 图库页整页挂着一个 iframe（正在挑姿势 / AI 合成台正在出图）：整页 innerHTML 替换会把
 // iframe 整个销毁重建，任务直接断，用户看到的就是「页面自己在快速刷新，来不及点生成」。
 // 这一页不依赖主站数据即时变化、结构也固定，已经渲染过就跳过；切页时 state.page 变了，
 // 判断自然不成立，会正常重绘。
 if (state.page==='figure' && $('#app .figure-page')) return;
 // 整页 innerHTML 替换会把滚动位置清零。SSE 每来一条就重渲染一次的话，
 // 正在翻相册/看时光的人会被不断弹回顶部——所以重渲染前后把位置接回去。
 // 主动切页时 navigate() 会在之后显式 scrollTo(0,0)，不受这里影响。
 const keepScroll=window.scrollY||0;
  const navs=[['home','home','首页'],['timeline','book','时光'],['albums','photo','相册'],['together','heart','我们']];
 const navActive=['personal','settings','channels','backups','notices','imports','importdetail','linkcheck'].includes(state.page)?'together':state.page;
 const navHtml=navs.map(([id,ico,label])=>`<button data-nav="${id}" class="${navActive===id?'active':''}" ${navActive===id?'aria-current="page"':''}>${icon(ico)}<span>${label}</span></button>`);navHtml.splice(2,0,`<button class="nav-fab" data-action="compose" aria-label="记录此刻">${icon('plus')}<span>记录</span></button>`);
 // 「我们」的子工具页（figure/dashboard/weekly 或 together 带 tab）在导航栏最左侧放「回到我们」，
 // 取代原先各页顶部那排 back 条（已移除），回到 together 根页。
 const toolsSub=state.page==='figure'||['dashboard','weekly','settings','channels','backups','linkcheck'].includes(state.page)||(state.page==='together'&&!!state.tab);
/* 返回按钮已移至顶部 topbar（renderShell 内 has-back 分支注入），此处不再在侧边栏/底部 tab 栏注入 */
/* 主题 / 动效 / 字号：class 与 data-fs 都从白名单推导，先全清再挂一个。
   之前这里写着 theme-peach / theme-lavender 三选一的白名单，主题加了以后
   theme-lemon 之类会落到 theme-rose 兜底——换了跟没换一样。 */
 const themeNow=THEME_IDS.includes(state.me.space.theme)?state.me.space.theme:(state.me.space.theme==='custom'?'custom':'rose'),root=document.documentElement;
 ['reduced-motion','theme-custom',...THEME_IDS.map(id=>'theme-'+id)].forEach(c=>root.classList.remove(c));
 root.classList.add('theme-'+themeNow);
 if(!state.me.space.motion)root.classList.add('reduced-motion');
 applyFontScale();
 document.body.className=state.page==='messages'?('chat-full'+(chatBgIsPhoto()?' chat-immersive':'')):(state.page==='watch'?'chat-full watch-open':(state.page==='together'&&state.tab==='calendar'?'cal-full':(state.page==='figure'?'figure-full':'')));
 /* className 是整体覆盖写的，会把 syncKeyboard 加的 kb-open 一起冲掉；键盘还开着就补回来 */
 if(parseFloat(document.documentElement.style.getPropertyValue('--kb-h'))>90)document.body.classList.add('kb-open');
 applyCustomColor(state.me.space.theme,state.me.space.custom_color);
 syncMetaThemeColor();
 $('#app').innerHTML=`<div class="shell${state.page==='messages'?' chat-full':''}${state.page==='watch'?' chat-full watch-full':''}${state.page==='figure'?' figure-full':''}"><aside class="sidebar"><div class="brand"><img src="/static/icon.svg" alt=""><div><strong>恋爱空间</strong><small>LOVE, EVERY DAY</small></div></div><nav class="nav" aria-label="主要导航">${navHtml.join('')}</nav><div class="sidebar-bottom"><div class="little-note"><span>❀</span><br>把喜欢，写进每一天。<br>little things, lasting love</div><button class="profile-btn" data-nav="personal">${avatar(state.me.user.id)}<div><strong>${esc(state.me.user.name)}</strong><small>我的小角落 ${icon('arrow')}</small></div></button></div></aside><main class="main"><header class="topbar${toolsSub?' has-back':''}">${toolsSub?`<button class="nav-back topbar-back" data-action="tools-back" aria-label="回到我们">${icon('back')}</button>`:''}<span class="desktop-date">${new Date().toLocaleDateString('zh-CN',{timeZone:state.me.space.timezone,month:'long',day:'numeric',weekday:'long'})} · 今天也要好好相爱</span><div class="topbar-right"><span class="pill">${icon('lock')} 双人私密空间</span><button class="icon-btn" id="dark-toggle" data-action="toggle-dark" aria-label="切换深浅色">${icon(document.documentElement.classList.contains('dark')?'sun':'moon')}</button><button class="icon-btn" data-action="open-search" aria-label="搜索">${icon('search')}</button><button class="icon-btn" data-nav="messages" aria-label="私聊">${icon('chat')}${state.me.chat_unread&&state.page!=='messages'?`<span class="badge">${state.me.chat_unread>99?'99+':state.me.chat_unread}</span>`:''}</button><button class="icon-btn" data-nav="notices" aria-label="通知">${icon('bell')}${state.me.unread?`<span class="badge">${state.me.unread>99?'99+':state.me.unread}</span>`:''}</button><details class="more-menu account-menu"><summary class="mobile-profile" aria-label="打开账号菜单" title="账号菜单">${avatar(state.me.user.id)}</summary><div class="menu-pop account-popover"><div class="account-menu-heading"><strong>${esc(state.me.user.name)}</strong><small>我的账号</small></div><button data-action="profile">${icon('edit')} 账号资料</button><button data-nav="personal">${icon('lock')} 个人小角落</button><button data-nav="settings">${icon('gear')} 设置</button><button data-action="logout" class="danger account-logout">${icon('arrow')} 退出登录</button></div></details></div></header>${!state.online?'<div class="offline-banner">网络暂时断开，正在等待重连。未发送的文字会为你保留。</div>':''}<div id="page"></div><p class="footer-note">♡ 有你在，平凡的日子也闪闪发光。</p></main></div>`;
 renderPage();
 if(keepScroll>0)window.scrollTo({top:keepScroll});
}

function renderPage() {
 const pages={home:homePage,timeline:timelinePage,albums:albumsPage,messages:messagesPage,together:togetherPage,personal:personalPage,settings:settingsPage,notices:noticesPage,channels:channelsPage,backups:backupsPage,imports:importsPage,importdetail:importDetailPage,dashboard:dashboardPage,weekly:weeklyPage,figure:figurePage,linkcheck:linkCheckPage,watch:watchPage};
 $('#page').innerHTML=(pages[state.page] || homePage)();
 if(state.page==='timeline'&&state.timelineHasMore)$('#timeline-list')?.insertAdjacentHTML('afterend',`<div class="timeline-more">${button('继续往前翻','load-more-timeline','secondary')}</div>`);
 if(state.page==='messages') {
  const ta=$('#chat-text');
  ta.value=localStorage.getItem('chat-text:'+state.me.user.id)||'';
  syncCompose();scrollChat();
  ta.addEventListener('focus',()=>{
   const d=$('#sticker-dock');if(d)d.hidden=true;
   const p=$('#chat-fn');if(p)p.hidden=true;
   /* 键盘弹出后把输入栏顶回可见区：新版 WebView 靠 interactive-widget 自己缩，
      旧版只缩视觉视口，这里补一次滚动兜底。 */
   setTimeout(()=>{try{ta.scrollIntoView({block:'end'});}catch{}},300);
  });
  $('#chat-file')?.addEventListener('change',e=>{const fs=[...e.target.files];e.target.value='';sendChatFiles(fs);});
  $('#chat-shot')?.addEventListener('change',e=>{const fs=[...e.target.files];e.target.value='';sendChatFiles(fs);});
  applyWallpaper();
 }
 if(state.page==='watch'){
  const wt=$('#watch-text');
  if(wt)wt.addEventListener('focus',()=>setTimeout(()=>{try{wt.scrollIntoView({block:'end'});}catch{}},300));
  startWatchSync();
  watchScroll();
 }
 if(state.page==='importdetail') initImportLog();
 syncStatusBarOverlay();
  if(state.page==='home'){measureHero();loadOnThisDay();loadYearbook();}
  if(state.page==='together'&&state.tab==='calendar') loadCalendar();
  /* 自定义清单表单：questPage 渲染后单独绑定 submit（不走 data-action 代理） */
  if(state.page==='together'&&state.tab==='quest'){const qf=$('#quest-custom-form');if(qf&&!qf.dataset.bound){qf.dataset.bound='1';qf.onsubmit=async e=>{e.preventDefault();const input=$('#quest-custom-input');const title=input.value.trim();if(!title)return;try{await post('/records',{kind:'quest',body:{title,category:'自定义',done:false},client_id:uuid()});input.value='';await refresh();toast('已加入清单');}catch(err){toast(err.message);}};}}
}
/* state.me 还没到时不要渲染：boot() 是异步的，用户在首屏加载完之前点导航（或 hashchange 抢跑）
   会让 renderShell 读到 null.space 抛 TypeError，被 catch 成一条吓人的报错提示。
   直接返回即可——boot() 结束时会按 location.hash 渲染到正确的页面。 */
/* 本次会话里由 navigate() 往历史栈压过几条。用来判断"现在能不能后退"：
   直接从深链进来（#watch）时 history 里没有上一页，这时候 history.back()
   会把整个 App 关掉，必须回落到 navigate。 */
let navDepth=0;
async function navigate(page,tab='') {if(!state.me)return;if(page!=='messages')state.chatReturn={page,tab};if(page==='messages'&&state.me){state.me.chat_unread=0;post('/notices/read?event=chat').catch(()=>{});/* 进聊天不主动弹输入法：先把上一页可能还活着的焦点交还，再渲染 */if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();}state.page=page;state.tab=tab;if(location.hash!=='#'+page){location.hash=page;navDepth++;}try{if(page==='timeline')await loadTimeline(true);await loadSpecial();renderShell();window.scrollTo({top:0});}catch(e){toast(e.message);}}
/* 返回上一页：走浏览器后退，**不要**再 push 一条新的 hash。
   以前「一起看 → 返回」写的是 navigate('messages')，等于在历史里又压了一条 #messages，
   于是栈变成 [ #messages, #watch, #messages ]——安卓实体返回键每按一次就在这两个界面
   之间来回跳，怎么都退不回首页。现在三处"返回"统一走这里。
   万一历史里确实没有上一页（深链直进），history.back() 什么也不会发生，
   220ms 后按 fallback 兜底；真没有上一页时 back() 还可能把整个 App 退掉，
   所以先用 navDepth/history.length 挡一层。 */
function goBack(fallback='home',tab=''){
 const ok=navDepth>0&&history.length>1;
 if(!ok)return navigate(fallback,tab);
 const before=location.hash;
 history.back();navDepth--;
 setTimeout(()=>{if(location.hash===before)navigate(fallback,tab);},220);
}
/* 摆拍参考：整页一屏（body/shell 加 figure-full 修饰类），iframe 直接吃掉标题以下的
   全部空间——不再套 .card 的边框/圆角/内边距，下方不留白。 */
function figurePage() {
  return `<div class="figure-page">
    <div class="page-heading">
      <div><h1>情侣摆拍参考</h1><p>照着下面的姿势参考，拍一张属于你们的照片。</p></div>
      <a class="link-btn figure-open" href="/pose-gallery/poses" target="_blank" rel="noopener">新标签打开 ${icon('arrow')}</a>
    </div>
    <div class="figure-frame">
      <iframe class="figure-iframe" src="/pose-gallery/poses" title="情侣姿势参考" loading="lazy" referrerpolicy="no-referrer"></iframe>
    </div>
  </div>`;
}

async function loadSpecial(){
 if(state.page==='channels'){
  [state.channels,state.deliveries,state.webpush]=await Promise.all([api('/channels'),api('/deliveries'),api('/webpush')]);
  state.webpush.local=false;
  if(browserPushSupported()&&!isNativeApp()){try{state.webpush.local=Boolean(await (await navigator.serviceWorker.ready).pushManager.getSubscription());}catch{}}
  if(isNativeApp()){try{const push=nativePushBridge();state.nativePush=push?.status?await push.status():{available:false,error:'原生提醒插件不可用'};}catch{state.nativePush={available:false};}}
 }
 // 设置页只要一行摘要；非管理员 /api/storage 会 403，所以只在 admin 时才请求。
 // 备份页那一路已经拉完整数据，这里命中缓存就够了。
 if(state.page==='settings'&&state.me.user.admin){try{state.storage=await api('/storage');}catch{state.storage=null;}}
 // 非管理员直接改 hash 进备份页时 /api/backups 会 403，别让整页崩掉
 if(state.page==='backups'){try{state.backups=await api('/backups');}catch{state.backups=[];}try{state.storage=await api('/storage');}catch{state.storage=null;}}
 if(state.page==='personal'&&state.tab==='trash')state.trash=await api('/records?trash=true&kind='+Object.keys(kindLabel).join(','));
 if(state.page==='imports'||state.page==='importdetail')state.imports=await api('/imports');
 if(state.page==='dashboard')state.dashboard=await api('/dashboard');
 if(state.page==='weekly')state.weekly=await api('/weekly?offset='+(state.weekOffset||0));
}
async function refresh(render=true){if(refreshing){state.pendingRefresh=true;return;}refreshing=true;try{await refreshData();if(state.page==='timeline')await loadTimeline(true);await loadSpecial();if(render)renderShell();}finally{refreshing=false;}/* 刷新期间若有新事件被排队，完成后立刻补一轮，事件不再丢失 */if(state.pendingRefresh){state.pendingRefresh=false;handleServerEvent();}}

function nextAnniversary() {
 return recordsOf('anniversary').map(r=>{let date=r.body.date;if(r.body.annual===true){const year=Number(today().slice(0,4));date=year+date.slice(4);if(date.endsWith('02-29')&&new Date(year,1,29).getMonth()!==1)date=year+'-02-28';if(date<today()){date=(year+1)+r.body.date.slice(4);if(date.endsWith('02-29')&&new Date(year+1,1,29).getMonth()!==1)date=(year+1)+'-02-28';}}return {...r,due:date,days:daysBetween(today(),date)};}).filter(r=>r.days>=0).sort((a,b)=>a.days-b.days)[0];
}
/* ———— 每日一句 / 相爱天数卡片 ———— */
const DAILY_QUOTES=[
 '喜欢是乍见之欢，爱是久处不厌。','日子很普通，但有你就不一样。','今天也想和你一起，把生活过成一件件小事。',
 '你是我所有计划里，唯一不变的那一项。','一起吃饭，一起发呆，一起把日子过完。','世界很大，我的坐标是你。',
 '想和你把「以后」两个字，慢慢过成具体的日子。','不必每天都惊喜，只要每天都有你。','我们不用很厉害，只要一直在一起。',
 '喜欢你这件事，我做得最久。','天气预报说明天有雨，我记得带伞，也记得带你。','你笑的时候，我觉得今天没白过。',
 '柴米油盐里，也藏着浪漫。','不用去很远的地方，回家就是最好的旅行。','你在的地方，就是我想去的地方。',
 '想和你一起变老，慢慢的那种。','今天的月亮很好，你也在，就更好了。','爱是记得，也是愿意。',
 '日子一天天过去，喜欢一天天变多。','我们把普通的日子，过成了纪念日。','你说话的时候，我在认真听。',
 '抱一下，今天就算圆满。','一天很短，但装得下想念。','明天也一起吃早饭吧。'];
const dailyQuote=()=>DAILY_QUOTES[dayNum(today())%DAILY_QUOTES.length];
function dailyQuoteBlock(){return `<section class="daily-quote">${icon('star')}<span>${esc(dailyQuote())}</span><small>今天的一句</small></section>`;}
function songsCard(){
 const songs=recordsOf('music').slice().sort((a,b)=>b.created-a.created).slice(0,3);
 return `<div class="card"><div class="section-heading"><h2>${icon('music')} 我们的歌</h2><button class="link-btn" data-action="tool-music">歌单 →</button></div>${songs.length?songs.map(r=>`<div class="song-line"><span class="song-dot">♪</span><div><strong>${esc(r.body.title||'未命名')}</strong><small class="meta">${esc(r.body.content||'')}</small></div></div>`).join(''):'<p class="meta">还没有歌，去放一首属于你们的第一首。</p>'}</div>`;
}
function loveCardImage(){
 const {space,user,users}=state.me,partner=users.find(u=>u.id!==user.id);
 const days=space.since?Math.max(0,daysBetween(space.since,today())+1):null;
 if(days===null)return toast('先在「空间设置」里填上相恋日期');
 const W=1080,H=1350,cv=document.createElement('canvas');cv.width=W;cv.height=H;
 const x=cv.getContext('2d'),F='"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif';
 const g=x.createLinearGradient(0,0,W,H);g.addColorStop(0,'#f9dfe6');g.addColorStop(.55,'#fdf3f1');g.addColorStop(1,'#f2d9e7');
 x.fillStyle=g;x.fillRect(0,0,W,H);
 x.save();x.globalAlpha=.45;x.fillStyle='#ffffff';
 x.beginPath();x.arc(90,150,150,0,Math.PI*2);x.fill();
 x.beginPath();x.arc(W-60,H-170,200,0,Math.PI*2);x.fill();x.restore();
 x.textAlign='center';
 x.fillStyle='#a75b70';x.font=`600 40px ${F}`;x.fillText('我 们 相 恋',W/2,300);
 x.fillStyle='#c2557a';x.font=`800 300px ${F}`;x.fillText(String(days),W/2,640);
 x.fillStyle='#a75b70';x.font=`600 54px ${F}`;x.fillText('天',W/2,730);
 x.fillStyle='#8c4a5c';x.font=`600 46px ${F}`;x.fillText(partner?`${user.name} & ${partner.name}`:user.name,W/2,880);
 x.fillStyle='#a9808d';x.font=`400 30px ${F}`;x.fillText(`从 ${space.since} 走到今天`,W/2,940);
 x.fillStyle='#a9808d';x.font=`400 32px ${F}`;x.fillText(dailyQuote(),W/2,1120);
 x.fillStyle='#c0a3ac';x.font=`400 24px ${F}`;x.fillText('恋爱空间 · 我们的每一天',W/2,1250);
 cv.toBlob(blob=>{
  if(!blob)return toast('导出失败，换个浏览器试试');
  const a=document.createElement('a'),url=URL.createObjectURL(blob);
  a.href=url;a.download=`我们的第${days}天-${today()}.png`;a.click();
  setTimeout(()=>URL.revokeObjectURL(url),5000);toast('卡片已保存到下载');
 },'image/png');
}
/* ── 首页封面构图 ──────────────────────────────
   三个数就够描述「这张照片在 hero 卡里怎么摆」：x/y 是 object-position 的百分比，z 是放大倍数。
   不预先把图裁死再存，好处是原图一点不损失、随时可以反悔，换成大屏手机也不会糊。
   ⚠️ hero 和裁剪弹窗共用 coverStyle()，两边算法一旦分叉，预览就会和首页对不上。 */
function coverPos(raw){
 const src=(raw&&typeof raw==='object')?raw:{};
 const num=(v,d)=>{const n=Number(v);return isFinite(n)?n:d;};
 return {x:Math.min(100,Math.max(0,num(src.x,50))),
         y:Math.min(100,Math.max(0,num(src.y,50))),
         z:Math.min(3,Math.max(1,num(src.z,1)))};
}
function coverStyle(raw){
 const p=coverPos(raw);
 let css=`object-position:${p.x}% ${p.y}%`;
 /* z=1 时不写 transform：多一层变换在部分安卓 WebView 上会让照片发虚。
    缩放中心必须钉在正中（默认值）——如果跟着 x/y 走，改一次 x 会同时挪位置和挪缩放原点，
    位移按 (1-z) 倍额外放大，手指和画面就对不上了。 */
 if(p.z>1.001)css+=`;transform:scale(${p.z})`;
 return css;
}
function coverImg(mid,pos){
 /* role=cover 是给 Service Worker 看的暗号：带它的请求走 cache-first，
    服务端也只对这一个参数放行缓存头。换封面时 id 会变，缓存自然失效重拉一次。 */
 return `<img class="hero-art hero-cover" src="/media/${esc(mid)}?preview=true&role=cover" alt="我们的合照封面" style="${coverStyle(pos)}" draggable="false" decoding="async">`;
}
/* 首页那张 hero 卡的宽高比：裁剪弹窗要按同一个比例画预览框，否则「所见」对不上「所得」 */
function measureHero(){
 const h=$('.hero');
 if(h&&h.clientWidth>8&&h.clientHeight>8)state.heroRatio=h.clientWidth/h.clientHeight;
}
/* 封面构图弹窗：拖动平移 + 滑块/滚轮/双指缩放，所见即所得（预览框的宽高比取自首页那张 hero）。
   只改三个数，不动原图；「复位」永远能回到正中的样子。 */
function coverCropModal(mid){
 const space=state.me.space||{};
 const coverId=mid||space.cover;
 if(!coverId)return toast('先给空间选一张封面照片');
 const same=coverId===space.cover;
 let pos=coverPos(same?space.cover_pos:null);
 const hero=$('.hero');
 const hw=hero?hero.clientWidth:0,hh=hero?hero.clientHeight:0;
 /* 优先用 renderPage 里量好的比例：弹窗打开时 body 会被设成 overflow:hidden，
    滚动条一消失页面就变宽，现量出来的比例会比真实首页差几个百分点。 */
 const ratio=state.heroRatio||((hw>8&&hh>8)?(hw/hh):1.9);
 openModal('调整封面背景',`<div class="crop-wrap">
  <div class="crop-frame" id="crop-frame" style="padding-top:${(100/ratio).toFixed(2)}%">
   <img id="crop-img" src="/media/${esc(coverId)}?preview=true&role=cover" alt="封面预览" draggable="false">
   <i class="crop-shade" aria-hidden="true"></i>
   <i class="crop-grid" aria-hidden="true"></i>
  </div>
  <div class="crop-tools">
   <div class="crop-zoom-row"><span class="crop-zoom-end">缩小</span><input type="range" id="crop-zoom" min="100" max="300" step="1" value="${Math.round(pos.z*100)}" aria-label="缩放图片"><span class="crop-zoom-end">放大</span><b id="crop-zoom-val">${Math.round(pos.z*100)}%</b></div>
   <div class="crop-acts"><button type="button" class="button soft" id="crop-reset">复位</button><button type="button" class="button primary" id="crop-save">保存构图</button></div>
  </div>
  <p class="small-note">按住图片拖动来摆位置，放大后能挪得更细。只记住构图，原图不会被裁掉，随时能重新调。</p>
 </div>`);
 const frame=$('#crop-frame'),img=$('#crop-img'),zoom=$('#crop-zoom'),zoomVal=$('#crop-zoom-val');
 if(!frame||!img)return;
 let natW=0,natH=0;
 const readNat=()=>{natW=img.naturalWidth||0;natH=img.naturalHeight||0;};
 img.addEventListener('load',readNat);readNat();
 const apply=()=>{
  img.style.cssText=coverStyle(pos);
  if(zoom)zoom.value=String(Math.round(pos.z*100));
  if(zoomVal)zoomVal.textContent=Math.round(pos.z*100)+'%';
  frame.classList.toggle('zoomed',pos.z>1.001);
 };
 /* 拖动换算要算清「图片按 cover 铺满预览框后到底溢出多少像素」，否则手指和画面不同步。
     注意缩放是 CSS transform，位移到画面上会被放大约 z 倍，所以除数里必须带上 z。 */
 const box=()=>{
  const w=frame.clientWidth,h=frame.clientHeight;
  if(!w||!h||!natW||!natH)return null;
  const base=Math.max(w/natW,h/natH);
  return {ox:Math.max(0,natW*base-w),oy:Math.max(0,natH*base-h)};
 };
 const pan=(dx,dy)=>{
  const b=box();if(!b)return;
  if(b.ox>1)pos.x=Math.min(100,Math.max(0,pos.x-dx*100/(pos.z*b.ox)));
  if(b.oy>1)pos.y=Math.min(100,Math.max(0,pos.y-dy*100/(pos.z*b.oy)));
  apply();
 };
 const setZoom=z=>{pos.z=Math.min(3,Math.max(1,z));apply();};
 const pointers=new Map();
 let drag=null,pinch=null;
 frame.addEventListener('pointerdown',e=>{
  if(frame.setPointerCapture)try{frame.setPointerCapture(e.pointerId);}catch{}
  pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});
  if(pointers.size===1){drag={id:e.pointerId,x:e.clientX,y:e.clientY};frame.classList.add('dragging');}
  else if(pointers.size===2){drag=null;const p=[...pointers.values()];pinch={d:Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y)||1,z:pos.z};}
 });
 frame.addEventListener('pointermove',e=>{
  if(!pointers.has(e.pointerId))return;
  pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});
  if(pinch&&pointers.size>=2){
   const p=[...pointers.values()],d=Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y)||1;
   setZoom(pinch.z*d/pinch.d);return;
  }
  if(drag&&drag.id===e.pointerId){pan(e.clientX-drag.x,e.clientY-drag.y);drag.x=e.clientX;drag.y=e.clientY;}
 });
 const release=e=>{
  pointers.delete(e.pointerId);
  if(pointers.size<2)pinch=null;
  if(drag&&drag.id===e.pointerId)drag=null;
  if(!pointers.size)frame.classList.remove('dragging');
 };
 frame.addEventListener('pointerup',release);
 frame.addEventListener('pointercancel',release);
 frame.addEventListener('wheel',e=>{e.preventDefault();setZoom(pos.z*(e.deltaY<0?1.08:1/1.08));},{passive:false});
 if(zoom)zoom.oninput=()=>setZoom(Number(zoom.value)/100);
 $('#crop-reset').onclick=()=>{pos={x:50,y:50,z:1};apply();};
 $('#crop-save').onclick=async e=>{
  const b=e.currentTarget;b.disabled=true;b.textContent='保存中…';
  try{
   const s=state.me.space||{};
   /* 只传空间级必填字段 + 构图；聊天壁纸那几项留空后端会沿用原值 */
   await put('/space',{name:s.name,since:s.since||'',cover:coverId,theme:s.theme||'rose',
    custom_color:s.theme==='custom'?(s.custom_color||''):'',motion:s.motion!==false,
    timezone:s.timezone||'Asia/Shanghai',cover_pos:{x:pos.x,y:pos.y,z:pos.z}});
   closeModal();await refresh();toast('首页封面已按这个构图显示');
  }catch(err){b.disabled=false;b.textContent='保存构图';toast(err.message);}
 };
 apply();
}
/* 首页右上角那颗图片图标：点一下直接从相册里挑一张当背景（也能现拍现传）。
   原来它只弹构图弹窗，想换图得绕去空间设置里翻半天；图定下来之后顺手把构图弹窗打开
   （换图十有八九要摆一下位置），不想调直接关掉就行，图已经生效了。 */
function pickCover(){albumModal('换一张封面背景',mid=>applyCover(mid));}
async function applyCover(mid){
 const s=state.me.space||{};
 try{
  /* 只传空间级必填字段：聊天壁纸那几项留空，后端会沿用原值（见 PUT /api/space） */
  await put('/space',{name:s.name,since:s.since||'',cover:mid,theme:s.theme||'rose',
   custom_color:s.theme==='custom'?(s.custom_color||''):'',motion:s.motion!==false,
   timezone:s.timezone||'Asia/Shanghai',cover_pos:{x:50,y:50,z:1}});
  await refresh();
  coverCropModal(mid);
 }catch(err){toast(err.message||'封面照片没设置成功，再试一次');}
}
/* ── 相册选图（首页封面 / 聊天背景共用） ──
   数据来自 /api/media/images：最近上传、且我有权看的图。相册页只列记录引用过的照片，
   聊天里发过、当过头像、合成台出的图都不在里面，所以这里单独扫媒体表。 */
function albumTiles(list){
 return list.map(m=>`<button type="button" class="album-thumb" data-mid="${esc(m.id)}" aria-label="${esc(m.name||'照片')}"><img src="/media/${esc(m.id)}?preview=true" alt="" loading="lazy" decoding="async"></button>`).join('');
}
async function albumModal(title,onPick){
 let list=[];
 try{list=await api('/media/images?limit=200');}catch{}
 openModal(title,`<div class="album-pick-head"><span>${list.length?`共 ${list.length} 张照片`:'相册里还没有照片'}</span><button type="button" class="button soft" id="album-upload">从手机上传</button></div><div class="album-pick" id="album-pick">${list.length?albumTiles(list):'<p class="meta">先从手机上传一张，以后换封面就能直接从相册里挑了。</p>'}</div>`,{wide:true});
 $('#album-pick').onclick=e=>{const b=e.target.closest('[data-mid]');if(!b)return;closeModal();onPick(b.dataset.mid);};
 $('#album-upload').onclick=()=>{
  const inp=document.createElement('input');
  inp.type='file';inp.accept='image/jpeg,image/png,image/webp';inp.style.display='none';
  document.body.appendChild(inp);
  inp.addEventListener('change',async()=>{
   const f=inp.files&&inp.files[0];inp.remove();if(!f)return;
   toast('正在上传…');
   try{const m=await uploadFile(f);closeModal();onPick(m.id);}catch(err){toast(err.message);}
  });
  inp.click();
 };
}
/* 表单里的相册：不另开弹窗——表单本身就是弹窗，再叠一层会把填了一半的内容扔掉，
   所以在原地展开一片缩略图。 */
async function albumInline(box,onPick){
 if(!box)return;
 if(!box.hidden){box.hidden=true;return;}
 box.hidden=false;
 box.innerHTML='<p class="meta" style="grid-column:1/-1">正在读取相册…</p>';
 let list=[];
 try{list=await api('/media/images?limit=120');}catch{}
 if(!list.length){box.innerHTML='<p class="meta" style="grid-column:1/-1">相册里还没有照片，点上方的「用你们的照片」从手机传一张。</p>';return;}
 box.innerHTML=albumTiles(list);
 box.onclick=e=>{const b=e.target.closest('[data-mid]');if(!b)return;box.hidden=true;onPick(b.dataset.mid);};
}
function homePage() {
 const {space,user,users}=state.me,partner=users.find(u=>u.id!==user.id),days=space.since?Math.max(0,daysBetween(space.since,today())+1):null,anniversary=nextAnniversary(),posts=recordsOf('post').slice(0,3),wishes=recordsOf('wish');
 /* 今天的心情：每一行都是一颗按钮——自己的没记就去记，已记就点开改（改的仍是心情手记里那条），
    对方的点进去看心情手记。moodRows 同时用在手机上那两格和桌面右栏的心情卡。 */
 const moodRows=users.map(u=>{
  const m=recordsOf('mood').find(r=>r.author===u.id&&r.body.date===today());
  const mine=u.id===state.me.user.id;
  const act=m?(mine?`data-action="edit-record" data-id="${m.id}"`:'data-action="mood-history"'):(mine?'data-action="mood-quick"':'data-action="mood-history"');
  const bubble=m?`${esc(m.body.emoji)+' '+esc(m.body.content||'已记录')}`:(mine?'＋ 记一笔':'等一个好心情');
  const label=`${esc(u.name)}${m?'：'+esc(m.body.emoji||'')+' '+esc(m.body.content||'已记录'):(mine?'，今天还没记，点这里记一笔':'，还没记')}`;
  return `<button type="button" class="mood-row${m?'':' no-mood'}" ${act} aria-label="${label}">${avatar(u.id)}<span>${esc(u.name)}</span><span class="mood-bubble${m?'':' empty'}">${bubble}</span></button>`;
 }).join('');
 const moodCell=`<div class="today-cell"><span class="tiny">${icon('sun')} 今天的心情</span><div class="mood-inline">${moodRows}</div></div>`;
 /* 最近纪念日：整格可点，进纪念日页；一个都没有时保留原来的「添加纪念日」按钮 */
 const annCell=anniversary
  ?`<button type="button" class="today-cell today-cell-link" data-action="tool-anniversary" aria-label="最近纪念日：${esc(anniversary.body.title)}，${anniversary.days} 天后"><span class="tiny">${icon('calendar')} 最近纪念日<span class="tiny-go">${icon('arrow')}</span></span><div class="countdown-mini"><strong>${anniversary.days}</strong><span>天后 · ${esc(anniversary.body.title)}</span></div><p class="meta">${anniversary.due} · 别忘了给彼此一个拥抱</p></button>`
  :`<div class="today-cell"><span class="tiny">${icon('calendar')} 最近纪念日</span><div class="countdown-mini"><strong>♡</strong><span>留一个日子，给仪式感</span></div>${button('添加纪念日','new-anniversary','small secondary')}</div>`;
 const todayCard=`<section class="today-card" aria-label="今天的陪伴">${moodCell}${annCell}</section>`;
 /* 共同打卡：提到首页最显眼的位置。今天谁打卡了一目了然，点一下就打卡，
    不用再翻「在一起」页；两张卡都齐了就安静地收成一行「圆满」。 */
 const habits=recordsOf('habit');
 const habitCard=habits.length?`<section class="habit-card" aria-label="共同打卡">${habits.map(r=>{
  const done=new Set((r.checks||[]).filter(c=>c.day===today()).map(c=>c.author)),mine=done.has(state.me.user.id),all=done.size>=2;
  return `<div class="habit-row${all?' all-done':''}"><div class="habit-info"><b>${esc(r.body.title)}</b><span class="tiny">今天 ${done.size}/2 人${all?' · 圆满完成':''}</span></div>${all?'<span class="habit-done" aria-label="已完成">✓</span>':button(mine?'今天已打卡':'打卡','check','small soft','check',`data-id="${r.id}"`)}</div>`;
 }).join('')}<p class="meta">晚上八点前还没打卡的话，会互相提个醒。</p></section>`:'';
 /* 主视觉：照片 + 两个人的名字 + 相恋天数。
    去掉了原来那一对 44px 头像——侧栏、顶栏、每条记录里到处都是头像，
    这里再用两个圆把画面的左上角占掉，既挡住照片又抢戏；名字之间那颗小心形
    已经把「两个人」说清楚了。 */
 const heroNames=partner?`${esc(user.name)}<span class="hero-amp" aria-hidden="true">♥</span>${esc(partner.name)}`:'等你，把另一半邀请进来';
 const heroCopy=`<section class="hero">${space.cover?coverImg(space.cover,space.cover_pos):'<img class="hero-art" src="/static/garden.svg" alt="两只小兔子守着共同的小家">'}<div class="hero-mask"></div><button type="button" class="hero-crop" data-action="cover-pick" aria-label="${space.cover?'更换封面照片':'设置一张照片当封面'}" title="${space.cover?'更换背景':'设置背景'}">${icon('image')}<span>${space.cover?'更换背景':'设置背景'}</span></button><div class="hero-copy"><div class="hero-main"><span class="hero-names-text">${heroNames}</span>${partner?'':`<button class="link-btn" data-action="invite">发送邀请，让 TA 住进来 →</button>`}<div class="hero-days"><small>我们相恋</small><strong>${days??'—'}<em>天</em></strong></div><div class="hero-foot">${days===null?`<button class="link-btn" data-action="space">设置相恋日期 →</button>`:`<span class="hero-since">${esc(space.since)} 起 · 今天也要好好相爱</span><button class="link-btn" data-action="love-card">存一张天数卡片 →</button>`}</div></div></div></section>`;
 const composeCta=`<button class="compose-cta" data-action="compose">${icon('edit')} 记录此刻</button>`;
 const homeHeading=heading('我们的每一天','一半是生活，一半是你。','compose','记录此刻','edit').replace('page-heading','page-heading home-heading');
 return `${homeHeading}${heroCopy}${todayCard}${habitCard}${composeCta}${dailyQuoteBlock()}
 <div class="home-grid"><div class="home-main"><section><div class="section-heading"><h2>${icon('book')} 最近的小美好</h2><button class="link-btn" data-nav="timeline">所有时光 ${icon('arrow')}</button></div>${posts.length?posts.map(recordCard).join(''):`<div class="card">${empty('故事，从这一刻开始','一张照片、一句想说的话，都是值得收藏的小美好。','compose')}</div>`}</section>
 <section class="on-this-day" id="on-this-day"><div class="loading-heart" style="font-size:var(--fs-xl)">♡</div><p class="meta meta-center">正在翻看这一天的回忆…</p></section>
 <section class="yearbook" id="yearbook"><h2>📖 今年的我们</h2><div class="yearbook-summary"><p>点开看看，这一年我们一起写下了什么。</p><span class="yearbook-toggle-row">${button('展开小年报','expand-yearbook','soft small','arrow')}</span></div></section></div>
 <aside class="home-aside"><div class="card mood-card"><div class="section-heading"><h2>☀ 今天的心情</h2><button class="link-btn" data-action="mood-history">回顾 →</button></div>${moodRows}${button('分享今天的心情','mood','soft')}</div>
 <div class="card anniversary-card">${anniversary?`<button type="button" class="anniversary-link" data-action="tool-anniversary" aria-label="最近纪念日：${esc(anniversary.body.title)}，${anniversary.days} 天后"><span class="tiny">${icon('calendar')} 下一个值得期待的日子<span class="tiny-go">${icon('arrow')}</span></span><h3>${esc(anniversary.body.title)}</h3><div class="countdown">${anniversary.days}<small>天后</small></div><p>${anniversary.due} · 别忘了给彼此一个拥抱</p></button>`:`<span class="tiny">${icon('calendar')} 下一个值得期待的日子</span><h3>留一个日子，给仪式感</h3><div class="countdown">♡</div>${button('添加纪念日','new-anniversary','small secondary')}`}</div>
 <div class="card"><div class="section-heading"><h2>✧ 我们的小心愿</h2><button class="link-btn" data-action="tool-wish">全部 →</button></div>${wishes.length?wishes.slice(0,3).map(r=>`<button class="wish-line ${r.body.done?'done':''}" data-action="toggle-wish" data-id="${r.id}"><span class="check-circle"></span>${esc(r.body.title)}</button>`).join(''):empty('一起期待下一件小事','想去的地方，想做的事情，都记在这里。','new-wish','许个心愿',true)}</div>${songsCard()}</aside></div>`;
}

function mediaMarkup(media=[]) {
 if(!media.length)return '';
 const VOICE_ICON='<svg class="v-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 9.5v5c0 .55.45 1 1 1h3.2L12 19.4V4.6L7.2 8.5H4c-.55 0-1 .45-1 1Z" fill="currentColor"/><path class="v-w1" d="M15.5 8.7a4.7 4.7 0 0 1 0 6.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path class="v-w2" d="M18.2 6.2a8.4 8.4 0 0 1 0 11.6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
 return `<div class="media-grid ${media.length===1?'single':''}">${media.map(m=>m.mime.startsWith('image/')?`<button data-action="photo" data-id="${m.id}" aria-label="查看照片 ${esc(m.name)}"><img loading="lazy" src="/media/${m.id}?preview=true" alt="${esc(m.name)}"></button>`:m.mime.startsWith('video/')?`<button class="media-video" data-action="video" data-id="${m.id}" aria-label="播放视频 ${esc(m.name)}"><video muted playsinline preload="metadata" poster="/media/${m.id}?poster=true" src="/media/${m.id}?preview=true"></video><span class="play-badge"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5v14l11-7z"/></svg></span></button>`:`<button type="button" class="voice-chip" data-voice-play aria-label="播放语音">${VOICE_ICON}<b class="voice-dur">--</b><audio class="voice-audio" preload="metadata" src="/media/${m.id}?preview=true"></audio></button>`).join('')}</div>`;
}
/* 微信式语音消息：点击整条气泡播放；原生 <audio controls> 在 Android WebView 里样式不可控，已弃用 */
const fmtVoiceTime=s=>{if(!isFinite(s)||s<=0)return "0''";return s<60?Math.round(s)+"''":Math.floor(s/60)+':'+String(Math.floor(s%60)).padStart(2,'0');};
/* 沉浸式下「撤回 / 记入时光」默认收起（见 CSS），手机点一下这条消息才展开。
   没有 hover 的触屏设备必须有这条路，否则操作永远摸不出来。
   发出失败的那些行带 .pending，始终显示，别把"没发出去"也藏了。 */
document.addEventListener('click',e=>{
 const line=e.target.closest('.chat-line:not(.pending)');
 if(!line)return;
 document.querySelectorAll('.chat-line.tap-ops').forEach(x=>{if(x!==line)x.classList.remove('tap-ops');});
 line.classList.toggle('tap-ops');
});
document.addEventListener('click',e=>{
 const chip=e.target.closest('[data-voice-play]');if(!chip)return;
 const audio=chip.querySelector('audio');if(!audio)return;
 if(audio.paused){document.querySelectorAll('.voice-chip.playing audio').forEach(a=>{if(a!==audio)a.pause();});audio.play().catch(()=>toast('语音播放失败，请稍后再试'));}
 else audio.pause();
});
document.addEventListener('click',e=>{
 const it=e.target.closest('[data-watch-media]');if(!it)return;
 watchChooseMedia(it.dataset.watchMedia,it.dataset.watchTitle||'');
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
/* 在线搜来的封面走 /api/music/stream 转发，Apple 那边偶尔拿不到图：失败就退回一个音符。
   用捕获阶段监听而不是行内 onerror —— CSP 的 script-src 'self' 会把行内处理器整条拦掉。 */
document.addEventListener('error',e=>{
 const img=e.target;
 if(!img||img.tagName!=='IMG'||!img.parentNode)return;
 const box=img.parentNode;
 if(!box.classList||!(box.classList.contains('cs-cover')||box.classList.contains('sp-cover')))return;
 box.innerHTML=icon('music');
},true);
/* 纪念日序数：把所有年度重复的纪念日按日期排好，给每个标上「今年第几个」 */
function anniversaryOrdinals(){
 const items=recordsOf('anniversary').filter(r=>r.body.annual===true||r.body.annual==='lunar');
 const year=Number(today().slice(0,4));
 const sorted=items.map(r=>{
  let d=r.body.date;
  if(r.body.annual===true){
   d=year+d.slice(4);
   if(d.endsWith('02-29')&&new Date(year,1,29).getMonth()!==1)d=year+'-02-28';
   if(d<today())d=(year+1)+r.body.date.slice(4);
   if(d.endsWith('02-29')&&new Date(year+1,1,29).getMonth()!==1)d=(year+1)+'-02-28';
  }
  return {id:r.id,due:d,ordinal:0};
 }).sort((a,b)=>a.due<b.due?-1:1);
 sorted.forEach((s,i)=>s.ordinal=i+1);
 const map={};sorted.forEach(s=>map[s.id]=s.ordinal);
 return map;
}

function recordCard(r) {
 if(r.kind==='personal_wish')return personalWishCard(r);
 if(r.kind==='music')return musicCard(r);
 // period 的日记录行（有 date 没 start）只活在生理期页里，别混进动态流和别的列表
 if(r.kind==='period'&&!r.body.start)return '';
 const own=r.author===state.me.user.id,sharedEdit=['album','anniversary','wish','habit','quest','ledger','music'].includes(r.kind),b=r.body;
 return `<article class="card kind-${r.kind}" data-record="${r.id}"><div class="card-header">${avatar(r.author)}<div><strong>${esc(person(r.author).name)}</strong><small>${esc(b.date||dateLabel(r.created))}${['diary','draft','surprise'].includes(r.kind)?' · '+kindLabel[r.kind]:''}${b.was_surprise?' · 一份公开的惊喜':''}</small></div><div class="card-menu">${own||sharedEdit?`<details class="more-menu"><summary aria-label="更多操作" title="更多操作">⋯</summary><div class="menu-pop"><button data-action="edit-record" data-id="${r.id}">${icon('edit')} 编辑</button><button data-action="delete-record" data-id="${r.id}" class="danger">${icon('trash')} 删除</button></div></details>`:''}</div></div>${b.title?`<h3 class="card-title">${esc(b.title)}</h3>`:''}<p class="card-text">${esc(b.content||'')}</p>${mediaMarkup(r.media)}${r.kind==='surprise'?`<p class="hint">${icon('lock')} 将于 ${dateLabel(b.publish_at)} 公开，目前只有你能看见。</p>`:''}${r.kind==='anniversary'?`<p class="meta">${esc(b.date)} · ${b.annual==='lunar'?'每年农历日期':b.annual===false?'一次性纪念日':'每年公历日期'} · 提前 ${b.remind_days??1} 天提醒${b.annual!==false?` · 今年第 ${(anniversaryOrdinals()[r.id]||0)} 个`:''}</p><div class="inline-actions">${button('回看这一天','anniversary-memories','small soft','calendar',`data-date="${esc(b.date)}"`)}</div>`:''}${r.kind==='wish'?`<p class="meta">${esc(b.category||'小心愿')}${b.target?' · 约定 '+esc(b.target):''}</p><div class="inline-actions">${button(b.done?'已完成 · 再次点亮期待':'完成这个心愿','toggle-wish','small soft','check',`data-id="${r.id}"`)}${b.done?button('记录实现的那一刻','wish-memory','small secondary','edit',`data-id="${r.id}"`):''}</div>`:''}${r.kind==='quest'?`<p class="meta">${esc(b.category||'日常')}${b.date?' · 计划 '+esc(b.date):''}</p><div class="inline-actions">${button(b.done?'已完成 · 取消勾选':'标记为完成','toggle-quest','small soft','check',`data-id="${r.id}"`)}${b.done?button('记录实现的那一刻','wish-memory','small secondary','edit',`data-id="${r.id}"`):''}</div>`:''}${r.kind==='ledger'?`<p class="meta"><strong>¥${Number(b.amount||0).toFixed(2)}</strong> · ${esc(b.category||'其他')}${b.date?' · '+esc(b.date):''}</p>`:''}${r.kind==='period'?`<p class="meta">${esc(b.start)} 开始 · 经期 ${b.length||5} 天${b.cycle?' · 周期 '+b.cycle+' 天':''}</p>`:''}${r.kind==='habit'?`<p class="meta">${(r.checks||[]).length} 次用心坚持 · 今天 ${new Set((r.checks||[]).filter(c=>c.day===today()).map(c=>c.author)).size}/2 人完成</p><div class="inline-actions">${button((r.checks||[]).some(c=>c.author===state.me.user.id&&c.day===today())?'今天已打卡':'今天也一起坚持','check','small soft','check',`data-id="${r.id}"`)}</div>`:''}${r.kind==='question'?`<p class="meta">${r.answer_count===2?'两个人的答案都到齐啦':'双方回答后，才会揭晓彼此的答案'}</p>${(r.answers||[]).map(a=>`<div class="answer-box"><strong>${esc(person(a.author).name)}</strong><br>${esc(a.content)}</div>`).join('')}<div class="inline-actions">${button('写下我的答案','answer','small soft','edit',`data-id="${r.id}"`)}</div>`:''}${r.kind==='mood'?`<div class="inline-actions">${esc(b.emoji||'☀')}</div>`:''}${r.kind==='draft'?`<div class="inline-actions">${button('继续编辑','edit-record','soft small','edit',`data-id="${r.id}"`)}</div>`:''}<div class="card-footer"><span class="date-tag">${icon('clock')} ${dateLabel(r.created)}</span>${!['draft','diary','surprise'].includes(r.kind)?`<button class="${r.likes.includes(state.me.user.id)?'liked':''}" data-action="like" data-id="${r.id}">${icon('heart')} ${r.likes.length||'喜欢'}</button><button data-action="comment" data-id="${r.id}">${icon('chat')} ${r.comments.length||'回复'}</button>`:`<span>${icon('lock')} 仅自己可见</span>`}</div>${r.comments.length?`<div class="comments">${r.comments.map(c=>`<div><strong>${esc(person(c.author).name)}：</strong>${esc(c.content)}${c.author===state.me.user.id?`<button class="comment-delete" data-action="delete-comment" data-id="${c.id}">删除</button>`:''}</div>`).join('')}</div>`:''}</article>`;
}

function timelinePage() {
 const f=state.filters||{},posts=state.timelinePosts||[];
 const active=[['author','作者'],['date','日期'],['media','类型']].filter(([k])=>f[k]).length+(f.q?1:0);
 const chips=[f.q?`<span class="filter-chip">“${esc(f.q)}”</span>`:'',f.author?`<span class="filter-chip">${esc(person(f.author).name)}</span>`:'',f.date?`<span class="filter-chip">${esc(f.date)}</span>`:'',f.media?`<span class="filter-chip">${{image:'照片',video:'视频',audio:'语音'}[f.media]}</span>`:''].join('');
 return `${heading('时光慢慢，爱意满满','那些一起走过的日子，都在这里。','compose','记录此刻','edit')}<div class="filters"><input id="filter-q" placeholder="搜索我们的故事…" value="${esc(f.q||'')}" aria-label="搜索动态"><details class="filter-box" ${(['author','date','media'].some(k=>f[k]))?'open':''}><summary>${icon('calendar')} 筛选${active?`<span class="filter-chip">${active}</span>`:''}</summary><div class="filter-body">${chips}<select id="filter-author" aria-label="按作者筛选"><option value="">两个人的时光</option>${state.me.users.map(u=>`<option value="${u.id}" ${f.author===u.id?'selected':''}>${esc(u.name)}</option>`).join('')}</select><input id="filter-date" type="date" value="${esc(f.date||'')}" aria-label="按日期筛选"><select id="filter-media" aria-label="按类型筛选"><option value="">所有记录</option>${[['image','照片'],['video','视频'],['audio','语音']].map(([id,label])=>`<option value="${id}" ${f.media===id?'selected':''}>${label}</option>`).join('')}</select>${active?button('清除筛选','clear-filters','small secondary'):''}</div></details></div><div id="timeline-list">${posts.length?posts.map(recordCard).join(''):empty(f.q||active?'没有符合条件的记录':'这一页，留给新的故事',f.q||active?'换个条件，或清除筛选再试试。':'可以发照片、文字、视频，或者留下一段声音。','compose')}</div>`;
}
/* 照片格子：相册页的「按相册」和「按时间」共用一份，避免两套 markup 走偏 */
function photoGrid(list){
 return `<div class="photo-grid">${list.map(p=>`<button class="photo-item" data-action="photo" data-id="${p.id}"><img loading="lazy" src="/media/${p.id}?preview=true" alt="${esc(p.caption||p.name)}"><span>${esc(p.date||'属于我们的瞬间')}</span></button>`).join('')}</div>`;
}
/* 相册两种看法：按手工分类（原来的方式），或按月份自动归组。
   照片上传时没存 EXIF 拍摄地，「按地点」做不了真地图，所以按时间这条线做扎实：
   月份分组不依赖任何手工维护，翻老照片时最直觉。 */
function albumsPage() {
 const selected=state.album||'',view=state.albumView||'album';
 const photos=state.photos.filter(p=>!selected||state.records.find(r=>r.id===p.record_id)?.body.album===selected);
 const albums=recordsOf('album');
 const views=`<div class="tabs album-views"><button data-action="album-view" data-view="album" class="${view==='album'?'active':''}">按相册分类</button><button data-action="album-view" data-view="date" class="${view==='date'?'active':''}">按时间</button></div>`;
 const chips=view==='album'?`<div class="tabs"><button data-action="album-filter" data-id="" class="${selected?'':'active'}">全部照片 · ${state.photos.length}</button>${albums.map(a=>`<button data-action="album-filter" data-id="${a.id}" class="${selected===a.id?'active':''}">${esc(a.body.title)}</button>`).join('')}<button data-action="new-album">＋ 新建相册</button></div>`:'';
 const editRow=selected?`<div class="inline-actions" style="margin:0 0 18px">${button('编辑相册','edit-record','small secondary','edit',`data-id="${selected}"`)}${button('删除相册分类','delete-record','small secondary','trash',`data-id="${selected}"`)}</div>`:'';
 let body='';
 if(!photos.length)body=empty('每一张，都是喜欢你的证据','直接上传，或在发布动态时添加照片，都会收藏在这里。','upload-album','上传第一张照片');
 else if(view==='date'){
  const groups={};
  photos.forEach(p=>{const key=String(p.date||'').slice(0,7);groups[key]=groups[key]||[];groups[key].push(p);});
  body=Object.keys(groups).sort().reverse().map(key=>{
   const list=groups[key].slice().sort((a,b)=>String(b.date||'').localeCompare(String(a.date||'')));
   const title=key?`${key.slice(0,4)} 年 ${Number(key.slice(5))} 月`:'还没有填日期';
   return `<section class="album-group"><h3 class="album-group-head">${title}<small>${list.length} 张</small></h3>${photoGrid(list)}</section>`;
  }).join('');
 } else body=photoGrid(photos);
 return `${heading('把喜欢的瞬间，装进口袋','照片留住的不只是风景，还有身边的你。','upload-album','上传照片','photo')}${views}${chips}${editRow}${body}`;
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
/* 一起看邀请卡的两种朝向：自己发的写「点击重新发起」，对方发的写「点一下，一起看」。
   卡片自己就是整条气泡（不套 .chat-bubble），主色实底跟七套主题走。 */
/* 参考图里是实心沙发剪影，通用 icon() 是纯描边，画出来像小汽车；
   这里用几个圆角矩形直接拼：两块靠背 + 一体座垫 + 两只脚。 */
const WATCH_SOFA=`<svg class="cw-sofa" viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="7" height="6" rx="2"/><rect x="13" y="5" width="7" height="6" rx="2"/><rect x="2" y="11" width="20" height="7" rx="2.5"/><rect x="5" y="18" width="2" height="2" rx="1"/><rect x="17" y="18" width="2" height="2" rx="1"/></svg>`;
function watchInviteCard(mine,attrs=''){
 return `<button type="button" class="chat-watch-invite" data-action="chat-watch-invite" data-mine="${mine?1:0}" ${attrs} aria-label="一起看视频"><span class="cw-ico">${WATCH_SOFA}</span><span class="cw-body"><b>一起看视频</b><small>${mine?'点击重新发起':'点一下，一起看'}</small></span></button>`;
}
function chatRows(quiet) {
 /* 页内搜索只筛已加载的最近 200 条：聊天会无限增长，全量搜索得走后端，
    这里的定位是"刚聊过的东西翻不到了"，够用又不加接口。 */
 const q=(state.chatSearch||'').trim().toLowerCase();
 const all=recordsOf('chat').sort((a,b)=>a.created-b.created);
 const chats=q?all.filter(r=>!r.body.recalled&&(((r.body.content||'').toLowerCase().includes(q))||(((r.body.reply_to||{}).text||'').toLowerCase().includes(q)))):all;
 const pending=pendingChats().filter(p=>!all.some(c=>c.client_id===p.client_id));
 let lastTs=null;
 const rows=chats.map(r=>{
  const tl=chatTimeLabel(r.created,lastTs);lastTs=r.created;
  if(r.body.recalled)return `${tl?`<div class="chat-day">${tl}</div>`:''}<div class="chat-recall" id="msg-${r.id}">${r.author===state.me.user.id?'你':'对方'}撤回了一条消息</div>`;
  const mine=r.author===state.me.user.id,hasText=!!(r.body.content||'').trim(),voiceOnly=(r.media||[]).some(m=>m.mime.startsWith('audio/'))&&!hasText;
  const sticker=r.body.sticker;
  /* 引用块只存"那条的 id + 当时那句话"，点一下跳回原消息；原消息被撤回也还看得懂上下文 */
  const quote=r.body.reply_to?`<button type="button" class="chat-quote" data-action="chat-jump" data-id="${esc(r.body.reply_to.id)}"><span>${esc((r.body.reply_to.text||'原消息').slice(0,60))}</span></button>`:'';
  const ops=(mine&&Date.now()/1000-r.created<120?`<button data-action="recall-chat" data-id="${r.id}">撤回</button>`:'')
   +`<button data-action="chat-reply" data-id="${r.id}">引用</button>`
   +`<button data-action="chat-pin" data-id="${r.id}">${r.body.pinned?'取消置顶':'置顶'}</button>`
   +`<button data-action="chat-to-draft" data-id="${r.id}">记入时光</button>`;
  /* 位置消息：body.location = {lat,lng}，点开用高德 URI 打开地图（不依赖任何 KEY） */
  const loc=r.body.location&&typeof r.body.location.lat==='number'&&typeof r.body.location.lng==='number'?r.body.location:null;
  const locCard=loc?`<button type="button" class="chat-loc" data-action="chat-open-map" data-lat="${loc.lat}" data-lng="${loc.lng}" title="用高德地图打开"><span class="cl-ico">${icon('location')}</span><span class="cl-body"><b>位置</b><small>点开用高德地图看</small></span><span class="cl-go">${icon('arrow')}</span></button>`:'';
  /* 分享的歌：body.song = {title,artist,mid,src,art,dur}。mid 指向歌单里的音频媒体，
     src 是在线搜来的 30 秒试听地址（走同源 /api/music/stream 转发）。两个都有就优先本地文件。 */
  const song=r.body.song&&r.body.song.title?r.body.song:null;
  const songCard=song?songCardMarkup(song):'';
  /* 一起看邀请卡：body.watch_invite={v:1}，文案和图标全在前端按主题画。
     自己那侧点一下是「重新发起」，对方那侧点一下是「加入」，别让两边互发刷屏。 */
  const invite=r.body.watch_invite&&r.body.watch_invite.v===1;
  const inviteCard=invite?watchInviteCard(mine,`data-id="${r.id}"`):'';
  const inner=inviteCard?inviteCard:songCard?`<div class="chat-bubble song">${quote}${songCard}</div>`:locCard?`<div class="chat-bubble loc">${quote}${locCard}</div>`:sticker?`<div class="chat-sticker${sticker.endsWith('.webm')?' video':''}">${sticker.endsWith('.webm')?`<video src="${esc(sticker)}" autoplay loop muted playsinline></video>`:`<img src="${esc(sticker)}" alt="贴纸" loading="lazy">`}</div>`:`<div class="chat-bubble${voiceOnly?' voice':''}${r.body.pinned?' pinned':''}">${quote}<span style="white-space:pre-wrap">${esc(r.body.content)}</span>${mediaMarkup(r.media)}</div>`;
  return `${tl?`<div class="chat-day">${tl}</div>`:''}<div class="chat-line ${mine?'mine':''}" id="msg-${r.id}">${avatar(r.author)}<div>${inner}${ops?`<div class="chat-time">${ops}</div>`:''}</div></div>`;
 }).join('');
 const pend=pending.map(p=>`<div class="chat-line mine pending">${avatar(state.me.user.id)}<div>${p.body.watch_invite?watchInviteCard(true):`<div class="chat-bubble">${esc(p.body.content||'一个附件')}</div>`}<div class="chat-time">尚未发送 <button data-action="retry-chat" data-id="${p.client_id}">点击重试</button></div></div></div>`).join('');
 if(q&&!chats.length)return `<div class="chat-no-match">最近 200 条里没有「${esc(state.chatSearch)}」，试试清掉筛选。</div>`;
 return rows+pend||(quiet
  ?`<p class="watch-chat-empty">${icon('chat')}<span>边看边聊，想说什么就说</span></p>`
  :empty('今天，有什么想对 TA 说？','说说日常，也说说想念。'));
}
/* 聊天列表的增量重绘：按 id 原地对账，只动真正变了的行。
   以前每个刷新点都写 `log.innerHTML = chatRows()`，整段重建会把每一行的
   <img>/<video> 一起销毁重造——200 条消息里的图全部重新解码、正在循环的贴纸
   从头播、滚动位置也跟着跳，附件还要全部重新走一遍网络。
   这里按 id 对账：内容没变的行一个节点都不碰（位置也对得上就 continue），
   只有真的变了才插入新节点。**不要**改成"先摘进 frag 再整体塞回"——
   <video> 被摘下再挂回会重新解析 poster，等于白拿一次网络请求。 */
function chatRowKey(node) {
 if (node.id && node.id.indexOf('msg-') === 0) return node.id;
 if (node.classList && node.classList.contains('chat-day')) return 'day:' + node.textContent;
 return null; /* 「尚未发送」这类临时行没有稳定 id：直接重建，它不含图片，代价可忽略 */
}
function paintChat(log, quiet) {
 if (!log) return;
 /* 必须用 <template> 解析，不能用游离的 <div>：div 里解析出来的 <video poster="…">
    会立刻开始预取封面、<img> 也会开始下载——每重绘一次就凭空多出一整屏媒体请求
    （实测 8 个视频 = 8 次 /media?poster=true）。template.content 是惰性的，
    解析完一个请求都不发，节点搬进文档才激活。 */
 const tpl = document.createElement('template');
 tpl.innerHTML = chatRows(quiet);
 const prev = new Map();
 for (const node of Array.prototype.slice.call(log.children)) {
  const k = chatRowKey(node);
  if (k && !prev.has(k)) prev.set(k, node);
 }
 const want = [];
 for (const node of Array.prototype.slice.call(tpl.content.children)) {
  const k = chatRowKey(node);
  const old = k && prev.get(k);
  if (old && old.outerHTML === node.outerHTML) { prev.delete(k); want.push(old); }
  else want.push(node);
 }
 /* 逐个就位：已经在正确位置的行直接跳过（不摘不挂，附件不重新请求） */
 for (let i = 0; i < want.length; i++) {
  if (log.children[i] === want[i]) continue;
  log.insertBefore(want[i], log.children[i] || null);
 }
 /* 多出来的行（撤回、搜索过滤后消失）从尾部删掉 */
 while (log.children.length > want.length) log.removeChild(log.lastChild);
}
/* 聊天壁纸：预设用 CSS 渐变/纹理，'photo' 用自己上传的照片。
   dim 是压在图上的遮罩强度（百分比）——它存在的意义只有一个：保证气泡文字在任何底图上都读得清。
   壁纸写在 space 设置里（/api/space → db.setting('space')），所以是**两个人共用一份**：
   谁改都对双方同时生效，不需要各设各的。 */
const CHAT_BG_PRESETS=[['','默认'],['sakura','樱粉'],['cream','奶油'],['mint','薄荷'],['stars','星光'],['night','夜幕'],['photo','用照片']];
/* 聊天背景是**每人一份**的（space.chat_bg_users[用户 id]），谁都能替对方设；
   自己没单独设过时才退回空间级的共同默认值。所以两边可以各看各的背景图。 */
function chatBgOf(uid){
 const s=state.me?.space||{};
 return (s.chat_bg_users||{})[uid] || {bg:s.chat_bg||'', media:s.chat_bg_media||'', dim:s.chat_bg_dim??35};
}
function myChatBg(){return chatBgOf(state.me?.user?.id);}
function wallpaperDim(){return Math.min(80,Math.max(0,Number(myChatBg().dim)||0));}
/* 只有真照片才进"沉浸式"：气泡/标题栏/输入栏换成半透明深色，让照片透出来。
   预设渐变本来就是浅色的，套深色气泡反而突兀，所以保持原来的浅色排版。 */
function chatBgIsPhoto(){const b=myChatBg();return b.bg==='photo'&&!!b.media;}
/* 壁纸层挂在 .chat-panel 上而不是消息区内部：这样背景是**整屏**的，标题栏和输入栏
   也压在图上（像聊天 App 那样），而不是只铺消息列表那块。 */
function chatWallpaper(){
 const bg=myChatBg().bg||'';
 if(!bg)return '';
 const style=`--chat-bg-dim:${wallpaperDim()/100}`;
 return bg==='photo'
  ? `<div class="chat-wallpaper photo" id="chat-wallpaper" aria-hidden="true" style="${style}"></div>`
  : `<div class="chat-wallpaper" id="chat-wallpaper" data-bg="${esc(bg)}" aria-hidden="true" style="${style}"></div>`;
}

/* ── 背景照片本地缓存 ──
   /media/ 是 no-store（私密媒体不该留在任何共享缓存里），后果是每次进聊天都要重新下载
   背景图，App 上尤其明显。这里按 media id 把图片 Blob 存进 IndexedDB：
   id 没变 → 直接用本地副本，一次网络请求都不发；换图后 id 变 → 新 key 重新下载，旧副本自动清掉。
   IndexedDB 不可用（隐私模式 / 老 WebView）时静默降级为每次联网。 */
const BG_DB='love-space-bg',BG_STORE='wallpaper';
let bgObjectUrl='';
function bgIDB(){
 return new Promise((resolve,reject)=>{
  if(!window.indexedDB)return reject(new Error('no indexedDB'));
  const req=indexedDB.open(BG_DB,1);
  req.onupgradeneeded=()=>{const db=req.result;if(!db.objectStoreNames.contains(BG_STORE))db.createObjectStore(BG_STORE);};
  req.onsuccess=()=>resolve(req.result);
  req.onerror=()=>reject(req.error||new Error('open failed'));
 });
}
async function bgCacheRead(key){
 try{
  const db=await bgIDB();
  return await new Promise((res,rej)=>{const rq=db.transaction(BG_STORE,'readonly').objectStore(BG_STORE).get(key);rq.onsuccess=()=>res(rq.result||null);rq.onerror=()=>rej(rq.error);});
 }catch{return null;}
}
async function bgCacheWrite(key,blob){
 try{
  const db=await bgIDB();
  await new Promise((res,rej)=>{const tx=db.transaction(BG_STORE,'readwrite');tx.objectStore(BG_STORE).put(blob,key);tx.oncomplete=res;tx.onerror=()=>rej(tx.error);});
 }catch{}
}
/* 只留当前这张：换了背景，旧图不该继续占着本地空间 */
async function bgCacheTrim(keep){
 try{
  const db=await bgIDB();
  await new Promise(res=>{
   const tx=db.transaction(BG_STORE,'readwrite'),store=tx.objectStore(BG_STORE),rq=store.getAllKeys();
   rq.onsuccess=()=>{(rq.result||[]).forEach(k=>{if(k!==keep)store.delete(k);});};
   tx.oncomplete=res;tx.onerror=res;
  });
 }catch{}
}
function paintWallpaper(layer,blob){
 if(bgObjectUrl){URL.revokeObjectURL(bgObjectUrl);bgObjectUrl='';}
 bgObjectUrl=URL.createObjectURL(blob);
 layer.style.backgroundImage=`url("${bgObjectUrl}")`;
 layer.dataset.ready='1';
}
async function applyWallpaper(){
 // body 上的 chat-immersive 是布局用的（原生 App 里决定聊天气泡页要不要铺到状态栏后面），
 // 在这里同步一份：换背景不必等整页重渲染，下次进聊天页也一定是对的。
 document.body.classList.toggle('chat-immersive', chatBgIsPhoto());
 const layer=$('#chat-wallpaper');
 if(!layer)return;
 if(!chatBgIsPhoto()){layer.dataset.ready='';bgCacheTrim('');return;}
 const mid=myChatBg().media,key='bg:'+mid;
 const cached=await bgCacheRead(key);
 if(cached&&cached.size){paintWallpaper(layer,cached);bgCacheTrim(key);return;}
 try{
  const res=await fetch(`/media/${mid}?preview=true`,{credentials:'same-origin'});
  if(!res.ok)return;
  const blob=await res.blob();
  if(!blob.size)return;
  paintWallpaper(layer,blob);
  await bgCacheWrite(key,blob);
  bgCacheTrim(key);
 }catch{/* 离线或失败：这次就没背景图，下次进来再试 */}
}

/* ── 聊天气泡皮肤 ────────────────────────────────────────────────────
   素材是 128×112 的整图（四角带装饰），前端用 CSS border-image 切九宫格拉伸，
   所以图不裁不切，原样引用即可。自己的消息用服务器预先水平翻转过的 -r.png：
   微信气泡的尖角和装饰都在左下角（对方那一侧），镜像之后才落在靠外的那边。
   皮肤存在 space 设置里（两个人共用一份），字色单独存一个字段——图有深有浅，
   白字深字没法自动判断。 */
function chatSkin(){
 const v=state.me?.space?.chat_bubble;
 return typeof v==='string'?v:'';
}
function chatSkinFg(){return (state.me?.space?.chat_bubble_fg||'dark')==='light'?'light':'dark';}
/* 皮肤素材是网上收的整图，"装饰/尾巴"画在左边还是右边看作作者，三个包也不统一。
   所以给一个左右互换开关；库里没这个键的老空间按"对调"起步——
   素材多数画成了右侧样式，原图给"我"那侧才顺眼。 */
function chatSkinSwap(){return state.me?.space?.chat_bubble_swap!==false;}
function chatSkinAttrs(){
 const skin=chatSkin();
 if(!skin)return {cls:'',style:''};
 const mirror=skin.replace(/\.png$/,'-r.png');
 /* CSS 里 --skin 是左侧（对方）、--skin-r 是右侧（我）。
     互换时把两张图对调即可，不用另生成素材。 */
 const swap=chatSkinSwap(), left=swap?mirror:skin, right=swap?skin:mirror;
 return {cls:' skin-on'+(chatSkinFg()==='light'?' skin-light':''),
         style:` style="--skin:url('/api/bubbles/${esc(left)}');--skin-r:url('/api/bubbles/${esc(right)}')"`};
}

function messagesPage() {
 const partner=state.me.users.find(u=>u.id!==state.me.user.id);
 const immersive=chatBgIsPhoto(),bgOn=!!myChatBg().bg,skinAttrs=chatSkinAttrs();
 /* 置顶条只显示最新的一条，点开跳过去；多条时给个总数，不挤占聊天区 */
 const pinned=recordsOf('chat').filter(r=>r.body.pinned&&!r.body.recalled).sort((a,b)=>b.created-a.created);
 const pinnedBar=pinned.length?`<button type="button" class="chat-pinned" data-action="chat-jump" data-id="${pinned[0].id}"><span class="cp-tag">📌 置顶</span><span class="cp-text">${esc((pinned[0].body.content||'一条附件').slice(0,42))}</span>${pinned.length>1?`<i>共 ${pinned.length} 条</i>`:''}</button>`:'';
 const searchBar=state.chatSearch?`<div class="chat-search-bar"><span>筛选「${esc(state.chatSearch)}」</span><button type="button" data-action="chat-search-clear">清除</button></div>`:'';
 const replyBar=state.chatReply?`<div class="chat-reply-bar"><i class="crb-mark" aria-hidden="true">↩</i><span>引用：${esc(state.chatReply.text||'一条消息')}</span><button type="button" class="icon-btn" data-action="chat-reply-cancel" aria-label="取消引用">${icon('close')}</button></div>`:'';
 /* ── 输入栏：中间胶囊输入框，右侧语音 / 表情 / 更多 ──────────
    有文字时语音按钮让位给发送按钮（form.has-text 控制）。 */
 const composeBar=`<form id="chat-form" class="chat-compose">
  <div class="compose-field"><textarea id="chat-text" name="content" placeholder="发消息" rows="1" maxlength="20000" aria-label="聊天内容" autocomplete="off" enterkeyhint="send"></textarea></div>
  <button type="button" class="compose-ib compose-mic" data-action="chat-voice" aria-label="发语音" title="发语音">${icon('mic')}</button>
  <button type="button" class="compose-ib compose-emoji" data-action="sticker-panel" aria-label="表情" title="表情">${icon('smile')}</button>
  <button type="button" class="compose-ib compose-plus" data-action="chat-fn" aria-label="更多" title="更多">${icon('plus')}</button>
  <button class="compose-send" type="submit" aria-label="发送消息" title="发送">${icon('send')}</button>
 </form>`;
 /* 面板只有网格：上方输入栏已经有一模一样的语音/表情/关闭，再加一行头就是重复。
     点 ⊕ 再点一次即可收起，选完任一项也会自动收起。 */
 const fnPanel=`<div id="chat-fn" class="fn-panel" hidden>
  <div class="fn-grid">
   <button type="button" class="fn-tile" data-action="chat-pick" data-id="media"><span class="fn-ico">${icon('image')}</span><b>相册</b></button>
   <button type="button" class="fn-tile" data-action="chat-pick" data-id="camera"><span class="fn-ico">${icon('camera')}</span><b>拍摄</b></button>
   <button type="button" class="fn-tile" data-action="chat-call"><span class="fn-ico">${icon('phone')}</span><b>发起通话</b></button>
   <button type="button" class="fn-tile" data-action="chat-watch"><span class="fn-ico">${icon('film')}</span><b>一起看</b></button>
   <button type="button" class="fn-tile" data-action="chat-locate"><span class="fn-ico">${icon('location')}</span><b>位置</b></button>
   <button type="button" class="fn-tile" data-action="chat-song"><span class="fn-ico">${icon('music')}</span><b>音乐</b></button>
  </div>
 </div>`;
 return `<section class="chat-panel${bgOn?' has-wallpaper':''}${immersive?' immersive':''}${skinAttrs.cls}"${skinAttrs.style}>${chatWallpaper()}<header class="chat-header"><button class="icon-btn" data-action="chat-back" aria-label="返回">${icon('back')}</button>${partner?avatar(partner.id):'<span class="avatar">♡</span>'}<div><h3>${partner?esc(partner.name):'等待另一半加入'}</h3><small>我们的悄悄话 · 仅彼此可见</small></div><button class="icon-btn" data-action="chat-search" aria-label="搜索消息" title="搜索消息" style="margin-left:auto">${icon('search')}</button><button class="icon-btn" data-action="chat-bg" aria-label="聊天背景" title="聊天背景">${icon('photo')}</button><button class="icon-btn" data-nav="imports" aria-label="聊天记录">${icon('book')}</button></header><div class="chat-body">${pinnedBar}${searchBar}<div id="chat-log" class="chat-log" aria-live="polite">${chatRows()}</div></div><div id="sticker-dock" class="sticker-dock" hidden></div>${replyBar}${composeBar}${fnPanel}<input id="chat-file" type="file" accept="image/*,video/*" multiple hidden><input id="chat-shot" type="file" accept="image/*" capture="environment" hidden></section>`;
}
function scrollChat(){const log=$('#chat-log');if(log)log.scrollTop=log.scrollHeight;}

/* ── 一起看（竖屏上下分屏，带进度同步）────────────────────────
   上半放映区、下半聊天区。

   同步只传「时间轴」，不传画面。之所以能这样，是因为片源来自服务器媒体
   `/media/<id>`：两个人拿到的是同一个文件，时长一致，对齐才有意义。
   （选本机文件也留着，但那只是"各自打开同一部片"，客户端无法验证是不是同一部。）

   · 同步是**事件触发**的，不是实时轮询：只有「用户主动做了」才上报 ——
     拖进度条、点播放/暂停、选片/切集/换组件。播放过程中一个字节都不发，
     对方那侧也没有轮询在跑（以前每 2.5 秒拉一次 /api/watch，手机上很费电费流量）。
   · 对方靠 SSE 收到「一起看状态变了」的信号，才来拉一次 `/api/watch`；
     服务端按 updated 把 position 往后推算，所以拉到的就是当下的进度。
   · 程序性动作（换源、跟对方对齐）不会当成用户操作推回去，
     否则两边会对着推、形成死循环。
   · 代价：不再有持续的进度校正，长时间播放两边会慢慢漂移；
     状态带上留了「对齐」按钮，拖一下进度条或点一下就能拉齐。
   · 首次进页面只定位不自动出声 —— 浏览器禁止无手势自动播放，强行 play 会被拦；
     昨天看到一半的进度今天进来自动响起来也不合适，所以给一个「点一下继续」。 */
let watchObjectUrl=null, watchTimer=null, watchLastUpdated=0, watchApplying=false, watchFirstPoll=true;
/* 上报闸门：把「用户主动做的」和「程序自己做的」分开。
   watchMuteUntil —— 程序性动作的静音窗口（换源、跟对方对齐）；
   watchSeekTarget —— 程序性 seek 的目标位置，用来精确识别"这次 seek 不是用户拖的"；
   watchExpectKey —— 本端刚选的片源，等它挂上期间别被自己触发的同步事件重复换源。 */
let watchMuteUntil=0, watchSeekTarget=null, watchPushTimer=null, watchPushPending=false, watchExpectKey='';
function watchMute(ms){watchMuteUntil=Math.max(watchMuteUntil,Date.now()+(ms||1000));}
function watchMuted(){return Date.now()<watchMuteUntil;}

function watchVideo(){return $('#watch-video');}
/* hls.js 挂在 video 上时元素本身没有 src 属性（画面走 MSE 的 blob），
   光看 getAttribute('src') 会误判成「没有片源」，播放状态也就不上报了。 */
let watchHls=null,watchLoadingSrc=false,watchSrcSeq=0;
function watchHasSrc(){
 const v=watchVideo();
 return !!(v&&(v.getAttribute('src')||watchHls||watchLoadingSrc));
}
function watchDestroyHls(){
 if(watchHls){try{watchHls.destroy();}catch{}watchHls=null;}
}
/* HLS 片源：能跑 MSE 的内核交给 hls.js；Safari 这类原生就认 m3u8 的，
   直接把改写后的播放列表塞给 <video>。老内核两种都不支持的会给明确提示。 */
function watchMountHls(v,url){
 watchDestroyHls();
 if(typeof Hls==='undefined'||!Hls.isSupported()){v.src=url;return;}
 const hls=new Hls({enableWorker:false,maxBufferLength:15,backBufferLength:15});
 watchHls=hls;
 hls.on(Hls.Events.MEDIA_ATTACHED,()=>hls.loadSource(url));
 hls.on(Hls.Events.ERROR,(evt,data)=>{
  if(!data||!data.fatal)return;
  toast(data.type===Hls.ErrorTypes.NETWORK_ERROR
   ?'片源网络出错，换个组件或重新选一次集'
   :'这个片源当前浏览器播不了，换个组件看看');
 });
 hls.attachMedia(v);
}

function watchPage(){
 const chats=chatRows(true);
 return `<section class="watch-page">
  <header class="watch-head">
   <button class="icon-btn" data-action="watch-back" aria-label="返回聊天">${icon('back')}</button>
   <div><h3>一起看</h3><small id="watch-sub">边看边聊 · 选一部一起看</small></div>
   <button class="button soft small" data-action="watch-pick">${icon('film')} 选片源</button>
  </header>
  <div class="watch-stage" id="watch-stage">
   <video id="watch-video" class="watch-video" playsinline controls hidden></video>
   <div class="watch-empty" id="watch-empty">
    <div class="we-art"><span class="we-ring"></span><span class="we-icon">${icon('film')}</span></div>
    <b id="watch-empty-title">还没有片源</b>
    <small id="watch-empty-hint">从相册里挑一段视频，两个人看的是同一个文件，进度自动对齐</small>
    <button class="button primary small" data-action="watch-pick">从相册选视频</button>
    <div class="we-tips"><span>进度自动对齐</span><span>随时换片</span></div>
   </div>
   <button type="button" class="watch-join" id="watch-join" data-action="watch-join" hidden>点一下继续播放</button>
  </div>
  <div class="watch-chat">
   <div class="watch-now" id="watch-now" hidden></div>
   <div class="watch-log" id="watch-log" aria-live="polite">${chats}</div>
   <form id="watch-form" class="chat-compose">
    <div class="compose-field"><textarea id="watch-text" rows="1" maxlength="20000" placeholder="边看边说" aria-label="聊天内容" autocomplete="off" enterkeyhint="send"></textarea></div>
    <button class="compose-send" type="submit" aria-label="发送消息">${icon('send')}</button>
   </form>
   <input id="watch-file" type="file" accept="video/*" hidden>
  </div>
 </section>`;
}
function watchScroll(){const log=$('#watch-log');if(log)log.scrollTop=log.scrollHeight;}

/* 把状态画到头部副标题和空状态上。片源没挂上时，这里就是唯一告诉
   "TA 选了哪部" 的地方，否则对方只会看到一句"还没有片源"。 */
/* 相册导出的文件名常常就是一串数字（1000028599.mp4），直接当片名摆出来既难看、
   也分不清是哪一段，一律改成中性叫法 —— 列表里靠下面的日期区分。 */
function watchName(raw){
 const n=String(raw||'').replace(/\.[^.]+$/,'').trim();
 return /^[\d\s._-]*$/.test(n)?'':n;
}

function watchRenderStatus(st){
 st=st||{};
 const sub=$('#watch-sub'), t=$('#watch-empty-title'), h=$('#watch-empty-hint');
 /* 短剧的 title 只存剧名，集数单独存；展示时拼成「剧名 · 第N集」 */
 const name=(watchName(st.title)||'一段视频')+(st.drama_id&&st.drama_ep?` · 第${st.drama_ep}集`:'');
 if(sub){
  sub.textContent=st.title?`${st.playing?'一起看着':'暂停中'} · ${name}`:'边看边聊 · 选一部一起看';
  sub.classList.toggle('live',!!(st.title&&st.playing));
 }
 /* 播放区和聊天区之间给一条「正在看」的状态带：有片源时两栏不再靠一条细线硬切，
    也能一眼看到对方是播着还是暂停了。内容不变就不重绘，避免 2.5s 轮询闪一下。 */
 const now=$('#watch-now');
 if(now){
  const label=st.title?`${watchName(st.title)||'一段视频'}${st.drama_id&&st.drama_ep?` · 第${st.drama_ep}集`:''}`:'';
  /* 状态带：不再有持续的进度校正，所以文案不说"进度自动对齐"。
     对方在操作时给一个「对齐」按钮 —— 长时间播放会慢慢漂移，点一下就拉齐。 */
  const mine=!st.by||st.by===state.me.user.id;
  const tip=st.playing?(mine?'正在看 · 你一操作就同步给 TA':'TA 在看 · 你一操作就跟上')
                      :'暂停中，点播放就能一起继续';
  const html=label?`<span class="wn-badge${st.playing?' live':''}">${icon('film')}</span>
   <span class="wn-text"><b>${esc(label)}</b><small>${tip}</small></span>
   ${(!mine&&label)?`<button type="button" class="wn-sync" data-action="watch-align" title="把进度拉到 TA 的位置">${icon('arrow')}对齐</button>`:''}
   <span class="wn-tag">${st.playing?'在播':'已暂停'}</span>`:'';
  if(now.innerHTML!==html)now.innerHTML=html;
  now.hidden=!label;
 }
 if(t&&!watchHasSrc()){
  const mine=st.by===state.me.user.id;
  t.textContent=st.title?`${mine?'你':(st.by?person(st.by).name:'TA')}选了《${name}》`:'还没有片源';
  h.textContent=st.title?'片源已经就位，点播放就能一起开始':'从相册里挑一段视频，两个人看的是同一个文件，进度自动对齐';
 }
}

/* 片源有三种：相册媒体、在线片源某一集、本机文件。srcKey 记「当前挂的是哪一版」，
   轮询时比对它就能发现对方换了片或换了集，不用去 string 比 src（在线片源的地址每次都带新签名）。
   在线片源还分 mp4 / HLS：先问后端这一集是什么格式，再决定用 <video> 还是 hls.js。 */
async function watchSetSource(opts){
 const v=watchVideo();if(!v)return;
 const seq=++watchSrcSeq;
 /* 换源会触发 emptied/pause/loadedmetadata 一串事件，还会把 currentTime 归零。
    静音这一小段时间，别把「换片」误报成「TA 暂停了」或者「进度归零了」。 */
 watchMute(1400);
 /* 换源会触发 emptied/pause，别让这些事件把「暂停了」的假状态推给对方 */
 watchLoadingSrc=true;
 try{
  watchDestroyHls();
  if(watchObjectUrl){URL.revokeObjectURL(watchObjectUrl);watchObjectUrl=null;}
  v.removeAttribute('src');v.load();   // readyState 归零，轮询挂的 loadedmetadata 才会命中新源
  v.hidden=false;
  const empty=$('#watch-empty');if(empty)empty.hidden=true;
  if(opts.media){
   v.dataset.srcKey='m:'+opts.media;
   v.src='/media/'+opts.media;
  }else if(opts.drama){
   const d=opts.drama;
   const key=`d:${d.src}:${d.prov}:${d.id}:${d.ep}`;
   v.dataset.srcKey=key;
   const path=`/dramas/${encodeURIComponent(d.src)}/${encodeURIComponent(d.prov)}/`+
              `${encodeURIComponent(d.id)}`;
   const url=`/api${path}/stream/${d.ep}`;
   let type='mp4';
   try{
    const info=await api(`${path}/source/${d.ep}`);
    type=(info&&info.type)||'mp4';
   }catch(e){toast(e.message||'这一集暂时打不开');}
   /* 等探测这会儿里对方可能又换了片，别把旧结果挂到新 srcKey 上 */
   const cur=watchVideo();
   if(!cur||cur.dataset.srcKey!==key||seq!==watchSrcSeq)return;
   if(type==='hls')watchMountHls(cur,url);else cur.src=url;
  }else{
   v.dataset.srcKey='local';
   watchObjectUrl=URL.createObjectURL(opts.file);
   v.src=watchObjectUrl;
  }
  watchFitStage();
 }finally{
  setTimeout(()=>{if(seq===watchSrcSeq)watchLoadingSrc=false;},60);
 }
}

/* 播放区高度跟着视频自身比例走。固定五五分屏时，横屏片子在 48% 高的框里用 contain
   缩放，上下会各留一整条黑边，看着像播放器没加载好。这里按 videoWidth/videoHeight
   算出真实高度，只保留一条上限：别让长片把下面的聊天区挤没。
   横过来拿手机时走左右分栏（见 style.css），高度由 flex 撑满，不再写死。 */
const WATCH_SIDE_BY_SIDE='(orientation:landscape) and (max-height:560px)';
function watchFitStage(){
 const v=watchVideo(),st=$('#watch-stage');if(!st)return;
 const w=st.clientWidth;
 const vw=v&&v.videoWidth,vh=v&&v.videoHeight;
 /* 没片源或元数据还没到：清掉内联高度，交回 CSS 的默认分屏 */
 if(!w||!vw||!vh){st.style.height='';return;}
 if(window.matchMedia&&window.matchMedia(WATCH_SIDE_BY_SIDE).matches){st.style.height='';return;}
 const box=$('#page');
 const pageH=(box&&box.clientHeight)||window.innerHeight;
 const h=Math.round(w*vh/vw);
 /* 竖屏片子（短剧基本都是 9:16）按 62% 卡会左右各留一大条黑边，
     放宽到「只给聊天区留 240」；横屏片子照旧 62%，够看又不挤聊天。 */
 const portrait=vh>vw;
 const limit=portrait?Math.max(Math.round(pageH*0.62),pageH-240):Math.round(pageH*0.62);
 st.style.height=Math.max(96,Math.min(h,limit))+'px';
}

async function watchPush(){
 const v=watchVideo();
 if(!v||(!v.getAttribute('src')&&!watchHls)||watchLoadingSrc)return;
 const body={position:v.currentTime,playing:!v.paused};
 if(Number.isFinite(v.duration))body.duration=v.duration;
 try{
  const cur=await api('/watch',{method:'PUT',body:JSON.stringify(body)});
  state.watch=cur;watchLastUpdated=Number(cur.updated)||0;
  watchRenderStatus(cur);
 }catch{}
}

/* 唯一的上报入口：只有「用户主动做了」才允许推给对方。
   reason='play' | 'pause' | 'seek'。
   两道闸门：
     ① watchMuted() —— 程序性动作的静音窗口（换源、跟对方对齐）；
     ② watchSeekTarget —— 程序性 seek 的目标位置；命中就说明这次 seek 不是用户拖的。
   拖进度条时浏览器可能连着抛好几次 seeked，400ms 内合并成一条，别把请求刷成一片。 */
function watchReport(reason){
 if(watchApplying||watchMuted())return;
 if(reason==='seek'&&watchSeekTarget!=null){
  const v=watchVideo();
  const same=v&&Math.abs((Number(v.currentTime)||0)-watchSeekTarget)<0.4;
  watchSeekTarget=null;
  if(same)return;
 }
 if(watchPushTimer){watchPushPending=true;return;}
 watchPush();
 watchPushTimer=setTimeout(()=>{
  watchPushTimer=null;
  if(watchPushPending){watchPushPending=false;watchPush();}
 },400);
}

function watchBindVideo(){
 const v=watchVideo();if(!v)return;
 /* 用属性赋值而不是 addEventListener：整块 DOM 每次换页都会重画，
    属性赋值天然覆盖上一次的绑定，不会越绑越多。 */
 v.onplay=()=>watchReport('play');
 v.onpause=()=>watchReport('pause');
 v.onseeked=()=>watchReport('seek');
 /* 短剧一集只有两三分钟，播完自己接下一集，不用每次都回去点 */
 v.onended=()=>{if(!watchApplying)watchNextEpisode();};
 /* 元数据到手才知道片子的实际比例，这时再定高度 */
 v.onloadedmetadata=()=>watchFitStage();
}

function showWatchJoin(){const b=$('#watch-join');if(b)b.hidden=false;}
function hideWatchJoin(){const b=$('#watch-join');if(b)b.hidden=true;}

function watchJoin(){
 const v=watchVideo();if(!v)return;
 hideWatchJoin();
 v.play().catch(()=>showWatchJoin());
}

/* 拉一次服务端状态并对齐过来。
   触发时机只有四种：① 进入页面 ② SSE 通知「一起看状态变了」
   ③ 低频兜底轮询 ④ 手动点「对齐」。没有事件的时候一个请求都不发。
   force=true 时不看 updated，硬对齐一次（手动对齐按钮用）。 */
async function watchPull(force){
 if(state.page!=='watch'){stopWatchSync();return;}
 let st;try{st=await api('/watch');}catch{return;}
 state.watch=st;
 watchRenderStatus(st);
 const v=watchVideo();if(!v)return;
 /* 对方换了片（或换了一集/换了个组件）就跟过去；本机文件是我自己选的，服务端没有 media,
    这时 want 为空，保持原样别把本地视频顶掉。
    want===watchExpectKey：本端刚点的片还在挂载途中，别被自己触发的同步再换一次源。 */
 const want=st.drama_id
  ?`d:${st.drama_src||''}:${st.drama_provider||''}:${st.drama_id}:${st.drama_ep||1}`
  :(st.media?`m:${st.media}`:'');
 if(want&&v.dataset.srcKey!==want&&want!==watchExpectKey){
  /* 提前压住回写：换源会清空 video，那串 emptied/pause 不该被当成「TA 暂停了」 */
  watchApplying=true;watchMute(1600);
  if(st.drama_id)watchSetSource({drama:{src:st.drama_src,prov:st.drama_provider,
   id:st.drama_id,ep:st.drama_ep||1}});
  else watchSetSource({media:st.media});
  /* 换源后这一轮就到此为止：位置按服务端的来，再从下一条快照开始正常同步，
     否则同一个 updated 会被应用两次、跟当前这次 seek 打架。 */
  watchLastUpdated=Number(st.updated)||0;
  const seek=()=>{try{v.currentTime=Math.max(0,Number(st.position)||0);}catch{}};
  if(v.readyState>=1)seek();else v.addEventListener('loadedmetadata',seek,{once:true});
  setTimeout(()=>{watchApplying=false;},800);
  if(st.playing)v.play().then(hideWatchJoin).catch(()=>showWatchJoin());
  return;
 }
 if(!watchHasSrc())return;

 const upd=Number(st.updated)||0;
 const pos=Math.max(0,Number(st.position)||0);

 if(watchFirstPoll){
  watchFirstPoll=false;watchLastUpdated=upd;
  if(pos>0.5){watchApplying=true;watchSeekTarget=pos;watchMute(900);
   try{v.currentTime=pos;}catch{}setTimeout(()=>{watchApplying=false;},800);}
  if(st.playing)showWatchJoin();
  return;
 }
 if(!force&&upd<=watchLastUpdated)return;
 watchLastUpdated=upd;
 if(st.by===state.me.user.id)return;   // 自己刚上报的快照，别自己跟自己
 watchApplying=true;watchMute(900);
 try{
  /* 播放中容忍 1.5 秒：频繁 seek 会打断解码，画面一顿一顿的，而人对 1.5 秒内的
     不同步几乎无感。暂停时就该停在同一帧，收紧到 0.5 秒 —— 这时候 seek 没有卡顿成本。 */
  const tol=st.playing?1.5:0.5;
  if(Math.abs(v.currentTime-pos)>tol){watchSeekTarget=pos;try{v.currentTime=pos;}catch{}}
  if(st.playing&&v.paused){try{await v.play();hideWatchJoin();}catch{showWatchJoin();}}
  else if(!st.playing&&!v.paused)v.pause();
 }finally{
  setTimeout(()=>{watchApplying=false;},800);
 }
}

function startWatchSync(){
 stopWatchSync();
 if(state.page!=='watch')return;
 watchFirstPoll=true;
 watchExpectKey='';
 watchBindVideo();
 watchRenderStatus(state.watch||{});
 watchPull();
 /* 兜底轮询：以前每 2.5 秒拉一次（实时同步），现在降到 15 秒，只负责在
    SSE 断线或事件漏了的时候把状态收敛回来。同步主通道是 SSE 的状态变更事件，
    没有事件时这一条也不会白发。 */
 watchTimer=setInterval(()=>watchPull(),15000);
 window.addEventListener('resize',watchFitStage);
 window.addEventListener('orientationchange',watchFitStage);
}
function stopWatchSync(){
 /* 离开「一起看」后整块 DOM 会被替换，但 hls.js 还 attach 在旧 <video> 的 JS 引用上，
    不 destroy 就会在后台继续拉分片烧流量（最多等下一轮轮询走到这里）。 */
 if(state.page!=='watch')watchDestroyHls();
 if(watchTimer){clearInterval(watchTimer);watchTimer=null;}
 window.removeEventListener('resize',watchFitStage);
 window.removeEventListener('orientationchange',watchFitStage);
}

/* 选片源：相册视频（同源，能真同步）/ 在线片源（走本站代理）/ 本机文件（退路）。
   在线片源是「服务 + 组件」两级：服务是 happy-capy 这类组件聚合器的地址，主人自己加；
   组件是那台服务代理的内容源，主人自己勾。前端只认「服务/组件/内容 id/集号」——
   直链带签名、二十来小时就过期，交给服务端每次现换。 */
/* 在线片源分四层：sources=组件卡列表（在线片源主页）/ home=某个组件按分类分区的
   片库 / list=某分类的完整海报墙 / detail=选集页。album tab 不走 view。 */
const WATCH_PICK={tab:'album',view:'sources',svc:'',prov:'',cat:'',page:1,q:'',
 videos:[],dramas:[],detail:null,catalog:null,openSvc:'',loading:false,error:'',
 home:{rows:[],loading:false,error:''},recent:[]};

/* 已启用的组件，摊平成一维，方便做切换条 */
function watchGroups(){
 const out=[];
 ((WATCH_PICK.catalog||{}).services||[]).forEach(s=>{
  (s.providers||[]).forEach(p=>{if(p.enabled)out.push({
   svc:s.id,svcName:s.name,prov:p.id,title:p.title,cats:p.categories||[],online:s.online,error:s.error||''});});
 });
 return out;
}

function watchGroup(){
 /* 组件卡列表里没勾过的源也能点进去看（进去时会自动勾上），所以这里从
    「全部组件」里按当前 svc/prov 找，别只在已启用列表里找，否则会串到别的组件。 */
 const services=((WATCH_PICK.catalog||{}).services)||[];
 let hit=null;
 services.forEach(s=>(s.providers||[]).forEach(p=>{
  if(s.id===WATCH_PICK.svc&&p.id===WATCH_PICK.prov)hit={
   svc:s.id,svcName:s.name,prov:p.id,title:p.title,cats:p.categories||[],
   online:s.online,error:s.error||''};
 }));
 if(hit)return hit;
 return watchGroups()[0]||null;
}

function watchEnabledKeys(){
 const out=[];
 ((WATCH_PICK.catalog||{}).services||[]).forEach(s=>
  (s.providers||[]).forEach(p=>{if(p.enabled)out.push(s.id+':'+p.id);}));
 return out;
}

async function watchCatalog(refresh){
 try{return await api('/drama-sources'+(refresh?'?refresh=1':''));}catch{return null;}
}

async function watchPick(){
 const p=WATCH_PICK;
 p.tab='album';p.view='sources';p.page=1;p.q='';p.cat='';p.detail=null;
 p.svc='';p.prov='';p.dramas=[];p.home={rows:[],loading:false,error:''};
 try{p.videos=await api('/media/videos');}catch{p.videos=[];}
 watchPickOpen();
 p.catalog=await watchCatalog();
 const g=watchGroups()[0];
 if(g){p.svc=g.svc;p.prov=g.prov;}
 wsSafeOpen();
}

/* 片源浏览统一裹一层影院外壳：openModal() 看见这个 class 就把弹窗切成全屏深色。
   顶部/切换条/底栏都 flex:none，中间的片单区自己滚动，长列表不会把标题顶出屏幕。 */
function wsPage(inner,view){return `<div class="ws-cinema" data-view="${view||''}">${inner}</div>`;}
/* 影院层是多级页面：异步请求回来时主人可能已经按了返回、点了别的组件。
   用 data-view 比对「DOM 现在显示哪一层」和「状态期望哪一层」，不一致就不重绘，
   免得慢请求把当前页盖掉（比只判 .src-manage 更通用）。 */
function wsExpectedView(){return WATCH_PICK.tab==='drama'?(WATCH_PICK.view||'sources'):'album';}
function wsCurrentView(){const n=document.querySelector('.ws-cinema');return n?(n.dataset.view||''):'';}
function wsSafeOpen(){if(wsCurrentView()&&wsCurrentView()!==wsExpectedView())return;watchPickOpen();}
/* 视图会在请求过程中变化的场景（如 list → detail）：只比对「主人有没有翻页」 */
function wsOpenIfUnchanged(from){if(wsCurrentView()&&wsCurrentView()!==from)return;watchPickOpen();}
function watchProvider(){
 const services=((WATCH_PICK.catalog||{}).services)||[];
 const s=services.find(x=>x.id===WATCH_PICK.svc);
 return s?((s.providers||[]).find(x=>x.id===WATCH_PICK.prov)||null):null;
}
function watchGroupName(){const p=watchProvider();return p?p.title:'片源';}
function watchPickTitle(){
 const p=WATCH_PICK;
 if(p.tab!=='drama')return '选一部一起看';
 if(p.view==='sources')return '片源组件';
 if(p.view==='detail')return (p.detail&&p.detail.title)||'选一部一起看';
 if(p.view==='list'){
  const cats=(watchProvider()||{}).categories||[];
  const c=cats.find(x=>x.id===p.cat);
  return watchGroupName()+(c?' · '+c.title:'');
 }
 return watchGroupName();
}
function watchPickOpen(){openModal(watchPickTitle(),watchPickBody());}

/* 继续观看只存本机：片名/海报/上次看到的集数，够点一下接着播，不碰服务端状态 */
const WS_RECENT_KEY='love-watch-recent-v1';
function watchRecentLoad(){
 try{const a=JSON.parse(localStorage.getItem(WS_RECENT_KEY)||'[]');
  WATCH_PICK.recent=Array.isArray(a)?a.filter(x=>x&&x.id&&x.title):[];}
 catch{WATCH_PICK.recent=[];}
 return WATCH_PICK.recent;
}
function watchRecentSave(d,g,ep){
 const key=[g.svc,g.prov,d.id].join(':');
 const row={key,svc:g.svc,prov:g.prov,id:d.id,title:d.title||'一段视频',
  poster:d.poster||'',ep:Number(ep)||1,ts:Date.now()};
 const list=watchRecentLoad().filter(x=>x.key!==key);
 list.unshift(row);WATCH_PICK.recent=list.slice(0,12);
 try{localStorage.setItem(WS_RECENT_KEY,JSON.stringify(WATCH_PICK.recent));}catch{}
}
function watchRecentFor(){
 return watchRecentLoad().filter(x=>x.svc===WATCH_PICK.svc&&x.prov===WATCH_PICK.prov).slice(0,6);
}
/* 上游组件清单没有图标字段，用名字首字 + 按 id 散列的彩色字标代替品牌 logo */
const WS_LOGO_COLORS=['#F5C518','#FF6B8B','#A78BFA','#4ED8B0','#FF9840','#62A8FF','#F472B6','#9BD75B'];
function wsLogo(title,id){
 let h=0;for(const ch of String(id||''))h=(h*31+ch.charCodeAt(0))>>>0;
 const c=WS_LOGO_COLORS[h%WS_LOGO_COLORS.length];
 return `<span class="src-logo" style="--logo:${c}">${esc(String(title||'?').slice(0,1))}</span>`;
}

function watchPickBody(){
 const p=WATCH_PICK;
 const tabs=`<div class="ws-tabs">
   <button type="button" class="ws-tab${p.tab==='album'?' on':''}" data-action="watch-tab" data-id="album">相册视频</button>
   <button type="button" class="ws-tab${p.tab==='drama'?' on':''}" data-action="watch-tab" data-id="drama">在线片源</button>
  </div>`;
 if(p.tab==='album'){
  const items=p.videos.length?p.videos.map(v=>{
    const name=watchName(v.name)||'相册视频';
    return `<button type="button" class="ws-item" data-watch-media="${esc(v.id)}" data-watch-title="${esc(name)}">
    <span class="ws-thumb" style="background-image:url('/media/${esc(v.id)}?poster=1')"></span>
    <span class="ws-meta"><b>${esc(name)}</b><small>${new Date(v.created*1000).toLocaleDateString('zh-CN',{timeZone:state.me.space.timezone})}</small></span>
   </button>`;}).join(''):'<p class="meta">相册里还没有视频。在线片源那栏可以直接挑，也可以先「从本机选文件」各自打开同一部。</p>';
  return wsPage(tabs+`<div class="ws-section"><b>相册里的视频</b><span class="ws-section-count">${p.videos.length?p.videos.length+' 段':''}</span></div>
   <div class="ws-list">${items}</div>
   <div class="ws-bottom">${button('从本机选文件','watch-pick-local','soft')}${button('取消','close-modal')}</div>`,'album');
 }
 /* 在线片源：组件卡列表 → 组件首页 → 分类片单 → 选集，四层各画各的 */
 if(p.view==='sources')return wsPage(watchSourcesInner(),'sources');
 if(p.view==='home')return wsPage(watchHomeInner(),'home');
 if(p.view==='detail')return wsPage(watchEpisodesBody(p.detail),'detail');
 return wsPage(watchListInner(),'list');
}

/* 在线片源首页 = 两列组件卡（参考图 1）。卡片主体「进片源」，右侧小图标管开/关：
   button 里不能再塞 button，所以外层用 div 容器、里面放两个平级按钮。 */
function watchSourcesInner(){
 const cat=WATCH_PICK.catalog||{services:[]};
 const svcs=cat.services||[];
 const many=svcs.length>1;
 const cards=[];
 svcs.forEach(s=>(s.providers||[]).forEach(p=>{
  const label=many?`${s.name} · ${p.title}`:p.title;
  const n=(p.categories||[]).length;
  cards.push(`<div class="src-card${p.enabled?' on':''}">
    <button type="button" class="src-card-main" data-action="watch-src-open"
      data-id="${esc(s.id)}" data-prov="${esc(p.id)}">
      ${wsLogo(p.title,s.id+':'+p.id)}
      <span class="src-card-txt"><b>${esc(label)}</b><small>${n?n+' 个分类':'点一下打开'}</small></span>
     </button>
    <button type="button" class="src-card-go" data-action="watch-src-toggle"
      data-id="${esc(s.id)}" data-prov="${esc(p.id)}"
      aria-label="${p.enabled?'关闭':'启用'}${esc(p.title)}" aria-pressed="${p.enabled}">
      ${p.enabled?icon('check'):icon('arrow')}
     </button>
    </div>`);
 }));
 if(!cards.length)cards.push(`<p class="ws-empty">${esc((svcs[0]||{}).error||'还没有可用的组件，先添加一台服务地址。')}</p>`);
 const svcRows=svcs.map(s=>`<div class="src-svc-row">
   <span class="src-dot${s.online?' on':''}"></span>
   <b>${esc(s.name)}</b><small>${esc(s.base)}</small>
   <button type="button" class="link-btn" data-action="watch-src-del" data-id="${esc(s.id)}">移除</button>
  </div>`).join('');
 return `<p class="ws-tip">点卡片进片源；右侧箭头/勾决定它是否出现在选片里。</p>
  <div class="src-manage src-grid">${cards.join('')}</div>
  <div class="src-svc-block"><b>片源服务</b>${svcRows||'<p class="ws-empty">还没有服务。</p>'}</div>
  <div class="ws-bottom">${button('添加服务','watch-src-add','soft')}${button('完成','watch-src-done','primary')}</div>`;
}

/* 一行横滑海报：继续观看、各分类共用同一套卡片 */
function wsRail(items,action){
 return `<div class="ws-rail">`+items.map(d=>`<button type="button" class="ws-rail-card"
   data-action="${action}" data-id="${esc(d.id)}"${action==='watch-recent-play'?` data-ep="${Number(d.ep)||1}"`:''}>
   <span class="ws-card-poster" style="background-image:url('${esc(d.poster||'')}')">${d.remark?`<i class="ws-card-tag">${esc(d.remark)}</i>`:''}</span>
   <span class="ws-card-title">${esc(d.title)}</span>
  </button>`).join('')+`</div>`;
}

/* 组件首页（参考图 2）：顶部「继续观看」，下面按分类一排一排横滑，右侧 › 看全部 */
function watchHomeInner(){
 const p=WATCH_PICK;
 const recent=watchRecentFor();
 const blocks=[];
 if(recent.length)blocks.push(`<section class="ws-home-sec">
   <div class="ws-section"><b>继续观看</b></div>${wsRail(recent,'watch-recent-play')}</section>`);
 const cats=(watchProvider()||{}).categories||[];
 const rows=p.home.rows||[];
 rows.forEach(r=>blocks.push(`<section class="ws-home-sec">
   <div class="ws-section"><b>${esc(r.cat.title)}</b>
    <button type="button" class="ws-section-more" data-action="watch-home-more"
      data-id="${esc(r.cat.id)}" aria-label="查看${esc(r.cat.title)}全部内容">${icon('arrow')}</button></div>
   ${r.items.length?wsRail(r.items,'watch-drama'):`<p class="ws-rail-empty">${p.home.loading?'正在找…':esc(r.error||'这个分类暂时没有内容')}</p>`}
  </section>`));
 if(!rows.length)blocks.push(`<p class="ws-empty">${p.home.loading?'正在找…':esc(p.home.error||'这个片源还没有分类')}</p>`);
 if(cats.length>rows.length)blocks.push(`<button type="button" class="ws-home-all" data-action="watch-home-all">
   查看全部 ${cats.length} 个分类 ${icon('arrow')}</button>`);
 const head=`<div class="ws-home-head"><button type="button" class="ws-search"
   data-action="watch-search">${icon('search')}${p.q?'搜：'+esc(p.q):'搜片名'}</button></div>`;
 return `<div class="ws-home">${head}${blocks.join('')}</div>`;
}

/* 某分类的完整海报墙（从分区 › 或搜索进来），分页和换一批沿用老逻辑 */
function watchListInner(){
 const p=WATCH_PICK;
 const cats=(watchProvider()||{}).categories||[];
 const chips=cats.map(c=>`<button type="button" class="ws-chip${p.cat===c.id?' on':''}"
   data-action="watch-cat" data-id="${esc(c.id)}">${esc(c.title)}</button>`).join('');
 const list=p.loading?'<p class="ws-empty">正在找…</p>':(p.dramas.length?`<div class="ws-grid">`+p.dramas.map(d=>`
   <button type="button" class="ws-card" data-action="watch-drama" data-id="${esc(d.id)}">
    <span class="ws-card-poster" style="background-image:url('${esc(d.poster)}')">${d.remark?`<i class="ws-card-tag">${esc(d.remark)}</i>`:''}</span>
    <span class="ws-card-title">${esc(d.title)}</span>
   </button>`).join('')+`</div>`:`<p class="ws-empty">${p.error?esc(p.error)+'。<br>':''}换个关键词，或者切到别的分类看看。</p>`);
 const section=`<div class="ws-section"><b>${esc((cats.find(c=>c.id===p.cat)||{}).title||'片单')}</b>
   <span class="ws-section-count">${p.dramas.length?p.dramas.length+' 部':''}</span>
   <button type="button" class="ws-section-more" data-action="watch-more">换一批 ${icon('arrow')}</button></div>`;
 return `<div class="ws-toolbar"><div class="ws-cats">${chips}</div>
   <button type="button" class="ws-search" data-action="watch-search">${icon('search')}${p.q?esc(p.q):'搜片名'}</button>
  </div>`+section+`<div class="ws-list">${list}</div>
  <div class="ws-bottom">${button('取消','close-modal')}</div>`;
}

/* 组件首页数据：每个分类各拉第一页铺一行。分类多的组件（27 个）不能一口气全并发，
   3 个一批、最多 6 个分类；剩下的用「查看全部 N 个分类」去完整片单页挑。 */
const WS_HOME_MAX_CATS=6;
async function watchHomeLoad(){
 const p=WATCH_PICK;
 const g=watchProvider();
 const cats=g?((g.categories||[]).slice(0,WS_HOME_MAX_CATS)):[];
 p.home={rows:cats.map(c=>({cat:c,items:[],error:''})),loading:!!cats.length,error:''};
 if(!cats.length)p.home.error='这个片源还没有分类';
 watchPickOpen();
 for(let i=0;i<p.home.rows.length;i+=3){
  const batch=p.home.rows.slice(i,i+3);
  const res=await Promise.allSettled(batch.map(r=>api(
   `/dramas/${encodeURIComponent(p.svc)}/${encodeURIComponent(p.prov)}?category=${encodeURIComponent(r.cat.id)}&page=1`)));
  res.forEach((r,k)=>{
   if(r.status==='fulfilled')batch[k].items=(r.value&&r.value.items)||[];
   else batch[k].error=(r.reason&&r.reason.message)||'这个分类暂时打不开';
  });
  wsSafeOpen();
 }
 p.home.loading=false;
 wsSafeOpen();
}

/* 点组件卡进片源。服务端 /api/dramas 与 /api/watch 都要求组件在启用清单里，
   没勾过的源点进来会连环 403 —— 进片源时顺手勾上，右侧开关仍可再关掉。 */
async function watchOpenSource(sid,prov){
 const services=((WATCH_PICK.catalog||{}).services)||[];
 const s=services.find(x=>x.id===sid);
 const p=s&&(s.providers||[]).find(x=>x.id===prov);
 if(!p)return;
 WATCH_PICK.tab='drama';WATCH_PICK.view='home';
 WATCH_PICK.svc=sid;WATCH_PICK.prov=prov;
 WATCH_PICK.detail=null;WATCH_PICK.dramas=[];WATCH_PICK.q='';
 WATCH_PICK.cat='';WATCH_PICK.page=1;WATCH_PICK.error='';
 if(!p.enabled){
  p.enabled=true;
  try{await api('/drama-sources/enabled',{method:'PUT',body:JSON.stringify({enabled:watchEnabledKeys()})});}
  catch(e){p.enabled=false;toast(e.message||'启用失败');}
 }
 await watchHomeLoad();
}

function watchEpisodesBody(d){
 /* 正在看的那一集高亮出来：state.watch 由 watchPull() 维护 */
 const cur=(state&&state.watch)||{};
 const curEp=String(cur.drama_id||'')===String(d.id)?Number(cur.drama_ep)||0:0;
 const eps=d.episodes.map(e=>`<button type="button" class="ws-ep${curEp===Number(e.n)?' on':''}" data-action="watch-drama-ep"
   data-id="${esc(d.id)}" data-ep="${e.n}">${e.n}</button>`).join('');
 return `<div class="ws-detail-head">
   <span class="ws-poster" style="background-image:url('${esc(d.poster)}')"></span>
   <div class="ws-detail-meta">
    <b>${esc(d.title)}</b>
    <small>${d.episodes.length>1?`共 ${d.episodes.length} 集 · 点一集就开始`:'点一下就开始'}</small>
    <button type="button" class="link-btn" data-action="watch-drama-back">${icon('back')} 返回片单</button>
   </div>
  </div>
  ${d.description?`<p class="ws-desc">${esc(d.description)}</p>`:''}
  <div class="ws-eps">${eps}</div>
  <div class="ws-bottom">${button('取消','close-modal')}</div>`;
}

async function watchLoadDramas(){
 const p=WATCH_PICK;
 if(!p.catalog)p.catalog=await watchCatalog();
 const g=watchGroup();
 p.view='list';
 if(!g){p.dramas=[];p.error='这个片源暂时不可用';return watchPickOpen();}
 /* 上游的 browse 必须带分类，空着会 404；没选过就默认第一个（搜索不用带） */
 if(!p.q)p.cat=p.cat||((g.cats[0]||{}).id||'');
 p.loading=true;p.error='';
 watchPickOpen();
 const query=`?category=${encodeURIComponent(p.cat||'')}&page=${p.page}${p.q?'&q='+encodeURIComponent(p.q):''}`;
 try{
  const res=await api(`/dramas/${encodeURIComponent(g.svc)}/${encodeURIComponent(g.prov)}`+query);
  p.dramas=(res&&res.items)||[];
 }catch(e){
  /* 自己加的组件上游说挂就挂，得让主人知道是源站的事，不是我们没搜到 */
  p.dramas=[];p.error=e.message||'片源列表没拉到';toast(p.error);
 }
 p.loading=false;
 wsSafeOpen();
}

async function watchDramaDetail(id){
 const g=watchGroup();
 if(!g)return;
 const from=wsCurrentView();
 WATCH_PICK.loading=true;
 /* 详情加载期间不切视图、也不重绘：慢请求回来时主人可能已经翻页了，
    只比对「当前 DOM 还是不是当初那一层」，是才切到选集页。 */
 try{
  WATCH_PICK.detail=await api(`/dramas/${encodeURIComponent(g.svc)}/${encodeURIComponent(g.prov)}/${encodeURIComponent(id)}`);
 }catch(e){WATCH_PICK.detail=null;toast(e.message||'这个打不开');}
 WATCH_PICK.loading=false;
 if(WATCH_PICK.detail)WATCH_PICK.view='detail';
 wsOpenIfUnchanged(from);
}

function watchSearchForm(){
 openModal('搜一部片',`<form class="modal-form" id="ws-search-form">
   <label>片名、演员或关键词<input name="q" required maxlength="40" autocomplete="off" value="${esc(WATCH_PICK.q||'')}" placeholder="例如：少夫人来自东北"></label>
   ${formError()}
   ${modalActions('搜一下')}
  </form>`);
 $('#ws-search-form').onsubmit=async e=>{
  e.preventDefault();
  const q=String(new FormData(e.currentTarget).get('q')||'').trim();
  if(!q)return;
  WATCH_PICK.q=q;WATCH_PICK.page=1;WATCH_PICK.tab='drama';WATCH_PICK.view='list';
  WATCH_PICK.cat='';WATCH_PICK.detail=null;
  await watchLoadDramas();
 };
}

async function watchChooseDrama(id,ep,g){
 g=g||watchGroup();
 if(!g)return;
 const d=WATCH_PICK.detail||{};
 const title=d.title||'一段视频';
 const many=(d.episodes||[]).length>1;
 watchRecentSave({id,title,poster:d.poster||''},g,ep);
 closeModal();
 /* 记下本端刚点的片源：SSE 事件会在几百毫秒后回来，那时源可能还没挂上，
    用它避免把自己触发的同步再换一次源。 */
 watchExpectKey=`d:${g.svc}:${g.prov}:${id}:${ep}`;
 watchSetSource({drama:{src:g.svc,prov:g.prov,id,ep}});
 watchRenderStatus({...(state.watch||{}),title,drama_src:g.svc,drama_provider:g.prov,
  drama_id:id,drama_ep:ep,media:''});
 try{
  const cur=await api('/watch',{method:'PUT',body:JSON.stringify({
    drama_src:g.svc,drama_provider:g.prov,drama_id:id,drama_ep:Number(ep),media:'',
    title,position:0,duration:0,playing:false})});
  state.watch=cur;watchLastUpdated=Number(cur.updated)||0;watchFirstPoll=false;
  watchRenderStatus(cur);
  toast(many?`第 ${ep} 集，点播放就一起看`:'选好了，点播放就一起开始');
 }catch(e){toast(e.message||'选片失败');}
}

/* 一集就几分钟，播完自动接下一集；改的是服务端状态，另一半也会跟过来 */
function watchNextEpisode(){
 const st=state.watch||{};
 if(!st.drama_id||watchApplying)return;
 const next=Number(st.drama_ep||1)+1;
 if(next>2000)return;
 watchChooseDrama(st.drama_id,next,{svc:st.drama_src,prov:st.drama_provider});
}

/* ── 组件管理：加服务、勾组件 ─────────────────────────────────────── */
/* 「片源组件」现在就是在线片源 tab 的主页面，不再另开弹窗；
   添加/移除/开关之后都回到这一层，标题与返回层级由 watchPickTitle()/wsBack() 管。 */
function watchSources(){
 WATCH_PICK.tab='drama';WATCH_PICK.view='sources';
 WATCH_PICK.detail=null;
 watchPickOpen();
}
/* 影院层返回键按层级回退：组件列表→相册，首页→组件列表，片单→首页，选集→片单 */
function wsBack(){
 const p=WATCH_PICK;
 if(p.tab!=='drama')return closeModal();
 if(p.view==='sources'){p.tab='album';return watchPickOpen();}
 if(p.view==='home'){p.view='sources';return watchPickOpen();}
 if(p.view==='list'){p.view='home';p.detail=null;p.q='';return watchPickOpen();}
 if(p.view==='detail'){p.detail=null;p.view='list';return watchPickOpen();}
 return closeModal();
}

async function watchToggleSource(sid,prov){
 const cat=WATCH_PICK.catalog||{services:[]};
 const s=(cat.services||[]).find(x=>x.id===sid);
 const p=s&&(s.providers||[]).find(x=>x.id===prov);
 if(!p)return;
 p.enabled=!p.enabled;
 try{
  await api('/drama-sources/enabled',{method:'PUT',body:JSON.stringify({enabled:watchEnabledKeys()})});
 }catch(e){
  p.enabled=!p.enabled;
  toast(e.message||'改不了');
 }
 /* 当前选中的组件可能刚被关掉，回落到第一个还开着的 */
 const g=watchGroup();
 WATCH_PICK.svc=g?g.svc:'';WATCH_PICK.prov=g?g.prov:'';
 watchSources();
}

function watchAddSourceForm(){
 /* 这里的「取消」不是关弹窗而是回上一层面板（watch-src-back），
    和标准收尾件 modalActions() 的行为不同，所以保留自定义 actions。 */
 openModal('添加片源服务',`<form class="modal-form" id="ws-src-form">
   <label>名字<input name="name" maxlength="24" autocomplete="off" placeholder="随便起，例如「家里那台」"></label>
   <label>服务地址<input name="base" required maxlength="200" autocomplete="off" inputmode="url"
     placeholder="http://192.168.31.95:8788"></label>
   <p class="meta" style="margin:0">填 happy-capy 这类组件服务的根地址，保存后会自动去读它的组件清单。</p>
   ${formError()}
   <div class="form-actions">${button('取消','watch-src-back')}<button class="button primary" type="submit">保存</button></div>
  </form>`);
 $('#ws-src-form').onsubmit=async e=>{
  e.preventDefault();
  /* 先把表单节点抓在手上：await 之后事件对象的 currentTarget 会被置空，
     出错时就再也找不到那个 .form-error 了（这里踩过一次）。 */
  const form=e.currentTarget;
  const fd=new FormData(form);
  const base=String(fd.get('base')||'').trim();
  const name=String(fd.get('name')||'').trim();
  if(!base)return;
  try{
   /* 记住加之前有哪几台，好让新加的那台自动展开 ——
      否则主人加完一台还得自己往下滚去找它。 */
   const before=new Set(((WATCH_PICK.catalog||{}).services||[]).map(s=>s.id));
   await api('/drama-sources',{method:'POST',body:JSON.stringify({name,base})});
   WATCH_PICK.catalog=await watchCatalog(true);
   const fresh=((WATCH_PICK.catalog||{}).services||[]).find(s=>!before.has(s.id));
   if(fresh)WATCH_PICK.openSvc=fresh.id;
   toast('加上了，勾上想要的组件就能看');
   watchSources();
  }catch(err){
   const box=form.querySelector('.form-error');
   if(box)box.textContent=err.message||'加不上';
  }
 };
}

async function watchDropSource(sid){
 try{
  await api('/drama-sources/'+encodeURIComponent(sid),{method:'DELETE'});
  WATCH_PICK.catalog=await watchCatalog(true);
  const g=watchGroup();
  WATCH_PICK.svc=g?g.svc:'';WATCH_PICK.prov=g?g.prov:'';
  watchSources();
 }catch(e){toast(e.message||'删不掉');}
}

async function watchChooseMedia(id,title){
 closeModal();
 watchExpectKey='m:'+id;
 watchSetSource({media:id});
 watchRenderStatus({...(state.watch||{}),title,media:id});
 try{
  const cur=await api('/watch',{method:'PUT',body:JSON.stringify({media:id,title,position:0,duration:0,playing:false})});
  state.watch=cur;watchLastUpdated=Number(cur.updated)||0;watchFirstPoll=false;
  watchRenderStatus(cur);
  toast('选好了，点播放就一起开始');
 }catch(e){toast(e.message||'选片失败');}
}

function watchPickLocal(){
 const input=$('#watch-file');if(!input)return;
 input.value='';
 input.onchange=()=>{
   const f=input.files&&input.files[0];if(!f)return;
   watchExpectKey='local';
   watchSetSource({file:f});
  /* 本机片源不上传，只把片名告诉对方；媒体和短剧都传空，把服务器上的片源清掉，
     免得对方那边还挂着一部你以为已经换掉的片子。 */
  const title=watchName(f.name)||'本机视频';
  api('/watch',{method:'PUT',body:JSON.stringify({media:'',drama_id:'',drama_ep:0,title,position:0,duration:0,playing:false})})
   .then(cur=>{state.watch=cur;watchLastUpdated=Number(cur.updated)||0;watchFirstPoll=false;watchRenderStatus(cur);})
   .catch(()=>{});
  try{watchVideo()?.play().catch(()=>{});}catch{}
 };
 input.click();
}

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
function insertStickerText(em){const ta=$('#chat-text');if(!ta)return;if(document.activeElement===ta){const s=ta.selectionStart??ta.value.length,e=ta.selectionEnd??s;ta.value=ta.value.slice(0,s)+em+ta.value.slice(e);ta.selectionStart=ta.selectionEnd=s+em.length;}else ta.value+=em;syncCompose();}
/* 微信式输入框：初始一行，输入后自动长高，超过约 4 行内部滚动 */
function autoGrow(ta){if(!ta)return;ta.style.height='auto';ta.style.height=Math.min(ta.scrollHeight,96)+'px';}
/* 有文字时把语音位换成发送按钮（.has-text 由样式接管显示/隐藏）。
   一起看的输入栏只有发送键、按键常显，这里只负责让它跟着文字长高。 */
function syncCompose(){
 const form=$('#chat-form'),ta=$('#chat-text');
 if(form&&ta){form.classList.toggle('has-text',!!ta.value.trim());autoGrow(ta);}
 const wt=$('#watch-text');if(wt)autoGrow(wt);
}
/* 键盘避让：Chrome 108+ 的 interactive-widget=resizes-content 会让布局视口跟着键盘
   一起缩，输入栏自然浮在键盘上；旧 WebView 只缩视觉视口，这里用 --kb-h 手动顶上去。 */
function syncKeyboard(){
 const vv=window.visualViewport;if(!vv)return;
 const hidden=Math.max(0,Math.round(window.innerHeight-vv.height-vv.offsetTop));
 document.documentElement.style.setProperty('--kb-h',hidden>90?hidden+'px':'0px');
 /* kb-open 用来给"底部安全区内边距"让位：键盘顶上来时那块安全区已经被键盘占了，
    再留一道 env(safe-area-inset-bottom) 就成了多出来的空白条。 */
 if(document.body)document.body.classList.toggle('kb-open',hidden>90);
}
if(window.visualViewport){addEventListener('resize',syncKeyboard);window.visualViewport.addEventListener('resize',syncKeyboard);window.visualViewport.addEventListener('scroll',syncKeyboard);}

/* ── 聊天里直接发文件（相册 / 拍摄 / 录音都走这里）───────────────── */
async function sendChatFiles(files){
 const list=[...(files||[])].filter(Boolean);if(!list.length)return;
 try{
  const ids=[];
  for(const f of list)ids.push((await uploadFile(f)).id);
  await sendChat({content:'',date:today(),media:ids});
  await refresh();scrollChat();
  toast(list.length>1?`已发送 ${list.length} 个文件`:'已发送');
 }catch(e){toast(e.message||'发送失败');}
}
/* 录音：点一下开始，再点一下结束并直接发出去（不复用写记录的弹窗，聊天里要快） */
let chatRec=null,chatRecStream=null;
async function chatVoiceToggle(){
 if(chatRec&&chatRec.state==='recording'){chatRec.stop();return;}
 try{
  if(!navigator.mediaDevices?.getUserMedia||!window.isSecureContext)
   throw new Error('录音需要 https 环境，当前页面拿不到麦克风');
  chatRecStream=await navigator.mediaDevices.getUserMedia({audio:true});
  const mime=['audio/webm','audio/mp4','audio/ogg'].find(m=>window.MediaRecorder&&MediaRecorder.isTypeSupported(m));
  chatRec=new MediaRecorder(chatRecStream,mime?{mimeType:mime}:{});
  const chunks=[];
  chatRec.ondataavailable=e=>chunks.push(e.data);
  chatRec.onstop=async()=>{
   const form=$('#chat-form');if(form)form.classList.remove('recording');
   try{chatRecStream.getTracks().forEach(t=>t.stop());}catch{}
   const type=(chatRec.mimeType||'audio/webm').split(';')[0];
   const ext=type.includes('mp4')?'m4a':type.includes('ogg')?'ogg':'webm';
   if(!chunks.length)return toast('没有录到声音');
   toast('正在发送语音…');
   await sendChatFiles([new File(chunks,'语音.'+ext,{type})]);
  };
  chatRec.start();
  $('#chat-form')?.classList.add('recording');
  toast('正在录音，再点一次麦克风结束并发送');
 }catch(e){toast(e.message||'录音失败');}
}
/* ── 分享一首歌 ────────────────────────────────────────────────────────
   一条聊天消息里只存摘要（歌名 / 歌手 / 媒体 id 或在线试听地址），不复制音频文件。
   播放器是自己画的：原生 <audio controls> 在深色气泡里会带一条系统菜单（右下角三点），
   既和整体风格不搭，老 WebView 上还会多画一层边框。 */
let songAudio=null,songCur=null;   // songCur={node,kind:'bubble'|'preview'}
function songSrcOf(s){
 if(!s)return '';
 if(s.mid)return '/media/'+s.mid;
 if(s.src)return '/api/music/stream?u='+encodeURIComponent(s.src);
 return '';
}
/* 封面同样走同源转发：Apple 的图床不在 CSP 的 img-src 里，直连会被拦成空白 */
function artSrcOf(u){return u?'/api/music/stream?u='+encodeURIComponent(u):'';}
function fmtDur(sec){const s=Math.max(0,Math.round(sec||0));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0');}
function audioCtl(){
 if(!songAudio){
  songAudio=new Audio();
  songAudio.preload='none';
  ['timeupdate','loadedmetadata','play','pause','durationchange'].forEach(ev=>songAudio.addEventListener(ev,()=>paintSong()));
  songAudio.addEventListener('ended',()=>{paintSong(true);songReset();});
 }
 return songAudio;
}
function paintSong(idle){
 if(!songCur)return;
 const a=audioCtl(),paused=idle||a.paused;
 let node=songCur.node;
 if(songCur.kind==='bubble'&&node&&!node.isConnected){
  /* 聊天日志被整块重绘（对方发来新消息就会重绘）后，旧节点已经不在文档里：
     按 data-src 找回同一首歌的那个卡片，接着显示进度，别让"正在播"变回"未播"。 */
  const again=$$('.chat-song').find(n=>n.dataset.src&&n.dataset.src===songCur.src);
  if(!again){songCur=null;return;}
  songCur.node=again;node=again;
 }
 if(songCur.kind==='bubble'){
  const total=isFinite(a.duration)&&a.duration>0?a.duration:0;
  const bar=node.querySelector('.cs-track i'),cur=node.querySelector('[data-role=cur]'),dur=node.querySelector('[data-role=dur]'),btn=node.querySelector('.cs-play');
  if(bar)bar.style.width=(total?(a.currentTime/total*100):0)+'%';
  if(cur)cur.textContent=fmtDur(a.currentTime);
  if(dur&&total)dur.textContent=fmtDur(total);
  if(btn)btn.innerHTML=icon(paused?'play':'pause');
  node.classList.toggle('playing',!paused);
 }else if(node.innerHTML!==icon(paused?'play':'pause'))node.innerHTML=icon(paused?'play':'pause');
}
function songReset(){
 const cur=songCur;if(!cur)return;
 songCur=null;
 if(cur.kind==='bubble'){
  const bar=cur.node.querySelector('.cs-track i'),c=cur.node.querySelector('[data-role=cur]'),btn=cur.node.querySelector('.cs-play');
  if(bar)bar.style.width='0%';if(c)c.textContent='0:00';if(btn)btn.innerHTML=icon('play');
  cur.node.classList.remove('playing');
 }else cur.node.innerHTML=icon('play');
}
/* 气泡里播放：同一时刻只有一首在响，换歌自动掐掉上一首 */
async function songToggle(btn){
 const card=btn.closest('.chat-song');if(!card)return;
 const src=card.dataset.src;
 if(!src)return toast('这首歌没有音频文件');
 const a=audioCtl();
 if(songCur&&songCur.node===card){if(a.paused)a.play().catch(()=>toast('放不出来，可能是网络问题'));else a.pause();return;}
 if(songCur){try{a.pause();}catch{}songReset();}
 songCur={node:card,kind:'bubble',src};
 a.src=src;
 try{await a.play();}catch{toast('放不出来，可能是网络问题');songReset();}
}
/* 选择面板里的试听：不发送，只在弹窗里听一段 */
async function songTry(btn){
 const src=btn.dataset.src;if(!src)return;
 const a=audioCtl();
 if(songCur&&songCur.node===btn){if(a.paused)a.play().catch(()=>toast('试听打不开'));else a.pause();return;}
 if(songCur){try{a.pause();}catch{}songReset();}
 songCur={node:btn,kind:'preview',src};
 a.src=src;
 try{await a.play();}catch{toast('试听打不开，换一首试试');songReset();}
}
function songCardMarkup(song){
 const src=songSrcOf(song);
 const tip=song.mid?'本地音频':(song.src?'在线试听 · 30 秒':'');
 const cover=song.art?`<img src="${esc(artSrcOf(song.art))}" alt="" loading="lazy" decoding="async">`:'';
 return `<div class="chat-song" data-src="${esc(src)}">
  <div class="cs-main">
   <span class="cs-cover">${cover||icon('music')}</span>
   <span class="cs-body"><b>${esc(song.title)}</b><small>${esc(song.artist||tip||'一首歌')}</small></span>
   ${src?`<button type="button" class="cs-play" data-action="song-toggle" aria-label="播放">${icon('play')}</button>`:''}
  </div>
  ${src?`<div class="cs-foot"><span class="cs-time" data-role="cur">0:00</span><div class="cs-track"><i></i></div><span class="cs-time" data-role="dur">--:--</span></div>`
        :'<small class="cs-warn">这首歌没有音频文件</small>'}
 </div>`;
}
/* ── 选歌弹窗：共同歌单 + 在线搜歌两个面板 ─────────────────────────── */
let songSearchSeq=0;
function songPicker(){
 state.songTab=state.songTab||'list';
 openModal('发一首歌',`<div class="song-sheet">
  <div class="ss-tabs">
   <button type="button" class="ss-tab${state.songTab==='list'?' active':''}" data-action="song-tab" data-id="list">共同歌单</button>
   <button type="button" class="ss-tab${state.songTab==='online'?' active':''}" data-action="song-tab" data-id="online">在线搜歌</button>
  </div>
  <div id="song-pane"></div>
 </div>`,{wide:true});
 renderSongPane();
}
function songListRow(r){
 const b=r.body||{},m=songMedia(r),src=m?'/media/'+m.id:'';
 return `<div class="song-pick" role="button" tabindex="0" data-action="chat-song-send" data-id="${r.id}">
  <span class="sp-cover">${icon('music')}</span>
  <span class="sp-body"><b>${esc(b.title||'未命名')}</b><small>${esc(b.content||(m?'你们放进来的音频':'没配音频文件'))}</small></span>
  ${src?`<button type="button" class="sp-btn" data-action="song-try" data-src="${esc(src)}" aria-label="试听">${icon('play')}</button>`:'<i class="sp-warn">无音频</i>'}
 </div>`;
}
function onlineSongRow(it,i){
 const sub=[it.artist,it.album].filter(Boolean).join(' · ');
 return `<div class="song-pick" role="button" tabindex="0" data-action="chat-song-online" data-idx="${i}">
  <span class="sp-cover">${it.art?`<img src="${esc(artSrcOf(it.art))}" alt="" loading="lazy" decoding="async">`:icon('music')}</span>
  <span class="sp-body"><b>${esc(it.title||'未命名')}</b><small>${esc(sub||'在线试听')}</small></span>
  <button type="button" class="sp-btn" data-action="song-try" data-src="/api/music/stream?u=${encodeURIComponent(it.preview||'')}" aria-label="试听">${icon('play')}</button>
 </div>`;
}
function renderSongPane(){
 const pane=$('#song-pane');if(!pane)return;
 if(state.songTab==='online'){
  pane.innerHTML=`<div class="ss-search"><span class="ss-lens">${icon('search')}</span><input id="song-q" type="search" placeholder="搜歌名或歌手，例如：晚安" autocomplete="off" enterkeyhint="search" value="${esc(state.songQuery||'')}"></div>
   <div id="song-results" class="song-picks"><p class="meta ss-tip">接的是 Apple 公开曲库，听到的是 30 秒试听片段。搜中文歌名或英文都行。</p></div>`;
  const inp=$('#song-q');if(!inp)return;
  inp.addEventListener('input',()=>{
   state.songQuery=inp.value;
   clearTimeout(renderSongPane.timer);
   renderSongPane.timer=setTimeout(()=>runSongSearch(),480);
  });
  inp.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();runSongSearch();}});
  if((state.songQuery||'').trim())runSongSearch();
  setTimeout(()=>{try{inp.focus();}catch{}},60);
  return;
 }
 const songs=recordsOf('music').slice().sort((a,b)=>b.created-a.created);
 if(!songs.length){
  pane.innerHTML='<p class="meta ss-tip">共同歌单还空着。换成「在线搜歌」直接搜一首发出去，或者去歌单页添加你们自己的音频文件。</p><div class="form-actions"><button type="button" class="button soft" data-action="chat-song-golist">去歌单添加</button></div>';
  return;
 }
 pane.innerHTML=`<div class="song-picks">${songs.map(songListRow).join('')}</div><p class="small-note ss-note">点一首直接发出去，右边的小按钮只在本机试听。</p>`;
}
async function runSongSearch(){
 const q=(state.songQuery||'').trim(),box=$('#song-results');if(!box)return;
 if(!q){box.innerHTML='<p class="meta ss-tip">输入歌名或歌手，开始搜。</p>';return;}
 const seq=++songSearchSeq;
 box.innerHTML='<p class="meta ss-tip">正在搜…</p>';
 try{
  const r=await api('/music/search?q='+encodeURIComponent(q)+'&limit=20');
  if(seq!==songSearchSeq)return;
  state.songResults=r.items||[];
  box.innerHTML=state.songResults.length
   ?state.songResults.map(onlineSongRow).join('')
   :`<p class="meta ss-tip">${esc(r.error||'没搜到，换个关键词试试。')}</p>`;
 }catch(e){
  if(seq===songSearchSeq)box.innerHTML=`<p class="meta ss-tip">${esc(e.message||'搜索失败，稍后再试')}</p>`;
 }
}
async function sendSong(rid){
 const r=recordsOf('music').find(x=>x.id===rid);
 if(!r)return;
 const m=songMedia(r);
 closeModal();
 try{
  await sendChat({content:'',date:today(),media:[],song:{
   title:String(r.body?.title||'未命名').slice(0,120),
   artist:String(r.body?.content||'').slice(0,120),
   mid:m?m.id:''}});
  await refresh();scrollChat();toast('已分享这首');
 }catch(e){toast(e.message||'分享失败');}
}
async function sendOnlineSong(idx){
 const it=(state.songResults||[])[idx];
 if(!it||!it.preview)return;
 closeModal();
 try{
  await sendChat({content:'',date:today(),media:[],song:{
   title:String(it.title||'未命名').slice(0,120),
   artist:String(it.artist||'').slice(0,200),
   mid:'',src:it.preview,art:it.art||'',dur:it.dur||0}});
  await refresh();scrollChat();toast('已分享这首');
 }catch(e){toast(e.message||'分享失败');}
}
/* ── 从相册选：铺满下半屏，多选 + 写一句，一次发出去 ──────────────────
   以前点一张就立刻发送，想发三张得开三次面板。现在点选只做"引用"（打勾 + 序号），
   底部还能写一句描述跟着一起发；半屏高度让缩略图一屏能看清更多。 */
let albumPickList=[],albumPickSel=[];
async function chatAlbumPick(){
 albumPickSel=[];
 let list=[];
 try{list=await api('/media/images?limit=300');}catch{}
 albumPickList=list;
 focusReturn=document.activeElement;
 $('#modal-root').innerHTML=`<div class="pick-overlay" id="pick-overlay"><section class="pick-sheet" role="dialog" aria-modal="true" aria-labelledby="pick-title">
  <header class="ps-head"><div><b id="pick-title">从相册选</b><small id="ps-count">${list.length?`相册里 ${list.length} 张`:'相册还是空的'}</small></div><button type="button" class="button soft small" id="ps-upload">上传</button><button type="button" class="icon-btn" data-action="close-modal" aria-label="关闭">${icon('close')}</button></header>
  <div class="ps-grid" id="ps-grid">${list.length?list.map(m=>`<button type="button" class="ps-cell" data-mid="${esc(m.id)}" aria-label="${esc(m.name||'照片')}"><img src="/media/${esc(m.id)}?preview=true" alt="" loading="lazy" decoding="async"><i></i></button>`).join(''):'<p class="meta">相册里还没有照片。先用上面的「上传」传一张，或者去相册页传。</p>'}</div>
  <div class="ps-foot">
   <div class="ps-picked" id="ps-picked"></div>
   <div class="ps-row"><input id="ps-caption" maxlength="200" placeholder="说点什么…（可以留空）" autocomplete="off"><button type="button" class="button primary" id="ps-send" disabled>发送</button></div>
  </div>
 </section></div>`;
 document.body.style.overflow='hidden';
 syncAlbumPick();
 const grid=$('#ps-grid');
 if(grid)grid.onclick=e=>{
  const cell=e.target.closest('[data-mid]');if(!cell)return;
  const mid=cell.dataset.mid,at=albumPickSel.indexOf(mid);
  if(at>=0)albumPickSel.splice(at,1);else albumPickSel.push(mid);
  syncAlbumPick();
 };
 const picked=$('#ps-picked');
 if(picked)picked.onclick=e=>{
  const chip=e.target.closest('[data-drop]');if(!chip)return;
  albumPickSel.splice(Number(chip.dataset.drop),1);syncAlbumPick();
 };
 $('#ps-send')?.addEventListener('click',sendAlbumPick);
 $('#ps-upload')?.addEventListener('click',()=>{closeModal();$('#chat-file')?.click();});
 $('#ps-caption')?.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();sendAlbumPick();}});
 /* 点面板外的暗色区域 = 取消（和别的弹窗一致） */
 $('#pick-overlay')?.addEventListener('click',e=>{if(e.target.id==='pick-overlay')closeModal();});
}
function syncAlbumPick(){
 const n=albumPickSel.length;
 $$('.ps-cell').forEach(c=>{
  const at=albumPickSel.indexOf(c.dataset.mid);
  c.classList.toggle('on',at>=0);
  const badge=c.querySelector('i');if(badge)badge.textContent=at>=0?String(at+1):'';
 });
 const picked=$('#ps-picked');
 if(picked)picked.innerHTML=albumPickSel.map((mid,i)=>`<button type="button" class="ps-chip" data-drop="${i}" aria-label="取消第 ${i+1} 张"><img src="/media/${esc(mid)}?preview=true" alt=""><span>${i+1}</span></button>`).join('');
 const cnt=$('#ps-count');
 if(cnt)cnt.textContent=n?`已选 ${n} 张`:(albumPickList.length?`相册里 ${albumPickList.length} 张`:'相册还是空的');
 const btn=$('#ps-send');
 if(btn){btn.disabled=!n;btn.textContent=n?`发送 ${n}`:'发送';}
}
async function sendAlbumPick(){
 if(!albumPickSel.length)return;
 const cap=($('#ps-caption')?.value||'').trim(),ids=albumPickSel.slice();
 const btn=$('#ps-send');if(btn)btn.disabled=true;
 try{
  await sendChat({content:cap,date:today(),media:ids});
  closeModal();
  await refresh();scrollChat();
  toast(ids.length>1?`已发送 ${ids.length} 张`:'已发送');
 }catch(e){toast(e.message||'发送失败');syncAlbumPick();}
}
/* ── 聊天气泡皮肤：两千多张图，分批画、选中先预览再落库 ────────────────
   图是 128×112 的整图（四角带装饰），前端靠 CSS border-image 切九宫格随
   内容拉伸，所以这里只管"挑哪一张"。两件事特意没做成即点即生效：
   ① 图底深浅差得远，深字压在紫气泡上根本看不见，得让人配着预览选字色；
   ② 一组的图有一千多张，全塞进 DOM 会卡，所以滚到底再画下一批。 */
let bpGroups=[],bpPack='',bpPick='',bpFg='dark',bpSwap=true,bpShown=0;
const BP_PAGE=90;
async function bubblePicker(){
 focusReturn=document.activeElement;
 bpPick=chatSkin();bpFg=chatSkinFg();bpSwap=chatSkinSwap();bpShown=0;bpGroups=[];
 const cur=bpPick?bpPick.split('/')[0]:'';
 $('#modal-root').innerHTML=`<div class="pick-overlay" id="bp-overlay"><section class="pick-sheet bp-sheet" role="dialog" aria-modal="true" aria-labelledby="bp-title">
  <header class="ps-head"><div><b id="bp-title">聊天气泡</b><small id="bp-count">正在读素材…</small></div><button type="button" class="icon-btn" data-action="close-modal" aria-label="关闭">${icon('close')}</button></header>
  <div class="bp-tabs" id="bp-tabs"></div>
  <div class="bp-preview" id="bp-preview"></div>
  <div class="bp-grid" id="bp-grid"><p class="meta">正在加载…</p></div>
  <div class="ps-foot">
   <div class="bp-fg"><span>字色</span><button type="button" data-fg="dark">深色字</button><button type="button" data-fg="light">浅色字</button><i>气泡图有深有浅，按这张图选</i></div>
   <label class="bp-swap"><input type="checkbox" id="bp-swap"${bpSwap?' checked':''}><span>左右互换</span><i>气泡的装饰朝哪边，看着别扭就勾一下</i></label>
   <div class="ps-row"><button type="button" class="button soft" id="bp-none">不用皮肤</button><button type="button" class="button primary" id="bp-apply">使用这个</button></div>
  </div>
 </section></div>`;
 document.body.style.overflow='hidden';
 $('#bp-overlay').onclick=e=>{
  if(e.target.id==='bp-overlay'){closeModal();return;}
  const pack=e.target.closest('[data-pack]');
  if(pack){if(pack.dataset.pack===bpPack)return;bpPack=pack.dataset.pack;renderBubbleTabs();renderBubbleGrid();return;}
  const cell=e.target.closest('[data-skin]');
  if(cell){bpPick=cell.dataset.skin;syncBubblePick();return;}
  const fg=e.target.closest('[data-fg]');
  if(fg){bpFg=fg.dataset.fg;syncBubblePick();}
 };
 $('#bp-none').onclick=()=>{bpPick='';syncBubblePick();};
 $('#bp-swap').onchange=e=>{bpSwap=e.target.checked;syncBubblePick();};
 $('#bp-apply').onclick=applyBubblePick;
 let data={groups:[]};
 try{data=await api('/bubbles');}catch(e){toast(e.message||'气泡素材读不出来');}
 bpGroups=data.groups||[];
 if(!bpGroups.length){
  $('#bp-grid').innerHTML='<p class="meta">服务器上还没有气泡素材。把图放进数据卷的 bubbles/ 目录，按包分文件夹即可。</p>';
  $('#bp-count').textContent='没有素材';renderBubbleTabs();syncBubblePick();return;
 }
 bpPack=bpGroups.some(g=>g.id===cur)?cur:bpGroups[0].id;
 renderBubbleTabs();renderBubbleGrid();syncBubblePick();
 const grid=$('#bp-grid');
 grid.onscroll=()=>{if(grid.scrollTop+grid.clientHeight>grid.scrollHeight-180)growBubbleGrid();};
}
function bpPackLabel(id,i){
 const m=/^p(\d+)$/.exec(id);
 return `第 ${m?m[1]:i+1} 组`;
}
function renderBubbleTabs(){
 const box=$('#bp-tabs');if(!box)return;
 box.innerHTML=bpGroups.map((g,i)=>`<button type="button" class="bp-tab${g.id===bpPack?' on':''}" data-pack="${esc(g.id)}" aria-pressed="${g.id===bpPack}">${bpPackLabel(g.id,i)}<i>${g.count}</i></button>`).join('');
}
function bpCells(items){
 return items.map(n=>`<button type="button" class="bp-cell" data-skin="${esc(bpPack)}/${esc(n)}" aria-label="气泡 ${esc(n)}"><img src="/api/bubbles/${esc(bpPack)}/${esc(n)}" alt="" loading="lazy" decoding="async"></button>`).join('');
}
function renderBubbleGrid(){
 const g=bpGroups.find(x=>x.id===bpPack),grid=$('#bp-grid');if(!grid)return;
 if(!g){grid.innerHTML='<p class="meta">这一组没有图。</p>';return;}
 bpShown=Math.min(BP_PAGE,g.items.length);
 grid.scrollTop=0;
 grid.innerHTML=bpCells(g.items.slice(0,bpShown));
 const total=bpGroups.reduce((n,x)=>n+x.count,0),cnt=$('#bp-count');
 if(cnt)cnt.textContent=`共 ${total} 张 · 这一组 ${g.count} 张`;
}
function growBubbleGrid(){
 const g=bpGroups.find(x=>x.id===bpPack),grid=$('#bp-grid');
 if(!g||!grid||bpShown>=g.items.length)return;
 const from=bpShown;
 bpShown=Math.min(bpShown+BP_PAGE,g.items.length);
 grid.insertAdjacentHTML('beforeend',bpCells(g.items.slice(from,bpShown)));
 syncBubbleCells();
}
function syncBubbleCells(){
 const on=bpPick;
 $$('#bp-grid [data-skin]').forEach(c=>c.classList.toggle('on',!!on&&c.dataset.skin===on));
}
function syncBubblePick(){
 syncBubbleCells();
 const pv=$('#bp-preview');
 if(pv){
  const on=!!bpPick,cls=(on?' skinned':'')+(bpFg==='light'?' light':'');
  /* 预览必须跟聊天页用同一套左右规则，否则"预览看着对、进去反了" */
  const mirror=on?bpPick.replace(/\.png$/,'-r.png'):'';
  const left=bpSwap?mirror:bpPick, right=bpSwap?bpPick:mirror;
  const style=on?` style="--skin:url('/api/bubbles/${esc(left)}');--skin-r:url('/api/bubbles/${esc(right)}')"`:'';
  pv.innerHTML=`<div class="bp-preview-row"><div class="bp-bubble${cls}"${style}>今天下班去买菜，回来给你做番茄牛腩，路上有点堵</div></div>`
   +`<div class="bp-preview-row mine"><div class="bp-bubble mine${cls}"${style}>好呀，路上慢点</div></div>`;
 }
 $$('#bp-overlay [data-fg]').forEach(b=>b.classList.toggle('on',b.dataset.fg===bpFg));
 const ap=$('#bp-apply');
 if(ap)ap.textContent=bpPick?'使用这个':'用默认气泡';
}
async function applyBubblePick(){
 const s=state.me.space||{},btn=$('#bp-apply');
 if(btn)btn.disabled=true;
 try{
  await put('/space',{...s,chat_bubble:bpPick||'',chat_bubble_fg:bpFg,chat_bubble_swap:bpSwap});
  await refresh();closeModal();
  toast(bpPick?'气泡换好了，两个人都看得见':'已换回默认气泡');
 }catch(e){toast(e.message||'保存失败');}
 finally{if(btn)btn.disabled=false;}
}
/* ── 点开一条位置消息：先想办法唤起高德 App ──────────────────────────
   原来整张卡是一个 target=_blank 的链接，点下去直接切到浏览器看网页地图，
   在 App 里等于"跳出恋爱空间"。现在的顺序：
   Android → intent://（装了就直开高德，没装由 Chrome/WebView 内核按
   browser_fallback_url 自己回落到网页）；iOS → iosamap://；
   其它/都失败 → 1.4 秒后在本窗口打开 uri.amap.com（callnative=1，网页自己也会再试一次）。
   "唤起来了"的判断：页面被切到后台（visibilitychange / pagehide）。 */
function openMap(lat,lng,name){
 const nm=name||'我们的位置';
 const web='https://uri.amap.com/marker?position='+lng+','+lat
  +'&name='+encodeURIComponent(nm)+'&coordinate=gaode&callnative=1&src=love-space';
 const ua=navigator.userAgent||'';
 if(!/android|iphone|ipad|ipod|harmony|mobile/i.test(ua)){window.location.href=web;return;}
 const q='sourceApplication=LoveSpace&poiname='+encodeURIComponent(nm)+'&lat='+lat+'&lon='+lng+'&dev=0';
 let gone=false;
 const mark=()=>{gone=true;};
 document.addEventListener('visibilitychange',mark);
 window.addEventListener('pagehide',mark);
 const timer=setTimeout(()=>{
  document.removeEventListener('visibilitychange',mark);
  window.removeEventListener('pagehide',mark);
  if(gone||document.hidden)return;
  window.location.href=web;
 },1400);
 void timer;
 if(/android|harmony/i.test(ua)){
  /* 两条路各有各的道理：
     - APK 里（WebView）走 androidamap:// 直 scheme，Capacitor 的 WebViewClient 会把
       非 http 的地址当外部 Intent 拉起，比 intent:// 更稳；
     - 浏览器里走 intent://，因为只有 Chrome 认 #Intent; 里的 browser_fallback_url，
       没装高德时会自己回落到网页地图，而不是丢一个"无法打开"的错误页。 */
  const scheme='androidamap://viewMap?'+q;
  window.location.href=isNativeApp()
   ?scheme
   :'intent://viewMap?'+q+'#Intent;scheme=androidamap;package=com.autonavi.minimap;S.browser_fallback_url='+encodeURIComponent(web)+';end';
 }else{
  window.location.href='iosamap://viewMap?'+q;
 }
}
/* 位置：浏览器定位拿经纬度，作为一条 location 消息发出去 */
function chatLocate(){
 if(!navigator.geolocation)return toast('这台设备不支持定位');
 if(!window.isSecureContext)return toast('定位只允许在 https 页面使用，当前连接不是安全上下文');
 const p=$('#chat-fn');if(p)p.hidden=true;
 toast('正在获取位置…');
 /* 首次使用会弹系统权限框，用户点「允许」之后第一次回调仍可能是 PERMISSION_DENIED
    （权限刚落、WebView 还没接住），所以对 code=1 给一次自动重试。 */
 let retried=false;
 const tips={1:'位置权限没给：到「设置 → 应用 → 恋爱空间 → 权限」里打开「位置」，再试一次',
             2:'暂时定不到位置——室内、地下室或没开 GPS 都会这样，换个地方再试',
             3:'定位超时了，再点一次'};
 const attempt=()=>navigator.geolocation.getCurrentPosition(async pos=>{
  try{
   const lat=Math.round(pos.coords.latitude*1e5)/1e5,lng=Math.round(pos.coords.longitude*1e5)/1e5;
   await sendChat({content:'',date:today(),media:[],location:{lat,lng}});
   await refresh();scrollChat();toast('位置已发送');
  }catch(e){toast(e.message||'发送失败');}
 },err=>{
  if(err&&err.code===1&&!retried){retried=true;setTimeout(attempt,1200);return;}
  toast(tips[err&&err.code]||('定位失败：'+(err&&err.message)||'未知原因'));
 },{enableHighAccuracy:true,timeout:8000,maximumAge:300000});
 attempt();
}
/* 表情面板：内嵌于输入栏上方（输入框始终可见），点击按钮开合；点 emoji 只插入文本不弹键盘 */
function stickerPanel(){
 const dock=$('#sticker-dock');if(!dock)return;
 if(!dock.hidden){dock.hidden=true;return;}
 const fn=$('#chat-fn');if(fn)fn.hidden=true;
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
 return `<div class="page-heading"><div><h1>${esc(i.title||'聊天记录')}</h1><p>${platformLabel[i.platform]||'聊天记录'} · ${i.message_count||0} 条记录 · 我们两人共享${i.author?` · 由 ${esc(person(i.author).name)} 导入`:''}</p></div>${button('返回列表','imports-back','secondary','arrow')}</div><div class="filters"><input id="import-q" placeholder="搜索聊天内容…" aria-label="搜索聊天内容"><input id="import-day" type="date" aria-label="跳转到日期"></div><div id="import-log" class="chat-log import-log"><div class="loading"><span class="loading-heart">♡</span></div></div><div class="inline-actions" style="justify-content:center"><button class="button soft small" id="import-earlier">加载更早的记录</button></div><div class="form-actions">${button('删除这份聊天记录','delete-import','secondary small','trash',`data-id="${i.id}"`)}</div>`;
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
/* 记录类型的图标：年报、看板这些"按类型聚合"的地方共用一份，别各写一张表 */
const KIND_EMOJI={post:'📝',diary:'📔',draft:'📄',surprise:'🎁',anniversary:'📅',wish:'✨',personal_wish:'💝',mood:'🌤',note:'💌',question:'💭',habit:'🌱',quest:'💫',ledger:'💰',period:'🌸',music:'🎵',album:'📷',chat:'💬'};
const WEEKDAY_LABEL=['周一','周二','周三','周四','周五','周六','周日'];
/* 小年报：基础计数之外，给"这一年是怎么过的"——记录了几天、最长连续多少天、
   最勤的月份与星期、记得最多的类型、收到的回应、常写的字、最常出现的心情。
   关键词由后端做 2-gram 词频，这里只按词频缩放字号，不再二次排序。 */
function yearbookBody(data){
 const k=data.by_kind||{};
 const highlights=[['📝','时光动态',k.post||0],['📷','收藏照片',data.photos],['☀','心情记录',data.moods],['✨','完成心愿',data.wishes_done],['📅','纪念日',data.anniversaries]].filter(x=>x[2]>0);
 const facts=[];
 if(data.active_days)facts.push(['🗓️','记录下来的日子',`${data.active_days} 天`]);
 if(data.streak>1)facts.push(['🔥','最长连续记录',`${data.streak} 天`]);
 if(data.best_month)facts.push(['📅','最勤快的一个月',`${data.best_month.month} 月 · ${data.best_month.count} 条`]);
 if(data.best_weekday)facts.push(['📆','最活跃的一天',`${WEEKDAY_LABEL[data.best_weekday.weekday]||''} · ${data.best_weekday.count} 条`]);
 if(data.top_kind&&kindLabel[data.top_kind.kind])facts.push([KIND_EMOJI[data.top_kind.kind]||'📝','记得最多',`${kindLabel[data.top_kind.kind]} ${data.top_kind.count} 条`]);
 if(data.interactions)facts.push(['💬','收到的回应',`${data.interactions} 次赞与评论`]);
 const words=(data.words||[]).slice(0,8);
 const maxWord=Math.max(1,...words.map(w=>w.n));
 const moods=(data.mood_top||[]).filter(m=>m.n>0);
 const grid=`<div class="yearbook-grid"><div class="yearbook-stat"><strong>${data.total}</strong><small>条记录</small></div><div class="yearbook-stat"><strong>${data.photos}</strong><small>张照片</small></div><div class="yearbook-stat"><strong>${data.moods}</strong><small>次心情</small></div><div class="yearbook-stat"><strong>${data.wishes_done}</strong><small>个心愿</small></div></div>`;
 if(!data.total)return grid+'<p class="meta">这一年，还在慢慢写下我们的故事…</p>';
 return grid
  +(facts.length?`<div class="yearbook-facts">${facts.map(([e,l,v])=>`<div class="yearbook-fact"><span class="yf-emoji">${e}</span><span class="yf-label">${l}</span><span class="yf-value">${v}</span></div>`).join('')}</div>`:'')
  +(words.length?`<div class="yearbook-section"><h3>这一年常写的字</h3><div class="yearbook-words">${words.map(w=>`<span class="yearbook-word" style="font-size:calc(${12+Math.round(w.n/maxWord*8)}px * var(--fs-scale))">${esc(w.w)}<i>${w.n}</i></span>`).join('')}</div></div>`:'')
  +(moods.length?`<div class="yearbook-section"><h3>最常出现的心情</h3><div class="yearbook-moods">${moods.map(m=>`<span class="yearbook-mood">${m.emoji}<i>${m.n}</i></span>`).join('')}</div></div>`:'')
  +(highlights.length?`<div class="yearbook-highlights">${highlights.map(([e,l,n])=>`<div class="yearbook-highlight"><span class="hl-emoji">${e}</span><span class="hl-text">${l}</span><span class="hl-num">${n}</span></div>`).join('')}</div>`:'');
}
async function loadYearbook(){
 const box=$('#yearbook');if(!box)return;
 try{
  const data=await api('/yearbook');
  state.yearbookData=data;
  box.innerHTML=`<h2>📖 ${data.is_current?'今年':' '+data.year+' 年'}的我们</h2><div class="yearbook-summary"><p>${data.total} 条记录 · ${data.photos} 张照片 · ${data.moods} 次心情${data.streak>1?` · 连续 ${data.streak} 天`:''}</p><span class="yearbook-toggle-row">${button('展开小年报','expand-yearbook','soft small','arrow')}</span></div>`;
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
 if(!selected)return `<div class="card cal-detail-card cal-detail-empty">${icon('calendar')}<p>点日历上的某一天，看看那天我们一起记下了什么。</p></div>`;
 const sel=days[selected]||null;
 const wd='日一二三四五六'[new Date(y,m-1,Number(selected)).getDay()];
 const rows=[
  ...((sel&&sel.anniversaries)||[]).map(a=>`<div class="otd-item"><span class="otd-year">纪念</span><button class="link-btn" data-action="otd-detail" data-id="${a.id}">${esc(a.title)}</button></div>`),
  ...((sel&&sel.moods)||[]).map(md=>`<div class="otd-item"><span class="otd-year">心情</span><span class="meta">${esc(person(md.author)?.name||'')}: ${esc(md.emoji)}</span></div>`),
  ...((sel&&sel.posts)||[]).map(p=>`<div class="otd-item"><span class="otd-year">动态</span><button class="link-btn" data-action="otd-detail" data-id="${p.id}">${esc(p.title||'一份回忆')}</button></div>`),
  ...((sel&&sel.checks&&sel.checks.length)?[`<div class="otd-item"><span class="otd-year">打卡</span><span class="meta">${sel.checks.length} 人完成</span></div>`]:[])
 ].join('');
 return `<div class="card cal-detail-card"><div class="cal-detail-head"><strong>${m} 月 ${Number(selected)} 日</strong><span>${y} 年 · 周${wd}</span></div>${rows||'<p class="meta">这一天还空着，留一段空白也挺好。</p>'}</div>`;
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
 /* 四种标记四种颜色，图例和格子里的小圆点共用这一份，改色只改这里 */
 const DOT_KINDS=[['anniversaries','var(--primary)','纪念日'],['posts','var(--primary-dark)','动态'],['moods','var(--green)','心情'],['checks','var(--amber)','打卡']];
 const activeDays=Object.keys(days).filter(k=>{const info=days[k];return info&&DOT_KINDS.some(([key])=>info[key]&&info[key].length);}).length;
 const weekHtml=ws=>ws.map((w,i)=>`<span class="cal-week${i===0||i===6?' is-end':''}">${w}</span>`).join('');
 const cellsHtml=cells.map(d=>{
  if(!d)return '<span class="cal-blank"></span>';
  const info=days[d],wd=(start+Number(d)-1)%7;
  const dots=info?DOT_KINDS.filter(([k])=>info[k]?.length).map(([k,c,label])=>`<i class="cal-dot" style="background:${c}" title="${label}"></i>`).join(''):'';
  return `<button type="button" class="cal-day${selected===d?' selected':''}${info?' has-events':''}${String(Number(d))===todayDay?' is-today':''}${wd===0||wd===6?' is-end':''}" data-action="cal-day" data-id="${d}" aria-label="${m} 月 ${Number(d)} 日${info?'，有记录':''}"><span class="cal-num">${Number(d)}</span><span class="cal-dots">${dots}</span></button>`;
 }).join('');
 return `<div class="calendar-page">${heading('共同年历','重要的日子，一眼看清。','')}
 <div class="cal-bar"><div class="cal-bar-title"><strong>${m} 月</strong><span>${y} 年 · ${activeDays?`记了 ${activeDays} 天`:'还空着'}</span></div><div class="cal-bar-nav"><button type="button" class="cal-nav" data-action="cal-prev" aria-label="上个月">‹</button><button type="button" class="cal-today" data-action="cal-today">今天</button><button type="button" class="cal-nav" data-action="cal-next" aria-label="下个月">›</button></div></div>
 <div class="cal-board"><div class="cal-weekrow">${weekHtml(['日','一','二','三','四','五','六'])}</div><div class="calendar-grid">${cellsHtml}</div></div>
 <p class="cal-legend">${DOT_KINDS.map(([,c,label])=>`<span class="cal-legend-item"><i style="background:${c}"></i>${label}</span>`).join('')}<span class="cal-legend-hint">点一格看看那天</span></p>
 <div id="cal-detail">${calDetailHTML()}</div></div>`;
}
const toolsList=[['calendar','🗓️','共同年历','重要的日子，一眼看清'],['anniversary','📅','纪念日','每个重要的日子，都认真对待'],['quest','💫','恋爱清单','一起做完这些小事，就是我们的故事'],['wish','✨','共同愿望','把一起想做的事，一件件实现'],['ledger','💰','共同账本','为了彼此花过的钱，也是一段回忆'],['personal-wish','💝','个人心愿','对方看得到心愿名称，输入一次密码后就能读到内容'],['mood','🌤','心情手记','晴天雨天，都想陪着你'],['note','💌','悄悄留言','有些喜欢，值得慢慢读'],['question','💭','情侣问答','每天再多了解彼此一点'],['music','🎵','共同歌单','把属于我们的歌，放在一起'],['habit','🌱','共同打卡','和你一起，成为更好的我们']];
function togetherPage() {
 if(state.tab==='calendar')return calendarPage();
 if(state.tab==='personal-wish')return personalWishPage();
 if(state.tab==='quest')return questPage();
 if(state.tab==='ledger')return ledgerPage();
 if(state.tab==='period')return periodPage();
 if(state.tab==='period-analysis')return periodAnalysisPage();
 if(state.tab==='music')return musicPage();
 if(state.tab){const meta=toolsList.find(x=>x[0]===state.tab);if(meta)return `${heading(meta[2],meta[3],'new-'+state.tab,'添加'+({anniversary:'纪念日',wish:'愿望',mood:'心情',note:'留言',question:'问题',habit:'目标'}[state.tab]))}${state.tab==='question'?'<p class="hint">可以写下自己的问题，也可以从内置题目里挑一个。双方回答后才揭晓彼此的答案。</p>':''}${recordsOf(state.tab).length?recordsOf(state.tab).map(recordCard).join(''):empty('给我们，多一点小小的仪式感',meta[3],'new-'+state.tab,'现在开始')}`;}
 return `${heading('关于我们，还有好多好多','把喜欢落在实处，把日子过成纪念。')}<div class="tools-grid"><button class="tool-card tool-card-wide" data-action="tool-period"><span class="tool-emoji">🌸</span><span class="tool-wide-copy"><h3>生理期</h3><p>记下周期，把照顾提前一点</p></span><span class="tool-wide-go">${icon('arrow')}</span></button><button class="tool-card" data-nav="dashboard"><span class="tool-emoji">📊</span><h3>数据看板</h3><p>我们的点滴，都在这里</p></button><button class="tool-card" data-nav="weekly"><span class="tool-emoji">✉️</span><h3>回忆周报</h3><p>把这一周，收进一封信</p></button><button class="tool-card" data-nav="figure"><span class="tool-emoji">📸</span><h3>情侣摆拍参考</h3><p>照着姿势参考，拍一张</p></button>${toolsList.map(([id,emoji,title,desc])=>`<button class="tool-card" data-action="tool-${id}"><span class="tool-emoji">${emoji}</span><h3>${title}</h3><p>${desc}</p></button>`).join('')}</div><div class="section-heading settings-section-heading"><h2>${icon('gear')} 设置</h2></div><div class="tools-grid settings-tools"><button class="tool-card" data-action="space"><span class="tool-emoji">🏡</span><h3>空间信息</h3><p>空间名称与相恋日期</p></button><button class="tool-card" data-action="theme-form"><span class="tool-emoji">🎨</span><h3>主题与外观</h3><p>主题色、夜间模式与动效</p></button><button class="tool-card" data-action="home-bg"><span class="tool-emoji">🖼️</span><h3>主页背景</h3><p>换一张首页封面照片</p></button><button class="tool-card" data-action="chat-bg"><span class="tool-emoji">🌄</span><h3>聊天背景</h3><p>聊天壁纸与文字对比度</p></button><button class="tool-card" data-action="chat-bubble"><span class="tool-emoji">💬</span><h3>聊天气泡</h3><p>两千多款气泡皮肤随手挑</p></button>${state.me.users.length<2?`<button class="tool-card" data-action="invite"><span class="tool-emoji">💌</span><h3>邀请另一半入住</h3><p>把你们的专属空间分享给 TA</p></button>`:''}<button class="tool-card" data-nav="channels"><span class="tool-emoji">🔔</span><h3>提醒设置</h3><p>通知渠道与提醒偏好</p></button><button class="tool-card" data-nav="settings"><span class="tool-emoji">⚙️</span><h3>全部设置</h3><p>账号资料、数据导出与备份</p></button></div>`;
}
/* 恋爱清单：对齐「小恩爱 200+ 件小事」的思路，但只用 40 条精选做引子，
   不批量灌库——清单是两个人的，不是产品的。 */
const QUEST_IDEAS=[
 ['日常','一起做一顿完整的早餐'],['日常','互换一天的家务'],['日常','一起逛一次菜市场'],['日常','给对方读一段书'],
 ['日常','一起养一盆植物'],['日常','写一封手写信给对方'],['日常','一起拍一组生活照'],['日常','给对方剪一次指甲'],
 ['旅行','一起看一次日出'],['旅行','一起看一次日落'],['旅行','去一次海边踩水'],['旅行','坐一次绿皮火车'],
 ['旅行','在陌生的城市迷路一次'],['旅行','一起看一场livehouse'],['旅行','去一次露营看星星'],['旅行','拍一张跳起来的合照'],
 ['美食','一起做一次火锅'],['美食','一起排队买一次网红小吃'],['美食','互相喂对方吃一样没吃过的'],['美食','一起去一次夜市'],
 ['美食','一起烤一次蛋糕'],['美食','记住对方最爱的三道菜'],['美食','一起喝到微醺'],['美食','给对方做一次生日面'],
 ['约会','看一场电影并牵着手'],['约会','一起去一次游乐园'],['约会','一起逛一次美术馆'],['约会','去一次城市最高的地方'],
 ['约会','一起看一次烟花'],['约会','重走第一次见面的路'],['约会','一起唱一次KTV'],['约会','雨天共撑一把伞'],
 ['生活','一起做一次体检'],['生活','一起存一笔旅行基金'],['生活','一起布置一次房间'],['生活','一起过完一个没有手机的晚上'],
 ['生活','一起吵一架然后和好'],['生活','一起制定一次年度计划'],['生活','互相写一份「喜欢你的十件事」'],['生活','一起看完一部很长的剧'],
];

/* 情侣问答题库：40+ 条，分回忆/默契/未来/趣味四组。
   问题表单里用 optgroup 分组展示，比平铺 select 好扫。 */
const QUESTION_BANK=[
  ['回忆',['第一次心动，是哪个瞬间？','如果可以重温一天，你会选哪天？','你记得我说过最温柔的话是哪句？','我们第一次见面，你心里在想什么？','你最想封存的一个我们共同的瞬间是？','我做过最让你感动的事是什么？','你记得我们第一次吵架是为什么吗？','有没有一个瞬间，你觉得"就是TA了"？','我们之间最默契的一次不用说话的经历是？','你最想回到我们关系的哪个阶段？']],
  ['默契',['什么样的陪伴让你最有安全感？','你觉得我们最像的地方是什么？','如果用一个词形容我们的关系，会是什么？','你觉得我最懂你的时候是什么时候？','我们之间最不需要解释就能懂的事是什么？','你觉得我们在一起后，彼此最大的变化是？','你最欣赏我性格里的哪一点？','你觉得我们最互补的地方在哪？','如果我们的默契值满分是100，现在你打几分？','你觉得我们最不像情侣的地方是什么？']],
  ['未来',['今年最想和我一起完成什么事？','如果明年我们可以去任何地方，你最想去哪？','你觉得十年后的我们会是什么样子？','你最想和我一起学的新技能是什么？','如果我们有一个只属于我们的传统，你希望是什么？','你最想和我一起完成的三个愿望是？','你觉得我们未来最需要一起面对的挑战是什么？','如果时间可以倒流但只能改一件事，你会改什么？','你最想和我一起过的一个节日是？','你觉得我们在一起最应该坚持的习惯是？']],
  ['趣味',['如果我是一种动物，你觉得我是什么？','你觉得我喝醉之后最可爱的地方是？','如果我们要一起拍一部电影，你最想演什么角色？','你觉得我最像哪种食物？','如果我们要一起开一家店，你最想开什么？','你觉得我最应该改掉的一个坏习惯是？','如果我们要一起学一门乐器，你最想学什么？','你觉得我最应该在公众场合少做的事是？','如果我们要一起做一个短视频，你最想拍什么？','你觉得我最应该尝试的一件新事物是？']],
];
const money=n=>'¥'+Number(n||0).toFixed(2);

 function questPage(){
 const items=recordsOf('quest').slice().sort((a,b)=>(a.body.done?1:0)-(b.body.done?1:0));
 const done=items.filter(r=>r.body.done).length,total=items.length,pct=total?Math.round(done/total*100):0;
 const back='';
 const progress=total?`<section class="card"><div class="section-heading"><h2>💫 一起完成 ${done} / ${total}</h2></div><div class="stat-bar big"><i style="width:${pct}%"></i></div><p class="meta">${pct}% · ${pct>=100?'全部做完了，可以写新的清单了':pct>=50?'已经过半，继续':'慢慢来，一件一件做'}</p></section>`:'';
 const ideas=QUEST_IDEAS.filter(([,t])=>!items.some(r=>r.body.title===t));
 const ideaBlock=`<details class="card"><summary style="cursor:pointer;font-weight:600">没灵感？从精选清单里挑（剩余 ${ideas.length} 条）</summary><div class="tabs" style="flex-wrap:wrap;margin-top:12px">${ideas.length?ideas.map(([c,t])=>`<button data-action="add-quest" data-title="${esc(t)}" data-cat="${esc(c)}">＋ ${esc(t)}</button>`).join(''):'<p class="meta">精选清单已经全部添加过了。</p>'}</div></details>`;
 const customBlock=`<section class="card"><div class="section-heading"><h2>写下你们自己的</h2></div><form id="quest-custom-form" class="quest-custom-form"><div class="quest-input-row"><input id="quest-custom-input" placeholder="想一起做的一件小事…" maxlength="80" required><button type="submit" class="button primary small">${icon('plus')} 加入</button></div><p class="small-note">自定义的小事会标记「自定义」，和精选清单分开展示。</p></form></section>`;
 return `${heading('恋爱清单','一件小事，也是一个故事。','new-quest','添加小事','heart')}${back}${progress}${items.length?items.map(recordCard).join(''):empty('清单还空着','从下面挑几件，或者写下你们自己的。','new-quest','添加第一件小事')}${customBlock}${ideaBlock}`;
}

function ledgerPage(){
 const items=recordsOf('ledger').slice().sort((a,b)=>String(b.body.date||'').localeCompare(String(a.body.date||'')));
 const nowMonth=today().slice(0,7);
 const month=state.ledgerMonth||nowMonth;
 const inMonth=items.filter(r=>String(r.body.date||'').slice(0,7)===month);
 const sum=rows=>rows.reduce((s,r)=>s+Number(r.body.amount||0),0);
 const monthTotal=sum(inMonth),allTotal=sum(items);
 /* 人均对比给两层：这个月谁花得多（当下最关心），和开账以来谁花得多（总量层面）。
    付款人就是记录作者，所以直接按 author 聚合，不用额外字段。 */
 const byUser=state.me.users.map(u=>({u,v:sum(inMonth.filter(r=>r.author===u.id))}));
 const allByUser=state.me.users.map(u=>({u,v:sum(items.filter(r=>r.author===u.id))}));
 const byCat={};inMonth.forEach(r=>{const k=r.body.category||'其他';byCat[k]=(byCat[k]||0)+Number(r.body.amount||0);});
 const cats=Object.entries(byCat).sort((a,b)=>b[1]-a[1]);
 const catPeak=Math.max(1,...cats.map(c=>c[1]));
 /* 近六个月趋势：一根柱子一个月，高度按最大值归一。空月份也要占位，
    否则"这个月没花钱"会从图上消失，看不出断档。 */
 const trend=[];
 for(let i=5;i>=0;i--){
  const d=new Date(month+'-01T00:00:00');d.setMonth(d.getMonth()-i);
  const key=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');
  trend.push({key,label:(d.getMonth()+1)+'月',total:sum(items.filter(r=>String(r.body.date||'').slice(0,7)===key))});
 }
 const trendPeak=Math.max(1,...trend.map(t=>t.total));
 const [yy,mm]=month.split('-');
 const monthLabel=`${yy} 年 ${Number(mm)} 月`;
 const switcher=`<div class="ledger-month-switch"><button class="icon-btn" data-action="ledger-month" data-delta="-1" aria-label="上个月">${icon('back')}</button><strong>${monthLabel}${month===nowMonth?' · 本月':''}</strong><button class="icon-btn" data-action="ledger-month" data-delta="1" aria-label="下个月"${month>=nowMonth?' disabled':''}>${icon('arrow')}</button></div>`;
 const summary=items.length?`<section class="card"><div class="section-heading"><h2>💰 共同账本</h2>${switcher}</div><div class="stats-hero" style="grid-template-columns:repeat(2,minmax(0,1fr));margin:0 0 6px"><div class="stat-card"><span>${month===nowMonth?'本月':Number(mm)+' 月'}一起花了</span><strong>${money(monthTotal)}</strong></div><div class="stat-card"><span>累计记录</span><strong>${money(allTotal)}</strong></div></div><div class="ledger-meta">这个月 ${inMonth.length} 笔${inMonth.length?'':'，还没记过'}</div>${byUser.map(x=>`<div class="stat-row"><span>${esc(x.u.name)}</span><div class="stat-bar"><i style="width:${monthTotal?Math.round(x.v/monthTotal*100):0}%"></i></div><b>${money(x.v)}</b></div>`).join('')}<p class="small-note">这个月谁付的；合计 ${monthTotal?money(monthTotal):money(0)}。</p><div class="section-heading" style="margin-top:14px"><h2>最近六个月</h2></div><div class="ledger-trend">${trend.map(t=>`<div class="ledger-trend-col${t.key===month?' active':''}"><span class="lt-amount">${t.total?'¥'+Math.round(t.total):''}</span><div class="lt-bar"><i style="height:${Math.max(t.total?6:2,Math.round(t.total/trendPeak*100))}%"></i></div><span class="lt-label">${t.label}</span></div>`).join('')}</div><div class="section-heading" style="margin-top:14px"><h2>累计谁花得多</h2></div>${allByUser.map(x=>`<div class="stat-row"><span>${esc(x.u.name)}</span><div class="stat-bar"><i style="width:${allTotal?Math.round(x.v/allTotal*100):0}%"></i></div><b>${money(x.v)}</b></div>`).join('')}${cats.length?`<div class="section-heading" style="margin-top:14px"><h2>花在哪</h2></div>${cats.map(([k,v])=>`<div class="stat-row"><span>${esc(k)}</span><div class="stat-bar"><i style="width:${Math.round(v/catPeak*100)}%"></i></div><b>${money(v)}</b></div>`).join('')}`:''}<p class="small-note">付款人就是记录作者；金额只在你们两个人之间可见。</p></section>`:'';
 return `${heading('共同账本','一起花的钱，也是共同生活的一部分。','new-ledger','记一笔','book')}${summary}${items.length?items.map(recordCard).join(''):empty('账本还是空的','一起吃的那顿饭、一起买的那张票，都值得记下来。','new-ledger','记第一笔')}`;
}

/* ———— 生理期 ————
   参考美柚的核心闭环：记一次经期 → 推算周期与下次 → 日历上标出来。
   这里没有「共享 / 私密」也没有「替谁记」：两个人共同维护同一条周期，
   谁都能记、能改，页面看到的完全一样（后端 period.visible / db.visible 同口径）。 */
/* 记录项按天的档位表：编号落库（加密后也短），文案和图标只活在前端。
   想加一个选项只改这里，后端白名单不用动。 */
const PERIOD_FLOW={1:'非常少量',2:'少量',3:'中量',4:'大量',5:'非常大量'};
const PERIOD_COLOR={1:['浅红色','#F6A8BB'],2:['鲜红色','#EF3F68'],3:['深红色','#B22340'],4:['褐色','#8A5432'],5:['黑色','#3B3431']};
const PERIOD_PAIN={1:['完全不痛','😌'],2:['轻微痛','🙂'],3:['比较痛','😣'],4:['非常痛','😖'],5:['痛到极致','😫']};
const PERIOD_DISCHARGE={1:['干燥','内裤干爽，分泌物量少'],2:['粘稠','分泌物稠厚，触感像胶状物'],3:['稀糊状','含水量偏多偏黄，触感像乳液'],4:['水状','呈白色或透明，触感似水滴'],5:['蛋清状','呈透明状，两指间可拉丝']};
const PERIOD_MOODS=[['😄','超开心'],['😃','挺开心'],['😐','一般'],['🙁','不开心'],['😭','好伤心'],['🤩','兴奋'],['😲','惊喜'],['😌','满足'],['🥰','心动'],['😎','自信'],['😴','放松'],['😑','平静'],['😤','烦躁'],['😠','易怒'],['😡','生气'],['😰','焦虑'],['😞','内耗'],['😣','压力'],['😨','害怕'],['😶','冷漠']];
const PERIOD_SEX=[['无措施','⚠️'],['避孕套','🛡️'],['体外排精','💦'],['未射精','🚫'],['紧急避孕药','💊'],['短效避孕药','💊'],['长效避孕药','💊'],['节育环','⭕'],['其他措施','🌸'],['自慰','✋']];
const PERIOD_BODY_SYMPTOMS=[['没有症状','👍'],['腰酸','🧍'],['腹痛','🤕'],['小腹坠胀','🎈'],['乳房胀痛','💗'],['身体酸痛','💪'],['头痛','🤯'],['眩晕','💫'],['失眠','🌙'],['粉刺','🫧'],['皮肤干燥','🧴'],['食欲不振','🍽️'],['贪冷饮','🧊'],['腹泻','🚽'],['便秘','🧻'],['疲惫','😪']];
const PERIOD_SECRETION=[['褐色分泌物','🟤'],['出血','🩸'],['有血块','🔴'],['白带增多','⚪']];
const PERIOD_SYMPTOMS=[...PERIOD_BODY_SYMPTOMS,...PERIOD_SECRETION].map(([name])=>name);
/* 记录项清单：顺序就是美柚记录页的顺序，图标是「这类纪录长什么样」的提示 */
const PERIOD_LOG_FIELDS=[['flow','流量','🩸'],['color','颜色','🎨'],['pain','痛经','⚡'],['sex','爱爱','💗'],['symptoms','症状','💊'],['mood','心情','😊'],['weight','体重','⚖️'],['discharge','白带','💧'],['temp','体温','🌡️']];
const DAY_MS=864e5;
function dayNum(s){return Math.round(Date.parse(String(s).slice(0,10)+'T00:00:00Z')/DAY_MS);}
function dayStr(n){return new Date(n*DAY_MS).toISOString().slice(0,10);}
/* 日记录行：同一种 kind，靠「有 date 没有 start」认出来。经期行才有 start，参与周期推算；
   日记录行只描述那一天，日历和预测都不受它影响。 */
function periodDayRows(){return recordsOf('period').filter(r=>!r.body.start&&r.body.date);}
function periodDayRow(date){return periodDayRows().find(r=>String(r.body.date).slice(0,10)===date)||null;}
function periodDayLogs(){const map={};periodDayRows().forEach(r=>{map[String(r.body.date).slice(0,10)]=r.body;});return map;}
/* 一行记录右侧要显示的值：空字符串表示还没记，行尾会换成 ⊕ */
function periodValueText(key,b){
 switch(key){
  case 'flow':return b.flow?(typeof b.flow==='number'?(PERIOD_FLOW[b.flow]||''):'经量'+b.flow):'';
  case 'color':return b.color?(PERIOD_COLOR[b.color]||[''])[0]:'';
  case 'pain':return b.pain?(PERIOD_PAIN[b.pain]||[''])[0]:'';
  case 'discharge':return b.discharge?(PERIOD_DISCHARGE[b.discharge]||[''])[0]:'';
  case 'mood':{const m=b.mood?PERIOD_MOODS[b.mood-1]:null;return m?`${m[0]} ${m[1]}`:'';}
  case 'sex':{
   const list=periodSexEntries(b);
   if(!list.length)return '';
   const first=list[0];
   const ways=first.w.map(i=>(PERIOD_SEX[i-1]||[])[0]).filter(Boolean).join('、');
   return [list.length>1?`${list.length} 次`:'',first.t||'',ways].filter(Boolean).join(' · ');
  }
  case 'symptoms':return (b.symptoms||[]).join(' · ');
  case 'weight':return b.weight?`${b.weight} 公斤`:'';
  case 'temp':return b.temp?`${b.temp} ℃`:'';
  default:return '';
 }
}
/* 存一天：没有这天的行就新建，有就整体覆盖（body 是整份加密体，不能只发一个字段） */
async function periodSaveDay(date,patch){
 const row=periodDayRow(date);
 const body={...((row&&row.body)||{}),date,...patch};
 Object.keys(body).forEach(k=>{
  const v=body[k];
  if(v===''||v==null||(Array.isArray(v)&&!v.length))delete body[k];
 });
 if(body.start)delete body.start;   // 日记录行永不带 start，否则会被当成一次经期
 if(row)await put('/records/'+row.id,{kind:'period',body});
 else await post('/records',{kind:'period',body,client_id:uuid()});
 await refresh();
}
/* 「月经来了 是/否」：是＝这天补一次经期起点（已在窗口内则不动）；
   否＝这天是首日就撤掉这条，是中途某天就把这次经期截到昨天为止。 */
/* 这一天算不算经期，用两个动作表达，跟美柚一致：
   · 经期外：[月经来了]  —— 从这天开始一次；离上次结束 3 天内自动接上那一段，不拆成两次
   · 经期内：[月经走了]  —— 今天干净了，这次截到昨天（今天是首日就直接撤掉）
             [月经又来了] —— 今天还在，把结束日再往后推一天（幂等，连点不会疯长） */
async function periodStart(day){
 const d=periodData(),n=dayNum(day),lastEp=d.lastEp;
 if(lastEp){
  const gap=n-lastEp.end;
  // 刚结束又回潮：接在上一段后面，否则一个月会碎成两三段经期
  if(gap>=1&&gap<=3){
   const r=lastEp.rec;
   await put('/records/'+r.id,{kind:'period',body:{...r.body,length:n-dayNum(r.body.start)+1}});
   toast('已经把这次经期接到今天');await refresh();return;
  }
 }
 // 经期长度的默认值取历史平均，但不低于 3 天：中途截短过一次之后，
 // 平均值会被拉到 1–2 天，下次新建就会变成一个荒唐的"两天经期"。
 const body={start:day,length:Math.max(3,d.length),cycle:d.cycle};
 await post('/records',{kind:'period',body,client_id:uuid()});
 toast('已记下这次经期');await refresh();
}
async function periodEnd(day){
 const d=periodData(),n=dayNum(day),hit=periodEpisodeOf(d,n);
 if(!hit)return toast('这天本来就不在经期里');
 const ep=hit.owner,s=dayNum(ep.body.start);
 if(s===n){await del('/records/'+ep.id);toast('已撤掉这次经期');}
 else{await put('/records/'+ep.id,{kind:'period',body:{...ep.body,length:n-s}});toast('这次经期到昨天为止');}
 await refresh();
}
async function periodMore(day){
 const d=periodData(),n=dayNum(day),hit=periodEpisodeOf(d,n);
 if(!hit)return toast('这天不在经期里');
 const ep=hit.owner,s=dayNum(ep.body.start),len=Number(ep.body.length||5),want=Math.max(len,n-s+2);
 if(want===len)return toast(`这次经期已经排到第 ${len} 天了`);
 await put('/records/'+ep.id,{kind:'period',body:{...ep.body,length:want}});
 toast('这次经期又多算一天');await refresh();
}
function periodData(){
 /* 两个人共同维护同一条周期：不按作者区分，谁记的都算进去，界面也就只有一套 */
 const items=recordsOf('period').filter(r=>r.body.start).slice().sort((a,b)=>String(a.body.start).localeCompare(String(b.body.start)));
 /* 同一次月经常被拆成两三行（中途点了「月经走了」、隔天又「月经又来了」就会另起一行）。
   统计前先按"首尾相接即同一段"合并，否则平均经期天数会被碎片腰斩——
   去年补了半年数据后，13 行只对应 8 次月经，平均天数一度显示成 2 天。 */
 const episodes=[];
 items.forEach(r=>{
  const s=dayNum(r.body.start),len=Math.max(1,Number(r.body.length||1)),e=s+len-1;
  const prev=episodes[episodes.length-1];
  if(prev&&s<=prev.end+1){
   prev.end=Math.max(prev.end,e);prev.length=prev.end-prev.start+1;prev.rec=r;prev.frags.push(r);return;
  }
  episodes.push({start:s,end:e,length:len,rec:r,frags:[r]});
 });
 const gaps=[];
 for(let i=1;i<episodes.length;i++){const g=episodes[i].start-episodes[i-1].start;if(g>=15&&g<=60)gaps.push(g);}
 const lastEp=episodes[episodes.length-1]||null;
 const avg=gaps.length?Math.round(gaps.reduce((a,b)=>a+b,0)/gaps.length):(lastEp?.rec.body.cycle||28);
 const length=episodes.length?Math.round(episodes.reduce((s,e)=>s+e.length,0)/episodes.length):5;
 const todayN=dayNum(today());
 const startN=lastEp?lastEp.start:null;
 const nextStart=startN!=null?startN+avg:null;
 /* 判断"今天在不在经期里"必须用这次记录的实际天数，不能用平均天数：
   平均 3 天、这次只记了 1 天的时候，以前会出现"标题写卵泡期、副标题写经期第 2 天"的矛盾。
   这里同样取合并后的段长，否则最后几天被拆成碎片时"经期第 N 天"会提前结束。 */
 const lastLen=lastEp?lastEp.length:5;
 const inWindow=startN!=null&&todayN>=startN&&todayN<startN+lastLen;
 return {items,episodes,gaps,cycle:avg,length,last:lastEp?lastEp.rec:null,lastEp,lastLen,nextStart,todayN,inWindow,
  dayOfPeriod:inWindow?todayN-startN+1:0,untilNext:nextStart!=null?nextStart-todayN:null,
  estimated:gaps.length===0};
}
/* 这一天落在哪一次月经里（合并后的段），以及该动哪一行：
   取开始日不晚于这天的最后一个碎片，这样即便这天正好落在两个碎片之间的空档
   （隔一天才又「月经又来了」），改长度也改在正确的那一行上。 */
function periodEpisodeOf(d,n){
 const ep=(d.episodes||[]).find(e=>n>=e.start&&n<=e.end);
 if(!ep)return null;
 const owner=ep.frags.filter(r=>dayNum(r.body.start)<=n).pop()||ep.frags[0];
 return {ep,owner};
}
/* 美柚式四阶段：月经期 / 卵泡期 / 排卵期 / 黄体期
   锚点是每次月经开始日，排卵日按"下次月经前 14 天"推（黄体期长度相对固定），
   所以黄体期天数恒定、卵泡期随周期长短伸缩，这也符合真实生理规律。 */
const PHASE_NAMES={period:'月经期',follicular:'卵泡期',fertile:'排卵期',luteal:'黄体期'};
function cyclePhases(d){
 const map={};
 const mark=(s,len,predicted)=>{
  const ovu=s+d.cycle-14;
  const put=(n,phase)=>{if(n>=0)map[dayStr(n)]={phase,predicted};};
  for(let i=0;i<len;i++)put(s+i,'period');
  for(let i=s+len;i<=ovu-6;i++)put(i,'follicular');
  for(let i=ovu-5;i<=ovu+1;i++)put(i,'fertile');
  for(let i=ovu+2;i<s+d.cycle;i++)put(i,'luteal');
  const k=dayStr(ovu);if(map[k])map[k].ovu=true;
 };
 // 先铺预测（远的先写），再用实际记录覆盖 —— 有真实数据时永远以真实为准
 if(d.nextStart!=null)for(let k=2;k>=0;k--)mark(d.nextStart+d.cycle*k,d.length,true);
 d.episodes.forEach(e=>mark(e.start,e.length,false));
 return map;
}
function todayPhase(d){const ph=cyclePhases(d)[today()];return ph||null;}
/* 整月网格：格子样式沿用 .cal-day（经期实心粉、预测虚边、排卵紫、记过细节带点）。
   只负责画格子，标题和翻页在 periodTopCard 里——原来的「双月日历」删掉了，一个月就够看。 */
function periodMonthGrid(y,m,d){
 const lead=new Date(Date.UTC(y,m-1,1)).getUTCDay(),days=new Date(Date.UTC(y,m,0)).getUTCDate();
 const phases=cyclePhases(d),todayS=today(),logs=periodDayLogs(),picked=state.periodDay||todayS;
 // 月初第一格的"上一段"要取上月最后一天，否则每月 1 号都会被误标成阶段第一天
 const firstIso=`${y}-${String(m).padStart(2,'0')}-01`;
 let prevPhase=(phases[dayStr(dayNum(firstIso)-1)]||{}).phase||'';
 const recs=new Map();
 d.items.forEach(r=>recs.set(String(r.body.start).slice(0,10),r));
 const cells=[...Array(lead)].map(()=>'<span></span>');
 for(let v=1;v<=days;v++){
  const iso=`${y}-${String(m).padStart(2,'0')}-${String(v).padStart(2,'0')}`,ph=phases[iso],rec=recs.get(iso),log=logs[iso];
  const isStart=!!ph&&ph.phase!==prevPhase;
  prevPhase=ph?ph.phase:'';
  // 格子里不再写短标签：经期是实心粉、排卵期是连续紫底，标签只会把那一行撑高
  const cls=ph?` ph-${ph.phase}${ph.predicted?' ph-pred':''}${ph.ovu?' ph-ovu':''}${isStart?' ph-start':''}`:'';
  const parts=[ph?`${PHASE_NAMES[ph.phase]}${ph.predicted?'（预测）':''}`:'还没有记录',ph&&ph.ovu?'排卵日':'',rec?'这次经期的第一天':'',log?'这天记过身体情况':'点一下记这天'].filter(Boolean);
  const tip=parts.join(' · ');
  cells.push(`<button type="button" class="cal-day${cls}${iso===todayS?' is-today':''}${rec?' has-rec':''}${log?' has-log':''}${iso===picked?' picked':''}" data-action="period-day" data-day="${iso}" title="${tip}" aria-label="${m} 月 ${v} 日，${tip}"><span class="cal-num">${v}</span><span class="cal-dots"></span></button>`);
 }
 return `<div class="cal-weekrow">${['日','一','二','三','四','五','六'].map((w,i)=>`<span class="cal-week${i===0||i===6?' is-end':''}">${w}</span>`).join('')}</div><div class="calendar-grid period-cal">${cells.join('')}</div>`;}
/* 翻月：月末日期要夹到目标月的最后一天，否则 1/31 往前翻会跳到 3 月 */
function shiftMonth(day,delta){
 const y=Number(day.slice(0,4)),m=Number(day.slice(5,7))-1+delta;
 const dt=new Date(Date.UTC(y,m,1));
 const last=new Date(Date.UTC(dt.getUTCFullYear(),dt.getUTCMonth()+1,0)).getUTCDate();
 const date=Math.min(Number(day.slice(8)),last);
 return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth()+1).padStart(2,'0')}-${String(date).padStart(2,'0')}`;
}
/* 阶段短名用两字，日历格子里放得下；主视觉卡上要念全称，单独一份 */
const PHASE_CARD={period:'经期',follicular:'卵泡期',fertile:'排卵期',luteal:'黄体期'};
/* 每个阶段一句照护提示——比"现在处于 X"多给一点能落地的事。
   长度控制在 15 字内：卡片左边只剩 ~15 个字宽，长一句就会折出孤字。 */
const PHASE_CARE={
 period:'多休息、保暖',
 follicular:'状态正好，适合一起出门走走',
 fertile:'身体状态不错，别熬夜就行',
 luteal:'容易情绪起伏，多担待一点'
};
function greetWord(){
 const h=new Date().getHours();
 if(h<5)return '夜深了';
 if(h<9)return '早上好';
 if(h<12)return '上午好';
 if(h<14)return '中午好';
 if(h<18)return '下午好';
 if(h<23)return '晚上好';
 return '夜深了';
}
/* 周期主视觉卡：左边问候 + 当前阶段 + 一句照护提示，右边环形进度标「周期第 N 天」。
   自己的大卡和「她的周期」共用这一个组件，口径不会分叉。 */
/* 受孕概率只按阶段给「低/中/高」三档，不给百分比：
   日历推算给不出那么细的结论，写死数字反而会被当成避孕依据。
   （Clue / Flo 也把这类提示写成"推算"，不承诺准确性。） */
const FERTILITY={period:['低','经期几乎不会受孕'],follicular:['中','越接近排卵日越高'],fertile:['高','排卵期前后，概率最高'],luteal:['低','排卵已过，概率回落']};
const FERTILITY_NOTE='按日历推算，仅供参考，不能作为避孕依据。';
/* 周期异常预警：阈值照「姨妈来了（Novawerk）」和「她扶 FloMe」那套——
   周期 <21 或 >35 天、经期 >7 天、长期没记录。看最近三次而不是只看最后一次，
   否则一次异常过一个月就被下一次正常值盖掉，等于没提醒。 */
function periodWarnings(d){
 const out=[],eps=d.episodes||[];
 if(eps.length<2)return out;
 const gaps=[];for(let i=1;i<eps.length;i++)gaps.push(eps[i].start-eps[i-1].start);
 const recent=gaps.slice(-3);
 const short=recent.filter(g=>g<21),long=recent.filter(g=>g>35);
 if(short.length)out.push(`最近三次里有 ${short.length} 次周期只有 ${short.join('、')} 天，偏短——可能是一次点滴出血，也可能记漏了`);
 if(long.length)out.push(`最近三次里有 ${long.length} 次周期到 ${long.join('、')} 天，偏长`);
 const len=d.lastEp?d.lastEp.length:0;
 if(len>7)out.push(`这次经期记了 ${len} 天，超过 7 天建议留意`);
 if(d.lastEp&&d.todayN-d.lastEp.start>Math.max(45,d.cycle+21))
  out.push(`距离上一次经期已经 ${d.todayN-d.lastEp.start} 天，可能漏记了`);
 return out;
}
function cycleHero(d,name=''){
 if(!d.items.length)return '';
 const ph=todayPhase(d);
 const cyc=Math.max(1,d.cycle);
 const startN=dayNum(d.last.body.start);
 const dayIn=Math.min(cyc,Math.max(1,d.todayN-startN+1));
 const pct=Math.max(4,Math.round(dayIn/cyc*100));   // 至少留一点弧，0% 看着像没加载出来
 const R=31,C=+(2*Math.PI*R).toFixed(1);
 const title=ph
  ?`当前阶段：${PHASE_CARD[ph.phase]}${ph.predicted?'<em class="cycle-hero-pred">预测</em>':''}`
  :(d.untilNext<0?`已推迟 ${-d.untilNext} 天`:'周期还在推算');
 const tip=d.inWindow
  ?`今天是经期第 ${d.dayOfPeriod} 天，${PHASE_CARE.period}`
  :(ph?PHASE_CARE[ph.phase]:(d.untilNext>=0?`预计还有 ${d.untilNext} 天`:'记一次就能重新推算'));
 const fert=ph?FERTILITY[ph.phase]:null;
 return `<div class="cycle-hero">
  <div class="cycle-hero-copy">
   <span class="cycle-hero-hi">${greetWord()}${name?'，'+esc(name):''}</span>
   <strong class="cycle-hero-phase">${title}</strong>
   <span class="cycle-hero-tip">${tip}</span>
   ${fert?`<span class="cycle-hero-fert f-${ph.phase}" title="${esc(FERTILITY_NOTE)}">受孕概率 <b>${fert[0]}</b><em>${esc(fert[1])}</em></span>`:''}
  </div>
  <div class="cycle-hero-side">
   <svg class="cycle-ring" viewBox="0 0 72 72" role="img" aria-label="周期第 ${dayIn} 天，共 ${cyc} 天">
    <circle class="ring-track" cx="36" cy="36" r="${R}"></circle>
    <circle class="ring-fill" cx="36" cy="36" r="${R}" stroke-dasharray="${C}" stroke-dashoffset="${(C*(1-pct/100)).toFixed(1)}" transform="rotate(-90 36 36)"></circle>
    <text x="36" y="36" text-anchor="middle" dominant-baseline="central">${dayIn}</text>
   </svg>
   <span class="cycle-hero-day">周期第 ${dayIn} 天</span>
  </div>
 </div>`;
}
/* 阶段进度条：一条 bar 摊开整个周期，游标就是今天，当前段高亮。
   ⚠️ flex 权重必须是「周期内第几天」这种相对天数，别拿绝对天数（dayNum）去当权重，
   否则某一段会被撑成两万多天、整条 bar 塌成一段。 */
function phaseBar(d){
 if(!d.items.length)return '';
 const s=dayNum(d.last.body.start),cyc=Math.max(1,d.cycle),len=Math.max(1,d.length),ovuRel=cyc-14;
 const segs=[['period','月经期',len],['follicular','卵泡期',Math.max(1,ovuRel-5-len)],
             ['fertile','排卵期',7],['luteal','黄体期',Math.max(1,cyc-ovuRel-2)]];
 const pos=Math.min(100,Math.max(0,(d.todayN-s+1)/cyc*100));
 const ph=todayPhase(d),cur=ph?ph.phase:'';
 return `<div class="phase-wrap"><div class="phase-bar">${segs.map(([k,nm,nd])=>`<span class="phase-seg s-${k}${k===cur?' current':''}" style="flex:${nd}" title="${nm}约 ${nd} 天"><b>${nm}</b><small>${nd}天</small></span>`).join('')}<i class="phase-cursor" style="left:${pos}%" aria-hidden="true"></i></div></div>`;
}
/* 顶部日历卡：整月网格 + 月份翻页 + 图例。
   原来这里只显示一周、下面再摆一份双月日历，等于同一件事看两遍；现在合成一张，整月铺开。 */
function periodTopCard(d){
 const day=state.periodDay||today(),y=Number(day.slice(0,4)),m=Number(day.slice(5,7));
 return `<div class="cal-bar"><div class="cal-bar-title"><strong>${m} 月</strong><span>${y} 年</span></div><div class="cal-bar-nav"><button type="button" class="cal-nav" data-action="period-month" data-delta="-1" aria-label="上个月">‹</button><button type="button" class="cal-today" data-action="period-pick" data-day="${today()}">今天</button><button type="button" class="cal-nav" data-action="period-month" data-delta="1" aria-label="下个月">›</button></div></div>${periodMonthGrid(y,m,d)}<p class="period-legend"><span class="lg-pill p-period">月经期</span><span class="lg-pill p-pred">预测经期</span><span class="lg-pill p-fertile">排卵期</span><span class="lg-pill p-ovu"><i></i>排卵日</span></p>`;
}
/* 选中那天的记录卡：一行一项，点开底部弹层选，选完立刻存。
   「月经来了 是/否」不是普通字段——它决定这天算不算经期，所以单独一行的分段按钮。 */
function periodLogCard(day){
 const d=periodData(),log=periodDayLogs()[day]||{},n=dayNum(day);
 const hit=periodEpisodeOf(d,n),ep=hit?hit.owner:null;
 const on=!!hit;
 const head=day===today()?'今天':`${Number(day.slice(5,7))} 月 ${Number(day.slice(8))} 日`;
 const rows=PERIOD_LOG_FIELDS.map(([key,name,ico])=>{
  const text=periodValueText(key,log);
  return `<button type="button" class="plog-row" data-action="period-log" data-field="${key}" data-day="${day}"><span class="plog-ico">${ico}</span><span class="plog-name">${name}</span><span class="plog-val">${esc(text)}</span>${text?'<span class="plog-add ghost">›</span>':`<span class="plog-add">${icon('plus')}</span>`}</button>`;
 }).join('');
 return `<section class="card period-log">
  <div class="plog-head"><div><strong>${head}</strong><small>${on?`经期第 ${n-hit.ep.start+1} 天`:'记下这一天，周期会更准'}</small></div>${ep?`<button type="button" class="link-btn" data-action="edit-record" data-id="${ep.id}">改经期长度</button>`:''}</div>
  <div class="plog-row"><span class="plog-ico">🩸</span><span class="plog-name">经期</span>${on
   ?`<span class="plog-seg"><button type="button" class="seg-btn outline" data-action="period-end" data-day="${day}">月经走了</button><button type="button" class="seg-btn" data-action="period-more" data-day="${day}">月经又来了</button></span>`
   :`<span class="plog-seg"><button type="button" class="seg-btn primary" data-action="period-start" data-day="${day}">月经来了</button></span>`}</div>
  ${rows}
  <button type="button" class="plog-row" data-action="period-log" data-field="content" data-day="${day}"><span class="plog-ico">📝</span><span class="plog-name">日记</span><span class="plog-val">${esc((log.content||'').slice(0,16))}</span><span class="plog-add">${log.content?'':icon('edit')}</span></button>
 </section>`;
}
/* 爱爱一天可能好几次，每次单独记措施和时间。
   老数据是 [2,4] 这种纯编号，统一读成 [{t:'',w:[2]},…]，界面只处理一种形状。 */
function periodSexEntries(b){
 return (b.sex||[]).map(item=>item&&typeof item==='object'
  ?{t:String(item.t||''),w:(item.w||[]).filter(x=>typeof x==='number')}
  :{t:'',w:typeof item==='number'?[item]:[]});
}
const CLOCK_H=[...Array(24)].map((_,i)=>String(i).padStart(2,'0'));
const CLOCK_M=[...Array(60)].map((_,i)=>String(i).padStart(2,'0'));
const WHEEL_H=44;   // 每格 44px，滚轮靠 scrollTop 换算选中项，改了要同步 CSS
function nowTime(){const d=new Date();return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;}
function wheelMarkup(t){
 const [h,m]=(t||'00:00').split(':');
 const col=(id,vals,cur)=>`<div class="wheel" data-wheel="${id}">${vals.map(v=>`<span class="wheel-item${v===cur?' on':''}">${v}</span>`).join('')}</div>`;
 return `<div class="wheel-wrap"><i class="wheel-band" aria-hidden="true"></i>${col('h',CLOCK_H,h||'00')}<span class="wheel-colon">:</span>${col('m',CLOCK_M,m||'00')}</div>`;
}
function bindWheel(root){
 $$('.wheel',root).forEach(w=>{
  const items=$$('.wheel-item',w);
  const idx=Math.max(0,items.findIndex(x=>x.classList.contains('on')));
  w.scrollTop=idx*WHEEL_H;
  w.onscroll=()=>{
   const i=Math.round(w.scrollTop/WHEEL_H);
   items.forEach((it,k)=>it.classList.toggle('on',k===i));
  };
 });
}
function periodSexSheet(day){
 const b=(periodDayRow(day)||{}).body||{};
 let entries=periodSexEntries(b);
 if(!entries.length)entries=[{t:nowTime(),w:[]}];
 let cur=0;
 openModal('爱爱',`<div class="ps-sheet" id="sex-sheet"></div>`,{sheet:true});
 const root=$('#sex-sheet');
 /* 切 tab / 重绘前先把屏幕上的选择读回 entries，否则会丢 */
 const read=()=>{
  const ways=$$('.ps-opt.on',root).map(o=>Number(o.dataset.pick));
  const wh=$('.wheel[data-wheel="h"]',root),wm=$('.wheel[data-wheel="m"]',root);
  const h=wh?CLOCK_H[Math.round(wh.scrollTop/WHEEL_H)]:null;
  const m=wm?CLOCK_M[Math.round(wm.scrollTop/WHEEL_H)]:null;
  entries[cur]={t:`${h||'00'}:${m||'00'}`,w:ways};
 };
 const draw=()=>{
  const e=entries[cur];
  root.innerHTML=`
   <div class="sex-tabs">${entries.map((x,i)=>`<button type="button" class="sex-tab${i===cur?' on':''}" data-tab="${i}">第 ${i+1} 次</button>`).join('')}<button type="button" class="sex-tab add" data-add="1" aria-label="再记一次">＋</button></div>
   <h3 class="ps-sub">爱爱</h3>
   <div class="ps-grid c5">${PERIOD_SEX.map(([name,emoji],i)=>psOption(i+1,name,emoji,e.w.includes(i+1))).join('')}</div>
   <h3 class="ps-sub">时间</h3>
   ${wheelMarkup(e.t)}
   <div class="form-actions"><button type="button" class="button" data-action="close-modal">取消</button>${entries.length>1?`<button type="button" class="button danger" id="sex-del">删除这次</button>`:''}<button type="button" class="button primary" id="sex-ok">确定</button></div>`;
  bindWheel(root);
  $('#sex-ok').onclick=async ev=>{
   read();
   ev.currentTarget.disabled=true;
   try{await periodSaveDay(day,{sex:entries.filter(x=>x.w.length).map(x=>({t:x.t,w:x.w}))});closeModal();}
   catch(err){toast(err.message);ev.currentTarget.disabled=false;}
  };
  const del=$('#sex-del');
  if(del)del.onclick=()=>{
   entries.splice(cur,1);
   if(!entries.length)entries=[{t:nowTime(),w:[]}];
   cur=Math.min(cur,entries.length-1);
   draw();
  };
 };
 root.onclick=e=>{
  const tab=e.target.closest('.sex-tab');
  if(tab&&tab.dataset.add){
   read();
   if(entries.length>=8)return toast('最多记八次');
   entries.push({t:nowTime(),w:[]});cur=entries.length-1;draw();return;
  }
  if(tab){read();cur=Number(tab.dataset.tab);draw();return;}
  const opt=e.target.closest('.ps-opt');
  if(opt){opt.classList.toggle('on');opt.setAttribute('aria-pressed',String(opt.classList.contains('on')));}
 };
 draw();
}
/* ———— 底部选择弹层 ————
   单选＝点一下就存并关掉；多选＝勾完点确定。全部走 periodSaveDay 落库。 */
function psOption(value,label,visual,on,style){
 return `<button type="button" class="ps-opt${on?' on':''}" data-pick="${esc(String(value))}" aria-pressed="${on}"><span class="ps-dot"${style?` style="${style}"`:''}>${visual||''}</span><span class="ps-label">${esc(label)}</span></button>`;
}
function periodChoiceSheet(day,field,title,items,cols=5){
 const cur=((periodDayRow(day)||{}).body||{})[field];
 openModal(title,`<div class="ps-sheet" id="ps-sheet"><div class="ps-grid c${cols}">${items.map(([v,label,visual,style])=>psOption(v,label,visual,String(cur)===String(v),style)).join('')}</div><p class="small-note">选一下就直接保存；再点一次同一项就是清除。</p></div>`,{sheet:true});
 $('#ps-sheet').onclick=async e=>{
  const btn=e.target.closest('.ps-opt');if(!btn)return;
  const picked=Number(btn.dataset.pick);
  try{await periodSaveDay(day,{[field]:String(cur)===String(picked)?null:picked});closeModal();}
  catch(err){toast(err.message);}
 };
}
function periodMultiSheet(day,field,title,groups,cols=4){
 const chosen=new Set((((periodDayRow(day)||{}).body||{})[field]||[]).map(String));
 const body=groups.map(([sub,items])=>`${sub?`<h3 class="ps-sub">${sub}</h3>`:''}<div class="ps-grid c${cols}">${items.map(([v,label,visual])=>psOption(v,label,visual,chosen.has(String(v)))).join('')}</div>`).join('');
 openModal(title,`<div class="ps-sheet" id="ps-sheet">${body}<div class="form-actions">${button('取消','close-modal')}<button class="button primary" id="ps-ok">确定</button></div></div>`,{sheet:true});
 const root=$('#ps-sheet');
 root.onclick=e=>{
  const btn=e.target.closest('.ps-opt');if(!btn)return;
  const on=!btn.classList.contains('on');
  // 「没有症状」和具体症状互斥，否则同一份记录自相矛盾
  if(on)$$('.ps-opt.on',root).forEach(o=>{if(o!==btn&&(btn.dataset.pick==='没有症状'||o.dataset.pick==='没有症状'))o.classList.remove('on');});
  btn.classList.toggle('on',on);btn.setAttribute('aria-pressed',String(on));
 };
 $('#ps-ok').onclick=async e=>{
  const picked=$$('.ps-opt.on',root).map(o=>o.dataset.pick);
  e.currentTarget.disabled=true;
  try{await periodSaveDay(day,{[field]:field==='sex'?picked.map(Number):picked});closeModal();}
  catch(err){toast(err.message);e.currentTarget.disabled=false;}
 };
}
/* 体重/体温：自绘数字键盘，比系统键盘稳（不会被弹起的键盘顶飞、也不用处理小数点和负号） */
function periodNumberSheet(day,field,title,unit,low,high){
 const cur=((periodDayRow(day)||{}).body||{})[field];
 let buf=cur!=null?String(cur):'';
 openModal(title,`<div class="ps-sheet" id="num-sheet"><div class="num-display"><output>${buf||'0'}</output><em>${unit}</em></div><div class="num-pad">${['1','2','3','4','5','6','7','8','9','.','0','del'].map(k=>`<button type="button" class="num-key" data-key="${k}">${k==='del'?'⌫':k}</button>`).join('')}</div><div class="form-actions">${button('取消','close-modal')}<button class="button primary" id="num-ok">确定</button></div></div>`,{sheet:true});
 const out=$('#num-sheet output');
 $('#num-sheet').onclick=e=>{
  const key=e.target.closest('.num-key');if(!key)return;
  const k=key.dataset.key;
  if(k==='del')buf=buf.slice(0,-1);
  else if(k==='.'){if(!buf.includes('.'))buf=(buf||'0')+'.';}
  else if(buf.length<5)buf=buf==='0'?k:buf+k;
  out.textContent=buf||'0';
 };
 $('#num-ok').onclick=async e=>{
  const value=Number(buf||0);
  if(!buf||!Number.isFinite(value)||value<low||value>high)return toast(`${title}需在 ${low}–${high} 之间`);
  e.currentTarget.disabled=true;
  try{await periodSaveDay(day,{[field]:value});closeModal();}
  catch(err){toast(err.message);e.currentTarget.disabled=false;}
 };
}
function periodLogSheet(field,day){
 const b=(periodDayRow(day)||{}).body||{};
 if(field==='content'){
  openModal('这一天的日记',`<form class="modal-form" id="pday-note"><label>想说的话<textarea name="content" maxlength="20000" placeholder="今天特别难受，或者想让他知道的…">${esc(b.content||'')}</textarea></label><p class="small-note">日记只存在这一天里，历史卡上不会重复显示。</p>${formError()}${modalActions()}</form>`,{sheet:true});
  $('#pday-note').onsubmit=async e=>{
   e.preventDefault();const submit=$('button[type=submit]',e.currentTarget);submit.disabled=true;
   try{await periodSaveDay(day,{content:String(new FormData(e.currentTarget).get('content')||'')});closeModal();}
   catch(err){$('.form-error',e.currentTarget).textContent=err.message;submit.disabled=false;}
  };
  return;
 }
 if(field==='flow')
  return periodChoiceSheet(day,'flow','流量',Object.entries(PERIOD_FLOW).map(([v,label])=>[v,label,`<i class="blood" style="--sz:${7+Number(v)*3}px"></i>`]));
 if(field==='color')
  return periodChoiceSheet(day,'color','颜色',Object.entries(PERIOD_COLOR).map(([v,[name,hex]])=>[v,name,'',`background:${hex}`]));
 if(field==='pain')
  return periodChoiceSheet(day,'pain','痛经',Object.entries(PERIOD_PAIN).map(([v,[name,emoji]])=>[v,name,emoji]));
 if(field==='mood')
  return periodChoiceSheet(day,'mood','心情',PERIOD_MOODS.map(([emoji,name],i)=>[i+1,name,emoji]));
 if(field==='sex')return periodSexSheet(day);
 if(field==='symptoms')
  // PERIOD_BODY_SYMPTOMS 是 [名称, 图标]，而 psOption 要 (值, 文案, 图标)，这里补一层
  return periodMultiSheet(day,'symptoms','症状',[['身体症状',PERIOD_BODY_SYMPTOMS.map(([name,emoji])=>[name,name,emoji])],['阴道分泌物',PERIOD_SECRETION.map(([name,emoji])=>[name,name,emoji])]],4);
 if(field==='weight')return periodNumberSheet(day,'weight','体重','公斤',20,300);
 if(field==='temp')return periodNumberSheet(day,'temp','体温','℃',30,45);
 if(field==='discharge'){
  openModal('白带',`<div class="ps-sheet" id="ps-sheet"><div class="ps-list">${Object.entries(PERIOD_DISCHARGE).map(([v,[name,desc]])=>`<button type="button" class="ps-item${String(b.discharge)===v?' on':''}" data-pick="${v}" aria-pressed="${String(b.discharge)===v}"><span class="ps-item-ico">💧</span><span class="ps-item-copy"><strong>${name}</strong><small>${desc}</small></span><i class="ps-radio"></i></button>`).join('')}</div></div>`,{sheet:true});
 $('#ps-sheet').onclick=async e=>{
  const btn=e.target.closest('.ps-item');if(!btn)return;
  try{await periodSaveDay(day,{discharge:Number(btn.dataset.pick)});closeModal();}catch(err){toast(err.message);}
  };
 }
}
function periodPage(){
 const d=periodData(),day=state.periodDay||today();
 /* 生理期不分「我的 / 她的」：两个人共同维护同一条周期，页面长得一样，谁记的都算数。 */
 const hero=d.items.length
  ?`<section class="card period-hero">${cycleHero(d,state.me.user.name)}<p class="meta">下次预计 ${Number(dayStr(d.nextStart).slice(5,7))} 月 ${Number(dayStr(d.nextStart).slice(8))} 日${d.estimated?'（参考值）':''} · ${d.untilNext>=0?`还有 ${d.untilNext} 天`:`已推迟 ${-d.untilNext} 天`}</p>${phaseBar(d)}<div class="stats-hero" style="grid-template-columns:repeat(3,minmax(0,1fr));margin:14px 0 0"><div class="stat-card"><span>平均周期</span><strong>${d.cycle}<em>天</em></strong></div><div class="stat-card"><span>平均经期</span><strong>${d.length}<em>天</em></strong></div><div class="stat-card"><span>记录天数</span><strong>${periodDayRows().length}<em>天</em></strong></div></div></section>`
  :`<section class="card"><div class="section-heading"><h2>🌸 开始记录</h2></div><p class="meta">点下面「月经来了 · 是」，把这次的第一天记下来；之后每天顺手记一点，周期会越来越准。谁记都行，两个人看到的是同一份。</p></section>`;
 /* 顺序：主视觉卡 → 整月日历 → 当天记录。日历只留这一份，下面不再重复 */
 const top=`<section class="card period-top-card">${periodTopCard(d)}</section>`;
 const log=periodLogCard(day);
 const spread=d.gaps.length>1?Math.max(...d.gaps)-Math.min(...d.gaps):0;
 const symCount={};
 periodDayRows().forEach(r=>(r.body.symptoms||[]).forEach(s=>{if(s!=='没有症状')symCount[s]=(symCount[s]||0)+1;}));
 d.items.forEach(r=>(r.body.symptoms||[]).forEach(s=>{if(s!=='没有症状')symCount[s]=(symCount[s]||0)+1;}));
 const syms=Object.entries(symCount).sort((a,b)=>b[1]-a[1]).slice(0,6);
 const total=Math.max(1,periodDayRows().length+d.episodes.length);
 const symBlock=syms.length?`<section class="card"><div class="section-heading"><h2>常出现的症状</h2></div>${syms.map(([s,n])=>`<div class="stat-row"><span>${esc(s)}</span><div class="stat-bar"><i style="width:${Math.round(n/total*100)}%"></i></div><b>${n} 次</b></div>`).join('')}<p class="small-note">${spread>7?`周期波动 ${spread} 天，波动大的时候多留一点休息的时间。`:'周期还算规律，保持记录会更准。'}</p></section>`:'';
 /* 一次月经一张卡：碎片行在统计上已经合并，列表里再拆成两三条只会让人以为记错了。
   「编辑 / 删除」对整次生效——删除会把这次的所有碎片行一起删掉。 */
 const hist=d.episodes.slice().reverse().map(e=>{
  const startIso=dayStr(e.start),endIso=dayStr(e.end),len=e.length;
  const logs=periodDayRows().filter(x=>{const n=dayNum(x.body.date);return n>=e.start&&n<=e.end;}).length;
  const author=e.frags[0].author;
  const symsAll=[...new Set(e.frags.flatMap(r=>r.body.symptoms||[]))];
  const words=e.frags.map(r=>r.body.content).filter(Boolean).join('\n');
  const ids=e.frags.map(r=>r.id).join(',');
  return `<article class="card"><div class="card-header">${avatar(author)}<div><strong>${esc(startIso.slice(5,7))} 月 ${esc(startIso.slice(8))} 日开始</strong><small>共 ${len} 天 · ${endIso.slice(5)} 结束${logs?` · 记了 ${logs} 天细节`:''}${e.frags.length>1?` · 分 ${e.frags.length} 段记的`:''} · ${esc(person(author).name)} 记录</small></div><div class="card-menu"><details class="more-menu"><summary aria-label="更多操作" title="更多操作">⋯</summary><div class="menu-pop"><button data-action="edit-record" data-id="${e.frags[0].id}">${icon('edit')} 编辑</button><button data-action="period-del-episode" data-ids="${ids}" class="danger">${icon('trash')} 删除这次</button></div></details></div></div>${symsAll.length?`<div class="tabs" style="flex-wrap:wrap;margin:8px 0 0">${symsAll.map(s=>`<span class="filter-chip">${esc(s)}</span>`).join('')}</div>`:''}${words?`<p class="card-text">${esc(words)}</p>`:''}</article>`;
 }).join('');
 /* 右上角不再放「记录经期」：记经期已经由下面记录卡的「月经来了 / 月经走了」接管，
    一个动作两个入口只会让人点错。这里换成进入数据分析页的入口。 */
 const headBar=heading('生理期','记下周期，把照顾提前一点。','');
 // 踩线才提示：正常的时候这块根本不存在，不占地方
 const warns=periodWarnings(d);
 const warnBlock=warns.length?`<section class="card period-warn"><strong>有几点需要留意</strong><ul>${warns.map(w=>`<li>${esc(w)}</li>`).join('')}</ul><small>按记录推算的提示，身体不舒服还是去看医生。</small></section>`:'';
 const entry=`<button type="button" class="card analysis-entry" data-action="period-analysis"><span class="ae-ico">📊</span><span class="ae-copy"><strong>数据分析</strong><small>周期、流量、痛经、体温的变化</small></span><span class="ae-go">${icon('arrow')}</span></button>`;
 return `${headBar}${hero}${warnBlock}${entry}${top}${log}${symBlock}${hist}`;
}
/* ───────────── 生理数据分析 ─────────────
   美柚那套「分析」页有十几个板块，这里按我们真正记过的维度落：数据完整度、规律度、
   预测、周期/经期变化、流量、痛经、颜色、症状、心情、白带、爱爱、体温、体重。
   （没有「便便」「开始时间」——我们没这两个字段，硬凑只会是空图。）
   图表全部手画 SVG/div，不引 Chart.js：离线 PWA 不能把核心页面挂在 CDN 上。 */
const PA_PURPLE='#A98BD8';
const paMean=a=>a.length?a.reduce((s,v)=>s+v,0)/a.length:0;
const paSd=a=>{if(a.length<2)return 0;const m=paMean(a);return Math.sqrt(paMean(a.map(v=>(v-m)**2)));};
const paRound=(v,n=0)=>{const p=10**n;return Math.round(v*p)/p;};
const paMD=s=>`${Number(String(s).slice(5,7))} 月 ${Number(String(s).slice(8,10))} 日`;

/* 分组柱：每天一组，左边本周期、右边近半年；没记的那根画虚线空框（照美柚的「未记录」） */
function paGrouped(rows,opt={}){
 const W=320,h=opt.h||(rows.length<=2?84:104),top=10,base=h-22,n=rows.length||1,slot=W/n;
 const max=opt.max||Math.max(1,...rows.flatMap(r=>[r.cur,r.hist]).filter(v=>typeof v==='number'));
 const bw=Math.min(12,slot*0.26);
 const y=v=>base-(base-top)*(v/max);
 const bar=(x,v,fill)=>typeof v==='number'&&v>0
  ?`<rect x="${x.toFixed(1)}" y="${y(v).toFixed(1)}" width="${bw.toFixed(1)}" height="${(base-y(v)).toFixed(1)}" rx="3" fill="${fill}"/>`
  :`<rect x="${x.toFixed(1)}" y="${base-18}" width="${bw.toFixed(1)}" height="18" rx="3" fill="none" stroke="var(--line)" stroke-dasharray="3 3"/>`;
 return `<svg class="pa-svg" viewBox="0 0 ${W} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(opt.aria||'')}">`
  +[0,.5,1].map(f=>`<line x1="0" x2="${W}" y1="${(top+(base-top)*f).toFixed(1)}" y2="${(top+(base-top)*f).toFixed(1)}" stroke="var(--line)" stroke-dasharray="2 4"/>`).join('')
  +rows.map((r,i)=>{const c=slot*i+slot/2;
    return bar(c-bw-2,r.cur,'var(--primary)')+bar(c+2,r.hist,PA_PURPLE)
     +`<text x="${c.toFixed(1)}" y="${base+14}" text-anchor="middle" class="pa-tick">${esc(r.label)}</text>`;}).join('')
  +`</svg>`;
}
/* 单系列竖柱：近期经期天数、每月爱爱次数 */
function paVBars(rows,opt={}){
 const W=320,h=opt.h||(rows.length<=3?86:96),top=12,base=h-22,n=rows.length||1,slot=W/n;
 const max=opt.max||Math.max(1,...rows.map(r=>r.v||0));
 const bw=Math.min(18,slot*0.44);
 return `<svg class="pa-svg" viewBox="0 0 ${W} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(opt.aria||'')}">`
  +`<line x1="0" x2="${W}" y1="${base}" y2="${base}" stroke="var(--line)"/>`
  +rows.map((r,i)=>{const c=slot*i+slot/2,v=r.v||0,hh=(base-top)*(v/max);
    // 0 也留一小截底色，否则连续几个空月看起来像图坏了
    const h1=v>0?hh:3;
    return `<rect x="${(c-bw/2).toFixed(1)}" y="${(base-h1).toFixed(1)}" width="${bw.toFixed(1)}" height="${h1.toFixed(1)}" rx="4" fill="${v>0?(r.now?'var(--primary)':'var(--soft-strong)'):'var(--line)'}"/>`
     +(v?`<text x="${c.toFixed(1)}" y="${(base-hh-6).toFixed(1)}" text-anchor="middle" class="pa-val">${v}</text>`:'')
     +`<text x="${c.toFixed(1)}" y="${base+14}" text-anchor="middle" class="pa-tick">${esc(r.label)}</text>`;}).join('')
  +`</svg>`;
}
/* 折线：体温 / 体重。只在首尾与最高最低处标数值，避免一串数字糊成一片 */
function paLine(pts,opt={}){
 const list=(pts||[]).filter(p=>typeof p.v==='number');
 if(list.length<2)return '';
 const W=320,h=opt.h||104,top=18,base=h-22;
 let lo=Math.min(...list.map(p=>p.v)),hi=Math.max(...list.map(p=>p.v));
 if(hi-lo<.4){hi+=.2;lo-=.2;}
 const X=p=>18+(W-36)*p.i/(list.length-1);
 const Y=v=>base-(base-top)*((v-lo)/(hi-lo));
 const color=opt.color||'#2F9E88';
 const marked=new Set([0,list.length-1,list.findIndex(p=>p.v===hi),list.findIndex(p=>p.v===lo)]);
 return `<svg class="pa-svg" viewBox="0 0 ${W} ${h}" width="100%" height="${h}" role="img" aria-label="${esc(opt.aria||'')}">`
  +`<line x1="0" x2="${W}" y1="${base}" y2="${base}" stroke="var(--line)"/>`
  +`<path d="${list.map((p,k)=>(k?'L':'M')+X(p).toFixed(1)+' '+Y(p.v).toFixed(1)).join(' ')}" fill="none" stroke="${color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`
  +list.map(p=>`<circle cx="${X(p).toFixed(1)}" cy="${Y(p.v).toFixed(1)}" r="3.5" fill="var(--surface)" stroke="${color}" stroke-width="2"/>`).join('')
  +list.map((p,k)=>marked.has(k)?`<text x="${X(p).toFixed(1)}" y="${(Y(p.v)-8).toFixed(1)}" text-anchor="middle" class="pa-val">${esc(opt.fmt?opt.fmt(p.v):p.v)}</text>`:'').join('')
  +`<text x="2" y="${base+13}" class="pa-tick">${esc(list[0].label)}</text>`
  +`<text x="${W-2}" y="${base+13}" text-anchor="end" class="pa-tick">${esc(list[list.length-1].label)}</text>`
  +`</svg>`;
}
/* 圆点矩阵：颜色、白带这种「一天一个颜色」的，用两行点比画柱状图直观 */
function paDotRows(rows){
 return `<div class="pa-dotmatrix">${rows.map(r=>`<div class="pa-dotrow"><span class="pa-dotlabel">${esc(r.name)}</span><div class="pa-dots">${r.cells.map(c=>c.color
   ?`<i class="pa-dot" style="background:${c.color}" title="${esc(c.tip||'')}"></i>`
   :`<i class="pa-dot hollow" title="${esc(c.tip||'')}"></i>`).join('')}</div></div>`).join('')}</div>`;
}

/* 把「经期段 + 日记录」摊成统计口径。所有 第N天 的序列都以「经期第几天」为横轴，
   这样不同长度的周期也能横向对齐——这也是美柚那套图能对比的原因。 */
function periodAnalysis(d){
 const eps=d.episodes||[],logs=periodDayLogs();
 const at=n=>logs[dayStr(n)]||null;
 const last=eps[eps.length-1]||null,prev=eps[eps.length-2]||null;
 const FIELDS=['flow','color','pain','sex','symptoms','mood','weight','discharge','temp'];
 // 数据完整度：经期里每一天都算一格，记了至少一项算填上
 let slots=0,filled=0;
 eps.forEach(e=>{for(let i=0;i<e.length;i++){slots++;const b=at(e.start+i);
  if(b&&FIELDS.some(k=>Array.isArray(b[k])?b[k].length:b[k]!=null&&b[k]!==''))filled++;}});
 const complete=slots?Math.round(filled/slots*100):0;
 const maxLen=Math.min(7,Math.max(1,...eps.map(e=>e.length)));
 const nth=key=>{
  const rows=[];
  for(let i=0;i<maxLen;i++){
   const cb=last&&i<last.length?at(last.start+i):null,cur=cb?(typeof cb[key]==='number'?cb[key]:null):null;
   const hist=eps.filter(e=>e!==last&&i<e.length).map(e=>at(e.start+i)?.[key]).filter(v=>typeof v==='number');
   if(cur==null&&!hist.length)continue;
   rows.push({label:`第${i+1}天`,cur,hist:hist.length?paRound(paMean(hist)):null});
  }
  return rows;
 };
 const nthColor=()=>{
  const n=Math.min(5,Math.max(1,...eps.map(e=>e.length))),cur=[],his=[];
  for(let i=0;i<n;i++){
   cur.push(last&&i<last.length?(at(last.start+i)?.color??null):null);
   const h=eps.filter(e=>e!==last&&i<e.length).map(e=>at(e.start+i)?.color).filter(v=>typeof v==='number');
   // 取众数：同一天在不同周期里颜色不一致时，代表值是"最常见的那一种"
   his.push(h.length?h.slice().sort((a,b)=>h.filter(v=>v===b).length-h.filter(v=>v===a).length)[0]:null);
  }
  return {cur,his,n};
 };
 const nthDischarge=()=>{
  const n=Math.min(5,Math.max(1,...eps.map(e=>e.length))),cur=[],his=[];
  for(let i=0;i<n;i++){
   cur.push(last&&i<last.length?(at(last.start+i)?.discharge??null):null);
   const h=eps.filter(e=>e!==last&&i<e.length).map(e=>at(e.start+i)?.discharge).filter(v=>typeof v==='number');
   his.push(h.length?paRound(paMean(h)):null);
  }
  return {cur,his,n};
 };
 const keySeries=(key,limit=12)=>{
  const rows=periodDayRows().filter(r=>typeof r.body[key]==='number')
   .sort((a,b)=>String(a.body.date).localeCompare(String(b.body.date)));
  return rows.slice(-limit).map(r=>({label:String(r.body.date).slice(5,10).replace('-','/'),v:r.body[key]}));
 };
 // 周期行：从新到旧。长度要记在「这一段开始的日子」上——09-29 那次到 10-26 是 27 天，
 // 所以 27 天属于 09-29 这一行；最后一段还没结束，只报「当前第 N 天」。
 const cycleRows=[];
 for(let i=eps.length-1;i>=0;i--){
  const e=eps[i],next=eps[i+1];
  if(next)cycleRows.push({date:e.start,gap:next.start-e.start});
  else cycleRows.push({cur:true,date:e.start,days:d.todayN-e.start+1});
 }
 const cycleMax=Math.max(1,...cycleRows.map(r=>r.cur?r.days:r.gap));
 // 近 6 个月爱爱
 const sexRows=periodDayRows().filter(r=>Array.isArray(r.body.sex)&&r.body.sex.length);
 const sexCount=sexRows.reduce((s,r)=>s+r.body.sex.length,0);
 const sexThisCycle=last?sexRows.filter(r=>{const n=dayNum(r.body.date);return n>=last.start&&n<=last.end;})
   .reduce((s,r)=>s+r.body.sex.length,0):0;
 const monthly=[];
 const y0=Number(today().slice(0,4)),m0=Number(today().slice(5,7));
 for(let k=5;k>=0;k--){
  let mm=m0-k,yy=y0;while(mm<1){mm+=12;yy-=1;}
  const pre=`${yy}-${String(mm).padStart(2,'0')}`;
  monthly.push({label:`${mm}月`,v:sexRows.filter(r=>String(r.body.date).slice(0,7)===pre)
    .reduce((s,r)=>s+r.body.sex.length,0),now:k===0});
 }
 const symCount={};
 periodDayRows().concat(eps.map(e=>e.rec)).forEach(r=>(r.body.symptoms||[]).forEach(s=>{
  if(s!=='没有症状')symCount[s]=(symCount[s]||0)+1;}));
 const moodCount={};
 periodDayRows().forEach(r=>{if(r.body.mood)moodCount[r.body.mood]=(moodCount[r.body.mood]||0)+1;});
 // 规律度：只看周期波动。样本 <3 个间隔时给参考值，别硬编一个分数骗人
 const sd=paSd(d.gaps);
 const score=d.gaps.length>=2?Math.min(99,Math.max(40,Math.round(100-Math.min(45,Math.max(0,(sd-1.5)*6))))):null;
 return {eps,last,prev,complete,slots,filled,flow:nth('flow'),pain:nth('pain'),
  color:nthColor(),discharge:nthDischarge(),cycleRows,cycleMax,
  sexCount,sexThisCycle,monthly,symCount,moodCount,sd,score,
  temp:keySeries('temp'),weight:keySeries('weight')};
}

/* 分析页本体：一个板块一块卡，顺序照「先结论后细节」排。 */
const PA_DIS_COLORS={1:'#CFBBA6',2:'#B9A183',3:'#E0C58F',4:'#A6D5E4',5:'#78C4D8'};
function periodAnalysisPage(){
 const d=periodData(),a=periodAnalysis(d);
 /* 返回走顶栏那个箭头（together 的子页都这样），页面里不再重复放一个 */
 const back=`<div class="page-heading"><div><h1>生理数据分析</h1><p>把这半年的记录，摊成看得懂的变化。</p></div></div>`;
 if(!a.eps.length)return back+`<section class="card"><p class="meta">还没有经期记录。回到生理期页点一次「月经来了」，这里就会开始长出图表。</p><div class="inline-actions">${button('回到生理期','period-back','primary')}</div></section>`;
 const sec=(h2,body,sub='')=>`<section class="card pa-card"><div class="section-heading"><h2>${h2}</h2>${sub?`<span class="pa-sub">${esc(sub)}</span>`:''}</div>${body}</section>`;
 const legend=items=>`<p class="pa-legend">${items.map(([c,t,empty])=>`<span><i class="pa-lg-dot${empty?' hollow':''}" style="${empty?'':`background:${c}`}"></i>${esc(t)}</span>`).join('')}</p>`;
 const warns=periodWarnings(d);

 /* ① 概览：规律度 + 数据完整度 + 三个基本盘 */
 const grade=a.score==null?'样本还太少':a.score>=85?'很规律':a.score>=70?'比较规律':a.score>=55?'有些波动':'波动明显';
 const note=a.score==null?'至少记满 3 个完整周期，规律度才有意义。'
   :a.score>=85?'继续保持，预测会越来越准。'
   :`周期波动 ${paRound(a.sd,1)} 天，预测日期按前后 ±${Math.max(2,Math.round(a.sd))} 天准备更稳妥。`;
 const overview=`<section class="card pa-overview">
  <div class="pa-hero-row">
   <div class="pa-ring" style="background:conic-gradient(var(--primary) ${(a.score||0)*3.6}deg, var(--soft) 0)"><span><b>${a.score==null?'--':a.score}</b><small>规律度</small></span></div>
   <div class="pa-hero-copy"><h3>${grade}</h3><p>${esc(note)}</p>
    <div class="pa-meter"><i style="width:${a.complete}%"></i></div>
    <small>完整度 ${a.complete}%　·　已记 ${a.filled}/${a.slots} 天</small></div>
  </div>
  <div class="pa-stats">
   <div><span>平均周期</span><strong>${d.cycle}<em>天</em></strong></div>
   <div><span>平均经期</span><strong>${d.length}<em>天</em></strong></div>
   <div><span>记录天数</span><strong>${periodDayRows().length}<em>天</em></strong></div>
  </div>
  ${warns.length?`<div class="pa-warns"><strong>需要留意</strong>${warns.map(w=>`<p>${esc(w)}</p>`).join('')}<small>按记录推算，不能替代医生判断。</small></div>`:''}
  <p class="pa-mini">受孕概率为日历推算（低 / 中 / 高），不能作为避孕依据。</p>
  </section>`;

 /* ② 经期预测：一周日期条，正中那天是预测日，左右两天算"可能" */
 const pred=(()=>{
  if(d.nextStart==null)return '';
  const cells=[];
  for(let i=-3;i<=3;i++){
   const n=d.nextStart+i,iso=dayStr(n),cls=i===0?' on':Math.abs(i)<=2?' soft':'';
   const wd='日一二三四五六'[new Date(n*DAY_MS).getUTCDay()];
   cells.push(`<span class="pa-day${cls}"><b>${Number(iso.slice(8))}</b><small>周${wd}</small></span>`);
  }
  const due=d.untilNext;
  return sec('🔮 经期预测',
   `<p class="pa-lead">预测下次经期将于 <b>${paMD(dayStr(d.nextStart))}</b> 开始，${due>=0?`距离经期开始还有 <b>${due}</b> 天`:`已经推迟 <b>${-due}</b> 天`}。</p>
    <div class="pa-week">${cells.join('')}</div>
    <p class="pa-legend"><span><i class="pa-lg-dot" style="background:var(--primary)"></i>预测开始日</span><span><i class="pa-lg-dot" style="background:var(--soft-strong)"></i>可能的开始日</span></p>`,
   d.estimated?'参考值':'');
 })();

 /* ③ 周期变化：最近一个周期 + 历史横向条 */
 const cycleSec=(()=>{
  const rows=a.cycleRows.slice(0,6).map(r=>{
   if(r.cur)return `<div class="pa-row"><span class="pa-date">${paMD(dayStr(r.date))}</span><span class="pa-chip">当前第 ${r.days} 天</span><span class="pa-track"><i style="width:${Math.round(r.days/a.cycleMax*100)}%"></i></span><b>${r.days}天</b></div>`;
   const diff=r.gap-Math.round(d.cycle);
   return `<div class="pa-row"><span class="pa-date">${paMD(dayStr(r.date))}</span><span class="pa-diff${diff<0?' early':diff>0?' late':''}">${diff===0?'准时':diff<0?`提前 ${-diff} 天`:`推迟 ${diff} 天`}</span><span class="pa-track"><i style="width:${Math.round(r.gap/a.cycleMax*100)}%"></i></span><b>${r.gap}天</b></div>`;
  }).join('');
  const gapNow=a.eps.length>1?a.eps[a.eps.length-1].start-a.eps[a.eps.length-2].start:null;
  const diffNow=gapNow==null?null:gapNow-Math.round(d.cycle);
  const range=a.eps.length>1?`${paMD(dayStr(a.eps[a.eps.length-2].start))} – ${paMD(dayStr(a.eps[a.eps.length-1].start-1))}`:'';
  const kpi=gapNow==null?'':`<div class="pa-kpi"><div><span>最近 1 个周期</span><strong>${gapNow} 天 <em class="pa-tag${gapNow>=21&&gapNow<=35?'':' warn'}">${gapNow>=21&&gapNow<=35?'正常':'需留意'}</em></strong></div>
   <div><span>比平均周期</span><strong>${diffNow===0?'相同':diffNow<0?`短 ${-diffNow} 天`:`长 ${diffNow} 天`}</strong></div></div>`;
  return sec('🗓 周期变化',kpi+`<p class="pa-mini">近期周期天数${range?`　·　最近一次 ${range}`:''}</p><div class="pa-list">${rows}</div>`);
 })();

 /* ④ 经期变化：本次天数 + 近期柱状 */
 const lenSec=(()=>{
  const bars=a.eps.slice(-6).map((e,i,arr)=>({label:`${Number(dayStr(e.start).slice(5,7))}/${Number(dayStr(e.start).slice(8))}`,v:e.length,now:i===arr.length-1}));
  const lastLen=a.last?a.last.length:0,prevLen=a.prev?a.prev.length:null;
  const diff=prevLen==null?null:lastLen-prevLen;
  return sec('💧 经期变化',
   `<div class="pa-kpi"><div><span>本次经期</span><strong>${lastLen} 天 <em class="pa-tag${lastLen>=2&&lastLen<=7?'':' warn'}">${lastLen>=2&&lastLen<=7?'正常':'需留意'}</em></strong></div>
     <div><span>和上个周期</span><strong>${diff==null?'—':diff===0?'相同':diff>0?`多 ${diff} 天`:`少 ${-diff} 天`}</strong></div></div>
    <p class="pa-mini">近期经期天数</p>${paVBars(bars,{aria:'近期每次经期的天数'})}`);
 })();

 /* ⑤ 流量 / ⑥ 痛经：同一套分组柱，两边的档位都是 1–5 */
 const flowRows=a.flow;
 const flowText=(()=>{
  const cur=flowRows.filter(r=>r.cur!=null),his=flowRows.filter(r=>r.hist!=null);
  if(!cur.length)return '这个周期还没记流量';
  if(!his.length)return '再多记一次经期，就能和近半年对比';
  const x=paMean(cur.map(r=>r.cur)),y=paMean(his.map(r=>r.hist)),dd=x-y;
  return Math.abs(dd)<.4?'和近半年差不多':dd>0?`比近半年偏多一点（约高 ${paRound(dd,1)} 档）`:`比近半年偏少一点（约低 ${paRound(Math.abs(dd),1)} 档）`;
 })();
 const flowSec=flowRows.length?sec('🩸 流量变化',
  `<p class="pa-kpi-line">本周期流量对比近半年：<b>${esc(flowText)}</b></p>${paGrouped(flowRows,{max:5,aria:'按经期第几天对比本周期与近半年的经量档位'})}${legend([['var(--primary)','本周期'],['#A98BD8','近半年'],['','未记录',1]])}`):'';

 const painRows=a.pain;
 const painText=(()=>{
  const cur=painRows.filter(r=>r.cur!=null);
  if(!cur.length)return '这个周期还没记痛经';
  const peak=cur.slice().sort((x,y)=>(y.cur||0)-(x.cur||0))[0];
  if(!peak.cur)return '这个周期完全没痛，挺好的';
  const nm=(PERIOD_PAIN[peak.cur]||[])[0]||'';
  return `这个周期最痛是「${nm}」，出现在${peak.label}`;
 })();
 const painSec=painRows.length?sec('⚡ 痛经情况',
  `<p class="pa-kpi-line">${esc(painText)}</p><div class="pa-offset">${paGrouped(painRows,{max:5,aria:'按经期第几天对比本周期与近半年的痛经程度'})}</div>${legend([['var(--primary)','本周期'],['#A98BD8','近半年'],['','未记录',1]])}`):'';

 /* ⑦ 颜色变化：一天一个点 */
 const colBuf=a.color,usedColors=new Set([...colBuf.cur,...colBuf.his].filter(Boolean));
 const colorSec=usedColors.size?sec('🎨 颜色变化',
  `${paDotRows([{name:'本周期',cells:colBuf.cur.map((v,i)=>({color:v?PERIOD_COLOR[v][1]:null,tip:v?`第${i+1}天 ${PERIOD_COLOR[v][0]}`:`第${i+1}天未记录`}))},
    {name:'近半年',cells:colBuf.his.map((v,i)=>({color:v?PERIOD_COLOR[v][1]:null,tip:v?`第${i+1}天 ${PERIOD_COLOR[v][0]}`:`第${i+1}天未记录`}))}])}
   ${legend([...usedColors].map(v=>[PERIOD_COLOR[v][1],PERIOD_COLOR[v][0]]).concat([['','未记录',1]]))}`):'';

 /* ⑧ 症状排行：沿用工具页的 .stat-row，不另造图表 */
 const syms=Object.entries(a.symCount).sort((x,y)=>y[1]-x[1]).slice(0,6);
 const symSec=syms.length?sec('💊 常出现的症状',
  syms.map(([s,n])=>`<div class="stat-row"><span>${esc(s)}</span><div class="stat-bar"><i style="width:${Math.round(n/syms[0][1]*100)}%"></i></div><b>${n} 次</b></div>`).join('')):'';

 /* ⑨ 心情 */
 const moods=Object.entries(a.moodCount).sort((x,y)=>y[1]-x[1]).slice(0,8);
 const moodSec=moods.length?sec('😊 心情',
  `<div class="pa-chips">${moods.map(([id,n])=>{const m=PERIOD_MOODS[Number(id)-1]||['🙂','心情'];return `<span class="pa-chip-mood"><i>${m[0]}</i>${esc(m[1])}<b>${n}</b></span>`;}).join('')}</div>
   <p class="pa-mini">共 ${Object.values(a.moodCount).reduce((s,n)=>s+n,0)} 次心情记录</p>`):'';

 /* ⑩ 白带：点阵，颜色按 5 档 */
 const disBuf=a.discharge;
 const disSec=(disBuf.cur.some(Boolean)||disBuf.his.some(Boolean))?sec('💧 白带变化',
  `${paDotRows([{name:'本周期',cells:disBuf.cur.map((v,i)=>({color:v?PA_DIS_COLORS[v]:null,tip:v?`第${i+1}天 ${PERIOD_DISCHARGE[v][0]}`:`第${i+1}天未记录`}))},
    {name:'近半年',cells:disBuf.his.map((v,i)=>({color:v?PA_DIS_COLORS[v]:null,tip:v?`第${i+1}天 ${PERIOD_DISCHARGE[v][0]}`:`第${i+1}天未记录`}))}])}
   ${legend(Object.entries(PERIOD_DISCHARGE).map(([v,it])=>[PA_DIS_COLORS[v],it[0]]).concat([['','未记录',1]]))}`):'';

 /* ⑪ 爱爱 */
 const sexSec=sec('💗 爱爱',
  `<p class="pa-kpi-line">本周期 <b>${a.sexThisCycle}</b> 次，累计 <b>${a.sexCount}</b> 次</p>
   <p class="pa-mini">近 6 个月</p>${paVBars(a.monthly,{aria:'近 6 个月每个月的次数'})}`);

 /* ⑫ 体温 / ⑬ 体重：有两次以上记录才画线 */
 const tempSec=a.temp.length>1?sec('🌡️ 体温',paLine(a.temp.map((p,i)=>({...p,i})),{color:'#2F9E88',fmt:v=>v.toFixed(1)+'℃',aria:'体温记录折线'})):'';
 const weightSec=a.weight.length>1?sec('⚖️ 体重',paLine(a.weight.map((p,i)=>({...p,i})),{color:'#7A93C4',fmt:v=>v.toFixed(1),aria:'体重记录折线'})):'';

 const tips=`<p class="small-note pa-foot">图表只反映记过的那几天。想让它更准，经期每天顺手点两下就够了。</p>`;
 return `${back}${overview}${pred}${cycleSec}${lenSec}${flowSec}${painSec}${colorSec}${symSec}${moodSec}${disSec}${sexSec}${tempSec}${weightSec}${tips}`;
}

function periodForm(record=null, presetDay=null){
 /* 这一层只管「这次经期从哪天到哪天」；每天的身体细节走日记录卡。
    presetDay：从日历格子点进来的那天，直接预填到「这次经期开始于」。 */
 const b=record?.body||{},d=periodData(),chosen=new Set(b.symptoms||[]);
 const chips=PERIOD_SYMPTOMS.map(s=>`<button type="button" class="sym-chip${chosen.has(s)?' on':''}" data-name="${s}" aria-pressed="${chosen.has(s)}">${s}</button>`).join('');
 // 老数据里 flow 是「少/中/多」，换成最近的档位显示，不至于打开就是空白
 const flowVal=typeof b.flow==='number'?b.flow:({'少':2,'中':3,'多':4}[b.flow]||'');
 openModal(record?'编辑这次经期':'记录这次经期',`<form class="modal-form" id="period-form">${field('这次经期开始于','start',b.start||presetDay||today(),'date','required')}<div class="form-row">${field('经期几天','length',b.length??d.length,'number','min="1" max="15"')}${field('周期几天','cycle',b.cycle??d.cycle,'number','min="15" max="60"')}</div>${selectField('整体经量','flow',[['','不记'],...Object.entries(PERIOD_FLOW)],flowVal)}<label>身体的感受（可多选）</label><div class="sym-chips">${chips}</div><label>想说的话（可选）<textarea name="content" maxlength="20000" placeholder="这次特别难受，或者想让他知道的…">${esc(b.content||'')}</textarea></label><p class="small-note">周期默认按历史记录的平均值填好，也可以手动改。数据加密保存，两个人一起维护同一条周期。</p>${formError()}${modalActions()}</form>`);
 $('#period-form').onclick=e=>{const chip=e.target.closest('.sym-chip');if(!chip)return;chip.classList.toggle('on');chip.setAttribute('aria-pressed',String(chip.classList.contains('on')));};
 $('#period-form').onsubmit=async e=>{
  e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);
  submit.disabled=true;
  try{
   const f=new FormData(form);
   const flow=f.get('flow');
   const body={start:f.get('start'),length:Number(f.get('length')||5),cycle:Number(f.get('cycle')||d.cycle),
    ...(flow?{flow:Number(flow)}:{}),symptoms:$$('.sym-chip.on',form).map(c=>c.dataset.name),
    content:String(f.get('content')||'')};
   if(record)await put('/records/'+record.id,{kind:'period',body});
   else await post('/records',{kind:'period',body,client_id:uuid()});
   closeModal();await refresh();toast('已记下这次');
  }catch(err){$('.form-error',form).textContent=err.message;}
  finally{submit.disabled=false;}
 };
}

/* ———— 共同歌单 ————
   不放隐藏播放器：每首歌就是一个原生 <audio>，能拖进度、能暂停，
   手机上也不会有被浏览器拦下来的自动播放。 */
function songMedia(r){return (r.media||[]).find(m=>String(m.mime||'').startsWith('audio/'))||null;}
function musicCard(r){
 const b=r.body||{},m=songMedia(r),own=r.author===state.me.user.id;
 return `<article class="card music-card kind-music"><div class="card-header">${avatar(r.author)}<div><strong>${esc(person(r.author).name)} 放进来的歌</strong><small>${esc(dateLabel(r.created))}</small></div><div class="card-menu">${own?`<details class="more-menu"><summary aria-label="更多操作" title="更多操作">⋯</summary><div class="menu-pop"><button data-action="edit-record" data-id="${r.id}">${icon('edit')} 编辑</button><button data-action="delete-record" data-id="${r.id}" class="danger">${icon('trash')} 删除</button></div></details>`:''}</div></div><h3 class="card-title">${esc(b.title||'未命名')}</h3>${b.content?`<p class="card-text">${esc(b.content)}</p>`:''}${m?`<audio class="song-audio" controls preload="none" src="/media/${m.id}"></audio>`:'<p class="small-note">这首歌还没有音频文件，编辑时补上一个。</p>'}</article>`;
}
function musicPage(){
 const items=recordsOf('music').slice().sort((a,b)=>b.created-a.created);
 const back='';
 return `${heading('共同歌单','把属于我们的歌，放在一起。','new-music','添加一首歌','heart')}${back}<p class="hint">放进来的一定要是你们自己的音频文件（mp3 / m4a / wav 都行）。歌单只有你们两个人能听，不会上传到任何第三方音乐平台。</p>${items.length?items.map(musicCard).join(''):empty('歌单还空着','那首一听就想起对方的歌，值得放进来。','new-music','添加第一首')}`;
}
function musicForm(record=null){
 const b=record?.body||{};
 openModal(record?'编辑这首歌':'添加一首歌',`<form class="modal-form" id="music-form"><label>歌名<input name="title" required maxlength="120" value="${esc(b.title||'')}" placeholder="例如：晚安"></label><label>歌手，或者想说的话<input name="content" maxlength="200" value="${esc(b.content||'')}" placeholder="例如：陈奕迅 · 那年冬天一直循环"></label><label>音频文件${record?'（不换就留空）':''}<input name="file" type="file" accept="audio/*" ${record?'':'required'}></label><p class="small-note">建议 mp3，单曲控制在 10 MB 以内，手机流量也不会太心疼。</p>${formError()}${modalActions()}</form>`);
 $('#music-form').onsubmit=async e=>{
  e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);submit.disabled=true;
  try{
   const data=Object.fromEntries(new FormData(form)),file=$('[name=file]',form).files[0];
   let media=record?(record.media||[]).map(m=>m.id):[];
   if(file&&file.size>20*1024*1024)throw new Error('音频超过 20 MB，换个小一点的吧');
   if(file)media=[(await uploadFile(file)).id];
   const body={title:data.title,content:data.content||'',media};
   if(record)await put('/records/'+record.id,{kind:'music',body});
   else await post('/records',{kind:'music',body,client_id:uuid()});
   closeModal();await refresh();toast('已经放进歌单了');
  }catch(err){$('.form-error',form).textContent=err.message;}
  finally{submit.disabled=false;}
 };
}
function personalWishPage(){const wishes=recordsOf('personal_wish');return `${heading('个人心愿','写下的人可以直接回看，对方输入一次密码后就能一直看到。','new-personal-wish','许下心愿','heart')}<p class="hint">心愿名称彼此可见。密码至少 6 位（建议纯数字），每条心愿都要不同；告诉对方后，对方解锁一次即可永久查看。</p>${wishes.length?wishes.map(personalWishCard).join(''):empty('留一份只差密码就能打开的心愿','对方能看见心愿名称，具体内容仍由你掌握。','new-personal-wish','许下第一份心愿')}`;}
function dashboardPage(){
 const d=state.dashboard;
 const back='';
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
 const back='';
 if(!w)return `${heading('回忆周报','把这一周，收进一封小小的信。')}${back}<p class="hint">正在整理这一周…</p>`;
 const off=w.offset||0,short=d=>d.slice(5).replace('-','.');
 const delta=w.delta>0?`比上一周多写了 ${w.delta} 条`:w.delta<0?`比上一周少了 ${-w.delta} 条`:'和上一周一样多';
 const streakLine=w.streak>0?`🔥 已连续记录 ${w.streak} 天`:(w.last_record_days_ago!=null?`上次记录在 ${w.last_record_days_ago} 天前`:'还没有开始记录');
 const kinds=Object.entries(w.by_kind||{}).filter(([k])=>kindLabel[k]).sort((a,b)=>b[1]-a[1]),total=Math.max(1,w.total||0);
 const kindRows=kinds.length?kinds.map(([k,n])=>`<div class="stat-row"><span>${kindLabel[k]}</span><div class="stat-bar"><i style="width:${Math.round(n/total*100)}%"></i></div><b>${n}</b></div>`).join(''):'<p class="meta">这一周还没有记录。</p>';
 const moods=Object.entries(w.moods||{}).sort((a,b)=>b[1]-a[1]),peak=Math.max(1,...moods.map(x=>x[1]));
 const moodRows=moods.length?moods.map(([e,n])=>`<div class="mood-stat"><span class="mood-emoji">${esc(e)}</span><div class="stat-bar"><i style="width:${Math.round(n/peak*100)}%"></i></div><b>${n}</b></div>`).join(''):'<p class="meta">这一周还没有心情记录。</p>';
 return `${heading('回忆周报','把这一周，收进一封小小的信。')}${back}<div class="tabs week-switch"><button data-action="week-prev">← 上一周</button><span class="week-range">${w.start.slice(0,4)} 年 · ${short(w.start)} – ${short(w.end)}</span><button data-action="week-next" ${off>=0?'disabled':''}>下一周 →</button></div><section class="card week-hero"><h2>${esc(w.message)}</h2><p class="meta">${esc(delta)}${w.top_mood?` · 这周最常见的心情是 ${esc(w.top_mood)}`:''}<br><strong style="color:var(--accent)">${esc(streakLine)}</strong></p></section><div class="stats-hero"><div class="stat-card"><span>记录</span><strong>${w.total}<em>条</em></strong></div><div class="stat-card"><span>有记录的天数</span><strong>${w.days_active}<em>天</em></strong></div><div class="stat-card"><span>照片</span><strong>${w.photos}<em>张</em></strong></div><div class="stat-card"><span>互动</span><strong>${(w.likes||0)+(w.comments||0)}<em>次</em></strong></div></div><div class="grid-2"><section class="card"><div class="section-heading"><h2>这一周写了什么</h2></div>${kindRows}</section><section class="card"><div class="section-heading"><h2>心情分布</h2></div>${moodRows}</section></div>${w.highlights.length?`<div class="section-heading"><h2>${icon('heart')} 本周精选</h2></div>${w.highlights.map(recordCard).join('')}`:empty('这一周的信封还是空的','写下一点什么，下一封周报就会有了。','compose','记录此刻')}<div class="inline-actions" style="margin-top:16px">${button('复制文字版','week-copy','small soft','download')}</div>`;
}
/* ── 链路检测 ──────────────────────────────────────────────────────────
   多线路的真实探测能力在原生层（MainActivity.probeAll），网页侧拿不到，
   所以 App 内走 LinkBridge 插件；浏览器里退化成 fetch 打点 —— 跨域用
   mode:'no-cors' 拿不到状态码，但能区分「连上了」和「压根没连上」，够判死活。
   切换线路只在 App 内可用：换域要重种登录 cookie，那是原生层的活。

   ⚠️ 浏览器里跨域打点有两个死穴，以前没处理，表现出来就是「只有本网址可达」：
   ① CSP 的 connect-src 只写了 'self' → fetch 直接被拦，报错在控制台，页面上
      只剩「不可达」。现在服务端按 SPACE_ROUTES 把四条线路的 origin 都放通了；
   ② fetch 没有默认超时，线路挂着不响应会一直等，整页卡在「检测中」。加 8s abort。 */
let BROWSER_ROUTES=[
 {name:'Cloudflare 隧道',url:'https://love.yangyuhui.xyz/'},
 {name:'节点小宝',url:'https://love-space.iepose.cn/'},
 {name:'腾讯云 CloudBase',url:'https://love.350921.xyz/'},
 {name:'Lucky 直连',url:'https://love-space.yangyuhui.xyz:4019/'},
 {name:'内网直连',url:'http://192.168.31.95:1314/'}];
/* 服务端才是线路清单的权威来源（app/config.py: SPACE_ROUTES）。
   拿到就覆盖本地这份兜底清单，省得改一处漏两处。 */
async function loadRoutes(){
 try{
  const res=await fetch('/api/routes',{cache:'no-store'});
  if(!res.ok)return;
  const data=await res.json();
  const list=(data?.routes||[]).filter(r=>r&&r.url);
  if(list.length)BROWSER_ROUTES=list.map(r=>({name:r.name||r.url,url:r.url}));
 }catch{}
}
const PROBE_ABORT_MS=8000;
function linkTone(ms){if(ms<0)return 'var(--muted)';if(ms<=300)return 'var(--green)';if(ms<=1200)return 'var(--amber)';return 'var(--danger)';}
function linkText(ms){return ms<0?'不可达':ms+' ms';}
function linkBridge(){return window.Capacitor?.Plugins?.LinkBridge||null;}
/* 桥不可靠：远程加载模式下 Capacitor 桥不保证注入（window.Capacitor 可能整个不在），
   但原生端 appendUserAgent 加了 LoveSpaceApp/<版本>，UA 里一定有 —— 用它兜底识别。 */
function isNativeApp(){return Boolean(linkBridge())||/LoveSpaceApp\//.test(navigator.userAgent||'');}
/* 桥不在时的备用通道：主框架导航到自定义 scheme，原生 WebViewClient 的
   shouldOverrideUrlLoading 会截到并 return true（页面原地不动，不会弹错误页）。
   离线页的 lovespace://retry 就是这么工作的，已经验证过。 */
function nativeScheme(u){try{location.href='lovespace://'+u;}catch{}}
function linkCheckPage(){
 const rows=state.linkRoutes,native=isNativeApp();
 const body=!rows
  ?empty('还没有检测结果','点上面的「开始检测」，会依次测一遍每条线路的响应速度。')
  :`<div class="link-list">${rows.map(r=>`<div class="link-row${r.current?' is-current':''}">
      <div class="link-row-main"><strong>${esc(r.name)}</strong><small class="meta">${esc(String(r.url||'').replace(/^https?:\/\//,'').replace(/\/$/,''))}</small></div>
      <span class="link-ms" style="color:${linkTone(r.ms)}">${linkText(r.ms)}</span>
      ${r.current?'<span class="status-pill sent">当前</span>':(r.best?'<span class="status-pill">最快</span>':'')}
      ${r.current||!native?'':`<button class="link-use" data-action="link-use" data-id="${esc(r.url)}">切换</button>`}
    </div>`).join('')}</div>`;
 return `${heading('链路检测','看看现在哪条线路最快，也可以手动切换。')}
  <div class="inline-actions" style="margin:-6px 0 14px">
   <button class="button primary" data-action="link-probe" ${state.linkProbing?'disabled':''}>${icon('gear')} ${state.linkProbing?'检测中…':'开始检测'}</button>
  </div>
  <section class="card">${body}</section>
  <p class="hint">${native
    ?'检测在手机本地直接发起，不经过服务器；数值是访问 /api/status 的往返耗时。在这里切换后，下次打开 App 会直接走这条线路。平时不会自动切换——只有当页面超过 6 秒还加载不出来、或这条线路连不上时，才会自动择优换一条。'
    :'当前在浏览器里，只能测到「跨域是否连得上」，数值仅供参考；完整检测与线路切换请在 App 内操作。'}</p>`;
}
async function probeRoutesInBrowser(){
 const origin=location.origin;
 const out=await Promise.all(BROWSER_ROUTES.map(async r=>{
  const base=String(r.url||'').replace(/\/$/,''),same=base===origin;
  // 打 /api/status 而不是首页：体积小，且能顺带确认后端还活着。加时间戳避开缓存。
  const url=base+'/api/status?_p='+Date.now();
  const ctrl=typeof AbortController==='function'?new AbortController():null;
  const timer=ctrl?setTimeout(()=>ctrl.abort(),PROBE_ABORT_MS):null;
  const t0=performance.now();
  try{
   if(same)await fetch(url,{cache:'no-store',signal:ctrl?ctrl.signal:undefined});
   else await fetch(url,{mode:'no-cors',cache:'no-store',signal:ctrl?ctrl.signal:undefined});
   return {...r,ms:Math.round(performance.now()-t0),current:same,best:false};
  }catch{return {...r,ms:-1,current:same,best:false};}
  finally{if(timer)clearTimeout(timer);}
 }));
 const fastest=out.filter(r=>r.ms>=0).sort((a,b)=>a.ms-b.ms)[0];
 if(fastest)fastest.best=true;
 return out;
}
async function runLinkProbe(){
 if(state.linkProbing)return;
 state.linkProbing=true;renderPage();
 const bridge=linkBridge();
 if(!bridge&&isNativeApp()){
  /* 桥没注入但确实在 App 里：走 lovespace:// 协议通道，原生端现场探测
     完用 evaluateJavascript 回调 window.__lovespaceLinkProbe。
     挂 30 秒看门狗，防止原生端万一没接住时按钮永远「检测中」。 */
  clearTimeout(runLinkProbe._guard);
  runLinkProbe._guard=setTimeout(()=>{
   window.__lovespaceLinkProbe=null;
   state.linkProbing=false;renderPage();
   toast('检测超时，请再试一次');
  },30000);
  window.__lovespaceLinkProbe=(data)=>{
   clearTimeout(runLinkProbe._guard);
   window.__lovespaceLinkProbe=null;
   try{
    const routes=(data?.routes||[]).map(r=>({name:r.name,url:r.url,ms:Number(r.ms),current:Boolean(r.current),best:Boolean(r.best)}));
    if(!routes.length)throw new Error('没有取到线路信息');
    state.linkRoutes=routes;
    const alive=routes.filter(r=>r.ms>=0).length;
    toast(alive?`检测完成，${alive}/${routes.length} 条线路可用`:'所有线路都没连上，检查一下网络');
   }catch(e){
    toast(e?.message||'检测失败，请稍后再试');
   }
   state.linkProbing=false;renderPage();
  };
  nativeScheme('link-probe');
  return;
 }
 try{
  let routes;
  if(bridge){
   const res=await bridge.probe();
   routes=(res?.routes||[]).map(r=>({name:r.name,url:r.url,ms:Number(r.ms),current:Boolean(r.current),best:Boolean(r.best)}));
  }else{
   await loadRoutes();
   routes=await probeRoutesInBrowser();
  }
  if(!routes.length)throw new Error('没有取到线路信息');
  state.linkRoutes=routes;
  const alive=routes.filter(r=>r.ms>=0).length;
  toast(alive?`检测完成，${alive}/${routes.length} 条线路可用`:'所有线路都没连上，检查一下网络');
 }catch(e){
  toast(e?.message||'检测失败，请稍后再试');
 }finally{
  state.linkProbing=false;renderPage();
 }
}
async function useLinkRoute(url){
 const bridge=linkBridge();
 if(bridge){
  try{
   await bridge.use({url});
   toast('正在切换到新线路…');
  }catch(e){toast(e?.message||'切换失败');}
  return;
 }
 if(isNativeApp()){
  /* 桥没注入的备用通道：原生端 switchToRoute 接管，整页加载新线路 */
  nativeScheme('link-use?url='+encodeURIComponent(url));
  toast('正在切换到新线路…');
  return;
 }
 toast('切换线路需要在 App 内操作');
}
function settingsPage() {
 const v=state.appVersion||{};
 /* 存储占用以前只存在于「数据管理 → 完整备份与迁移」里面，外面连个数字都没有，
    等于埋了三层还看不见。管理员在设置页就地给一行摘要，点一下进详情。 */
 const st=state.storage;
 const fmtSize=b=>b>=1073741824?(b/1073741824).toFixed(2)+' GB':(b/1048576).toFixed(1)+' MB';
 const isAdmin=!!state.me.user.admin;
 const storageStrip=isAdmin&&st?`<button class="storage-strip" data-nav="backups"><span class="storage-strip-icon">${icon('gear')}</span><span class="storage-strip-body"><strong>已用 ${fmtSize(st.total||0)}</strong><small>可用 ${fmtSize(st.disk_free||0)} · ${st.record_count||0} 条记录 · ${st.media_count||0} 个媒体文件</small></span><span class="storage-strip-more">存储占用与备份 ${icon('arrow')}</span></button>`:'';
 return `${heading('设置','管理空间、账号和数据。')}<div class="settings-grid"><section class="card"><h2>${icon('home')} 空间设置</h2><div class="setting-list"><button data-action="space">空间名称与相恋日期 ${icon('arrow')}</button>${state.me.users.length<2?`<button data-action="invite">邀请另一半 ${icon('arrow')}</button>`:''}<button data-nav="channels">通知渠道与提醒偏好 ${icon('arrow')}</button></div><p class="small-note">名称和日期是两个人共用的；通知渠道只影响你自己收到的提醒。</p></section><section class="card"><h2>${icon('image')} 外观与背景</h2><div class="setting-list"><button data-action="theme-form">主题与外观 ${icon('arrow')}</button><button data-action="home-bg">主页背景 ${icon('arrow')}</button><button data-action="chat-bg">聊天背景 ${icon('arrow')}</button><button data-action="chat-bubble">聊天气泡 ${icon('arrow')}</button></div><p class="small-note">主题色、主页封面、聊天壁纸和气泡皮肤各管一摊，改哪样只动哪样，不用整张表一起提交。夜间模式只记在这台设备上。</p></section><section class="card"><h2>${icon('gear')} 我的账号</h2><div class="setting-list"><button data-action="profile">头像、昵称与密码 ${icon('arrow')}</button><button data-action="logout">退出登录 ${icon('arrow')}</button></div></section><section class="card"><h2>${icon('chat')} 连接</h2><div class="setting-list"><button data-nav="linkcheck">链路检测与线路切换 ${icon('arrow')}</button></div><p class="small-note">平时 App 从哪条线路进来就用哪条，不会自动切换。进页面明显变慢、或某条线路连不上时，可以在这里测一遍响应速度并手动换一条——换过之后，下次打开会直接走新选的这条。</p></section><section class="card"><h2>${icon('download')} 数据管理</h2>${storageStrip}<div class="setting-list"><a href="/api/export" download>导出我有权查看的记录与原文件 ${icon('download')}</a><a href="/api/export/markdown" download>导出 Markdown 知识库（第二大脑） ${icon('download')}</a><a href="/api/export/ics" download>导出日历 .ics（纪念日与计划） ${icon('download')}</a>${state.me.user.admin?`<button data-nav="backups">完整备份与存储占用 ${icon('arrow')}</button>`:''}</div><p class="small-note">第二大脑是纯 Markdown 文件夹，可拖进 Obsidian / Logseq，也可直接给 AI 当长期记忆；只含你自己可见的内容，个人心愿只导出标题。私密日记按账号隔离，完整备份由服务器管理员管理。日历文件导进手机自带日历后，纪念日就能用系统提醒，比站内推送更稳。</p></section><section class="card"><h2>${icon('info')} 关于</h2><div class="setting-list"><div style="display:flex;align-items:center;gap:10px;padding:12px 0"><span class="stat-icon" style="font-size:var(--fs-h1)">💕</span><div><h3 style="margin:0;font-size:var(--fs-body)">恋爱空间</h3><p class="meta" style="margin:2px 0 0">${v.version?((state.apkVersion?'APK v'+state.apkVersion+' · ':'')+'网页 v'+v.version+(state.apkLatest&&state.apkVersion&&newerVer(state.apkLatest,state.apkVersion)?' · <span style="color:var(--danger)">可更新到 v'+state.apkLatest+'</span>':'')):'加载中…'}</p></div></div><button data-action="check-update">检查更新 ${icon('arrow')}</button><button data-action="copy-apk-link">复制 App 下载链接 ${icon('arrow')}</button></div><p class="small-note">网页功能自动更新；原生功能（如后台通知）需下载新版 APK，可在检查更新中获取，也可复制下载链接发给对方在手机浏览器打开。</p></section></div>`;
}
function personalPage() {
 const tab=state.tab||'diary',tabs=[['diary','私密日记'],['draft','草稿箱'],['surprise','定时惊喜'],['trash','回收站']];
 let content='';
 if(tab==='settings')return settingsPage();
 if(tab==='trash')content=`<p class="hint">删除的内容保留三十天，你可以恢复自己的记录。</p>${(state.trash||[]).length?state.trash.map(r=>`<article class="card"><h3>${esc(r.body.title||r.body.content||kindLabel[r.kind])}</h3><p class="meta">${kindLabel[r.kind]} · ${dateLabel(r.deleted)} 删除</p><div class="inline-actions">${button('恢复这份回忆','restore','soft small','clock',`data-id="${r.id}"`)}</div></article>`).join(''):empty('回收站是空的','你的回忆都在好好保存。')}`;
 else content=`<p class="hint">${icon('lock')} ${tab==='surprise'?'到约定的时间，惊喜才会被另一半看见。':'这个角落只有你能看见。草稿主动发布后，才会进入共同空间。'}</p>${recordsOf(tab).length?recordsOf(tab).map(recordCard).join(''):empty(tab==='diary'?'给自己，留一点心里话':tab==='draft'?'还没写完的故事，在这里等你':'提前准备一份温柔的惊喜','慢慢写，不着急。',tab==='draft'?'compose':'new-'+tab,tab==='draft'?'写一份草稿':'开始记录')}`;
 return `${heading('我的小角落','有些心事留给自己，有些惊喜留给未来。',['diary','surprise'].includes(tab)?'new-'+tab:'',tab==='surprise'?'准备惊喜':'写日记')}<div class="tabs">${tabs.map(([id,label])=>`<button data-action="personal-tab" data-id="${id}" class="${tab===id?'active':''}">${label}</button>`).join('')}</div>${content}`;
}
function noticesPage(){const sysNotices=state.notices.filter(n=>n.event!=='chat'),readCount=sysNotices.filter(n=>n.seen).length;return `${heading('小小的提醒','每一份回应，都值得被看见。','read-notices','全部已读','check')}${readCount?`<div class="inline-actions" style="justify-content:flex-end;margin:-8px 0 16px">${button('删除已读提醒（'+readCount+'）','delete-read-notices','small secondary','trash')}</div>`:''}<div class="card">${sysNotices.length?sysNotices.map(n=>`<div class="notice ${n.seen?'':'unread'}"><span class="stat-icon">${icon(n.event==='chat'?'chat':'bell')}</span><div><p>${esc(n.title)}</p><small class="meta">${dateLabel(n.created)}</small></div>${n.record_id?`<button class="link-btn" style="margin-left:auto" data-action="notice-detail" data-id="${n.record_id}">查看 ${icon('arrow')}</button>`:(n.event==='watch'?`<button class="link-btn" style="margin-left:auto" data-action="notice-watch">去看 ${icon('arrow')}</button>`:'')}</div>`).join(''):empty('还没有新的提醒','收到留言、互动和纪念日提醒时，会出现在这里。聊天消息请在私聊中查看。')}</div>`;}
const channelNames={smtp:'邮件',bark:'Bark',serverchan:'Server酱',pushplus:'PushPlus',wecom:'企业微信机器人',webhook:'自定义 Webhook',telegram:'Telegram',dingtalk:'钉钉机器人',feishu:'飞书机器人',ntfy:'ntfy'};
const eventNames={chat:'聊天消息',comment:'点赞与评论',note:'留言',activity:'新动态与互动',anniversary:'纪念日',period:'生理期提醒',wish:'愿望到期',surprise:'惊喜公开',habit:'共同打卡',watch:'一起看',backup:'备份失败',storage:'空间不足',system:'系统消息'};
function channelsPage(){
 const native=isNativeApp(),supported=browserPushSupported();
 const webpushCard=native?'':`<section class="card webpush-card"><div class="section-heading"><h2>${icon('bell')} 浏览器系统通知</h2><span class="status-pill ${state.webpush?.local?'sent':'pending'}">${state.webpush?.local?'本设备已开启':(state.webpush?.devices?`已绑定 ${state.webpush.devices} 台设备`:'尚未开启')}</span></div><p class="meta">网页关闭或切到后台时，也可由系统送达提醒。锁屏通知只显示通用提示，不包含聊天或心愿内容。${/iphone|ipad|ipod/i.test(navigator.userAgent)?' iPhone/iPad 请先将恋爱空间添加到主屏幕，再开启通知。':''}</p>${!supported?'<p class="small-note">当前浏览器不支持网页系统通知，请使用支持通知的浏览器或配置其他通知渠道。</p>':state.webpush?.local?`<div class="inline-actions">${button('发送测试通知','test-webpush','small soft','bell')}${button('关闭本设备通知','disable-webpush','small secondary')}</div>`:button('开启本设备通知','enable-webpush','small primary','bell')}</section>`;
 return `${heading('不错过，每一份在意','让想念与提醒，抵达你喜欢的地方。','new-channel','添加渠道','bell')}${webpushCard}<p class="hint">可同时启用多个渠道，各自设置事件和免打扰时间。外部通知只发送提醒摘要，详情请登录空间查看。测试发送会跳过免打扰。</p><div class="channel-list">${state.channels.length?state.channels.map(c=>`<div class="card"><span class="stat-icon">${icon('bell')}</span><div><h3>${esc(c.name)}</h3><p class="meta">${channelNames[c.kind]} · ${c.quiet_start===c.quiet_end?'全天接收':c.quiet_start+':00–'+c.quiet_end+':00 免打扰'}<br>${c.events.map(x=>eventNames[x]).join('、')}</p></div><div class="inline-actions">${button('测试','test-channel','small soft','',`data-id="${c.id}"`)}${button('移除','delete-channel','small secondary','',`data-id="${c.id}"`)}</div></div>`).join(''):empty('选择你的提醒方式','支持邮件、Bark、Server酱、PushPlus、企业微信、Telegram、钉钉、飞书、ntfy 和 Webhook。','new-channel','添加第一个渠道')}</div><section class="card"><div class="section-heading"><h2>最近发送记录</h2>${button('刷新','refresh','small secondary')}</div>${state.deliveries.length?state.deliveries.map(d=>`<div class="delivery"><div><p>${esc(d.title)} · ${esc(d.name)}</p><small class="meta">${d.error?esc(d.error):d.sent_at?dateLabel(d.sent_at):'等待发送'} · 尝试 ${d.attempts} 次</small></div><span class="status-pill ${d.status}">${({sent:'已发送',pending:'待发送',sending:'发送中',failed:'失败',merged:'已合并',skipped:'已跳过'})[d.status]}</span>${d.status==='failed'?button('重试','retry-delivery','small secondary','',`data-id="${d.id}"`):''}</div>`).join(''):'<p class="meta">配置好渠道后，点击测试即可验证能否收到通知。</p>'}</section>`;
}
function backupsPage(){const s=state.storage||{};const fmt=b=>b>=1073741824?(b/1073741824).toFixed(2)+' GB':(b/1048576).toFixed(1)+' MB';const pct=s.disk_total?Math.round((1-s.disk_free/s.disk_total)*100):0;const kindBars=[['image','照片'],['video','视频'],['audio','语音']].map(([k,l])=>{const v=s.media_by_kind?.[k]||0;const total=s.media_by_kind?Object.values(s.media_by_kind).reduce((a,b)=>a+b,0):0;return `<div class="storage-bar"><span>${l}</span><div class="bar-track"><div class="bar-fill" style="width:${total?Math.round(v/total*100):0}%"></div></div><span class="meta">${fmt(v)}</span></div>`;}).join('');return `${heading('让回忆，有一个安心的家','完整备份、迁移和恢复。','backup','立即备份','download')}<section class="card storage-panel"><div class="section-heading"><h2>${icon('gear')} 存储占用</h2></div><div class="storage-overview"><div class="storage-stat"><strong>${fmt(s.total||0)}</strong><small>已使用</small></div><div class="storage-stat"><strong>${fmt(s.disk_free||0)}</strong><small>可用空间</small></div><div class="storage-stat"><strong>${pct}%</strong><small>磁盘占用率</small></div></div>${kindBars}<div class="storage-meta"><p class="meta">数据库 ${fmt(s.db||0)} · 备份 ${fmt(s.backups||0)} · ${s.record_count||0} 条记录 · ${s.media_count||0} 个媒体文件</p></div></section><p class="hint">每天自动备份，保留最近七份成功备份。完整备份包含双方数据与渠道密钥，仅供服务器管理员妥善保管。恢复操作通过服务器命令进行，并恢复到新的空目录。</p><section class="card">${(state.backups||[]).length?state.backups.map(b=>`<div class="delivery"><div class="backup-name"><p>${esc(b.name)}${b.encrypted?' <span class="status-pill sent">🔒 已加密</span>':''}</p><small class="meta">${dateLabel(b.created)} · ${(b.size/1024/1024).toFixed(2)} MB</small></div><a class="button secondary small" href="/api/backups/${encodeURIComponent(b.name)}" download>${icon('download')} 下载</a></div>`).join(''):empty('备份还未生成','可以现在创建第一份完整备份。')}</section>`;}

/* 图片/视频查看器要占满视口，靠 .viewer 这个显式 class 定样式
   （不用 CSS :has()，旧 WebView 不支持时会把舞台高度算塌） */
function openModal(title,content,{wide=false,sheet=false,cleanup=null}={}) {
 closeModal(); focusReturn=document.activeElement;
 const viewer = wide && /class="lightbox-body"/.test(content);
 /* 片源浏览是沉浸式影院层：只要内容根节点带 ws-cinema，弹窗就自动全屏、深色、
    返回键换成箭头。跟 viewer 一样靠内容自报身份，调用方不用多传一个参数。 */
 const cinema = /class="ws-cinema"/.test(content);
 const closeIco = cinema?icon('back'):icon('close');
 $('#modal-root').innerHTML=`<div class="modal-overlay${sheet?' sheet':''}${cinema?' cinema':''}"><section class="modal ${wide?'wide':''}${sheet?' sheet':''}${viewer?' viewer':''}${cinema?' cinema':''}" role="dialog" aria-modal="true" aria-labelledby="modal-title"><header class="modal-header"><h2 id="modal-title">${esc(title)}</h2><button class="icon-btn" data-action="${cinema?'ws-back':'close-modal'}" aria-label="${cinema?'返回':'关闭'}">${closeIco}</button></header>${content}</section></div>`;
 enhanceNativeControls($('.modal'));
 /* 点遮罩空白处关闭：选片浮层（pick-overlay）一直是这个交互，普通弹窗之前只能点右上角叉。
    影院层（全屏片源浏览）例外——误触一下就丢掉选片进度太坑，必须点返回箭头。
    viewer（看图/看视频）也不做：点画面两侧的黑边容易误关，关它有右上角叉。 */
 const ov=$('.modal-overlay');
 if(ov&&!cinema&&!viewer)ov.addEventListener('click',e=>{if(e.target===ov)closeModal();});
 modalCleanup=cleanup;document.body.style.overflow='hidden';setTimeout(()=>$('.modal input:not([type=checkbox]),.modal textarea,.modal button')?.focus(),50);
}
function closeModal(){
 /* 弹窗里试听的那首歌：弹窗一关就停，别让"关掉界面的声音"继续响（气泡里的播放不受影响） */
 if(songCur&&songCur.kind==='preview'){try{songAudio.pause();}catch{}songReset();}
 if(modalCleanup){modalCleanup();modalCleanup=null;}$('#modal-root').innerHTML='';document.body.style.overflow='';focusReturn?.focus?.();}
/* 全局搜索：在顶栏搜索图标或聊天页放大镜打开，对已加载的记录做标题+正文本地模糊匹配。
   不新拉后端接口——state.records 里已有非聊天记录（含私信）与最近 200 条聊天，够覆盖常见场景。
   scope='chat' 时只搜聊天，供聊天页内搜索用。 */
function openSearchPanel(scope){
 const chatOnly=scope==='chat';
 const overlay=document.createElement('div');
 overlay.className='search-overlay';
 overlay.innerHTML=`<div class="search-panel" role="dialog" aria-modal="true" aria-label="搜索">
  <div class="search-input-row">
   <span style="color:var(--muted)">${icon('search')}</span>
   <input id="search-input" placeholder="${chatOnly?'搜索最近的消息…':'搜索留言、愿望、清单、账本、动态、聊天…'}" autocomplete="off">
   <button class="icon-btn" data-action="close-search" aria-label="关闭搜索">${icon('close')}</button>
  </div>
  <div id="search-results"></div>
 </div>`;
 document.body.appendChild(overlay);
 document.body.style.overflow='hidden';
 focusReturn=document.activeElement;
 const input=$('#search-input',overlay);
 input.focus();
 const results=$('#search-results',overlay);
 const render=()=>{
  const q=input.value.trim().toLowerCase();
  if(!q){results.innerHTML=`<div class="search-empty">${icon('search')} 输入关键词，找找我们的小回忆</div>`;return;}
  const q2=q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  const re=new RegExp(q2,'i');
  const emoji=m=>m||'';
  const group=kind=>{
   const items=state.records.filter(r=>{
    if(r.kind==='album')return false;
    if(chatOnly&&r.kind!=='chat')return false;
    if(r.kind==='chat'&&r.body?.recalled)return false;
    const b=r.body||{};
    return re.test(b.title||'')||re.test(b.content||'')||re.test((b.reply_to||{}).text||'');
   }).map(r=>{
    const b=r.body||{};
    const title=b.title||(r.kind==='chat'?chatTimeLabel(r.created,null)||'聊天消息':'');
    const content=(b.content||'').slice(0,80);
    const srTitle=re.test(title)?title.replace(re,'<mark>$&</mark>'):'';
    const srSub=re.test(content)?content.replace(re,'<mark>$&</mark>'):'';
    return `<button class="search-result-item" data-action="search-jump" data-id="${r.id}">
     <span class="sr-type">${KIND_EMOJI[r.kind]||'📄'}</span>
     <span class="sr-text"><span class="sr-title">${srTitle||esc(title)||'（无标题）'}</span><span class="sr-sub">${srSub||esc(content||'')}</span></span>
    </button>`;
   }).join('');
   return items?`<div class="search-group-heading">${kindLabel[kind]||kind}</div><div class="search-results">${items}</div>`:'';
  };
  const types=chatOnly?['chat']:['chat','post','diary','note','wish','quest','ledger','question','habit','mood','anniversary','music','period','surprise','draft'];
  const html=types.map(group).filter(Boolean).join('')||`<div class="search-empty">没有找到「${esc(q)}」相关的记录</div>`;
  results.innerHTML=html;
 };
 input.addEventListener('input',render);
 input.addEventListener('keydown',e=>{
  if(e.key==='Escape')closeSearchPanel(overlay);
  if(e.key==='Enter'){
   const first=$('#search-results .search-result-item',overlay);
   if(first)jumpToRecord(first.dataset.id,overlay);
  }
 });
 overlay.addEventListener('click',e=>{
  if(e.target===overlay)closeSearchPanel(overlay);
  const item=e.target.closest('[data-action="search-jump"]');
  if(item)jumpToRecord(item.dataset.id,overlay);
  if(e.target.closest('[data-action="close-search"]'))closeSearchPanel(overlay);
 });
 render();
}
function closeSearchPanel(overlay){
 overlay?.remove();
 document.body.style.overflow='';
 focusReturn?.focus?.();
}
function jumpToRecord(id,overlay){
 closeSearchPanel(overlay);
 const r=state.records.find(x=>x.id===id);
 if(!r)return;
 /* 聊天消息跳到聊天页并把那条滚到中间高亮：聊天区不在 tab 体系里，单独处理 */
 if(r.kind==='chat'){
  navigate('messages');
  setTimeout(()=>{
   const node=$('#msg-'+id);
   if(!node)return toast('这条消息在更早的记录里，往上翻翻看');
   node.scrollIntoView({block:'center'});
   node.classList.add('flash');
   setTimeout(()=>node.classList.remove('flash'),1400);
  },120);
  return;
 }
 /* 根据记录类型跳到对应页面 */
 const pageMap={post:'timeline',diary:'personal',note:'together',wish:'together',quest:'together',ledger:'together',question:'together',habit:'together',mood:'together',anniversary:'together',music:'together',period:'together',surprise:'personal',draft:'personal'};
 const tabMap={note:'note',wish:'wish',quest:'quest',ledger:'ledger',question:'question',habit:'habit',mood:'mood',anniversary:'anniversary',music:'music',period:'period'};
 const page=pageMap[r.kind]||'timeline';
 const tab=tabMap[r.kind]||'';
 navigate(page,tab);
 toast('已跳转到记录');
}
function field(label,name,value='',type='text',extra=''){return `<label>${label}<input name="${name}" type="${type}" value="${esc(value)}" ${extra}></label>`;}
function selectField(label,name,options,value){return `<label>${label}<select name="${name}">${options.map(([v,l])=>`<option value="${esc(v)}" ${String(value)===String(v)?'selected':''}>${esc(l)}</option>`).join('')}</select></label>`;}

/* ── 自绘「日期 / 下拉选择」控件 ──
   原生 <input type=date> 和 <select> 在手机上弹出的是系统 UI——绿头白底的日历、
   白底黑字的列表，跟应用的主题完全两个世界。这里换成「只读按钮 + 原地展开的面板」：
   视觉走同一套令牌，点选即收，从头到尾不离开当前弹窗。 */
const WEEK_HEAD=['一','二','三','四','五','六','日'];
function formatDateCn(v){
 if(!v)return '';
 const d=new Date(v+'T00:00:00');if(isNaN(d))return v;
 const wk=['周日','周一','周二','周三','周四','周五','周六'][d.getDay()],[y,m,day]=v.split('-');
 /* 当年的日期不写年份：双列表单里半栏只有 180px 左右，
    「2026年11月4日 · 周三」会被折成两行，把整行撑高、跟右列错位。 */
 if(Number(y)===new Date().getFullYear())return `${Number(m)}月${Number(day)}日 · ${wk}`;
 return `${y}年${Number(m)}月${Number(day)}日`;
}
function miniCalHtml(month,selected){
 const [y,m]=month.split('-').map(Number);
 const lead=(new Date(y,m-1,1).getDay()+6)%7,days=new Date(y,m,0).getDate(),td=today();
 let cells='';for(let i=0;i<lead;i++)cells+='<i class="mc-blank"></i>';
 for(let d=1;d<=days;d++){
  const ds=`${y}-${String(m).padStart(2,'0')}-${String(d).padStart(2,'0')}`;
  cells+=`<button type="button" class="mc-day${ds===selected?' on':''}${ds===td?' ring':''}" data-day="${ds}">${d}</button>`;
 }
 return `<div class="mc-head"><button type="button" class="mc-nav" data-mc-nav="-1" aria-label="上个月">‹</button><b>${y} 年 ${m} 月</b><button type="button" class="mc-nav" data-mc-nav="1" aria-label="下个月">›</button></div><div class="mc-week">${WEEK_HEAD.map(w=>`<i>${w}</i>`).join('')}</div><div class="mc-grid">${cells}</div>`;
}
/* ── 面板互斥与定位 ──
   日期、相册、自绘 select 共用一个状态：同一时刻只允许一个下拉面板展开，
   打开新的之前先收掉旧的。展开前先看一眼剩余空间——表单底部放不下且上方
   够用就改成向上弹，别让面板顶出屏幕。 */
let openPanel=null;
function closeOpenPanel(){
 if(!openPanel)return;
 openPanel.box.hidden=true;openPanel.btn.classList.remove('open');openPanel=null;
}
function togglePanel(btn,box){
 if(openPanel&&openPanel.box===box){closeOpenPanel();return;}
 closeOpenPanel();
 box.classList.remove('up');box.hidden=false;
 const need=box.offsetHeight,r=btn.getBoundingClientRect();
 if(window.innerHeight-r.bottom<need+16&&r.top>need+16)box.classList.add('up');
 btn.classList.add('open');openPanel={btn,box};
}
function wireDatePick(form,btn,input,box){
 if(!btn||!input||!box)return;
 let month=(input.value||today()).slice(0,7);
 const paint=()=>{box.innerHTML=miniCalHtml(month,input.value);};
 btn.textContent=input.value?formatDateCn(input.value):'选个日子';
 btn.onclick=()=>{if(openPanel&&openPanel.box===box){closeOpenPanel();return;}month=(input.value||today()).slice(0,7);paint();togglePanel(btn,box);};
 box.onclick=e=>{
  const nav=e.target.closest('[data-mc-nav]');
  if(nav){let [y,m]=month.split('-').map(Number);m+=Number(nav.dataset.mcNav);if(m<1){m=12;y--;}if(m>12){m=1;y++;}month=`${y}-${String(m).padStart(2,'0')}`;paint();return;}
  const day=e.target.closest('[data-day]');
  if(day){input.value=day.dataset.day;btn.textContent=formatDateCn(input.value);closeOpenPanel();}
 };
}
function wireChipsPick(form,btn,input,box){
 if(!btn||!input||!box)return;
 const sync=()=>{const on=box.querySelector('.chip.on');btn.textContent=on?on.textContent.trim():(box.dataset.placeholder||'请选择');};
 sync();
 btn.onclick=()=>togglePanel(btn,box);
 box.onclick=e=>{const chip=e.target.closest('[data-value]');if(!chip)return;
  box.querySelectorAll('.chip').forEach(c=>c.classList.toggle('on',c===chip));
  input.value=chip.dataset.value;sync();closeOpenPanel();};
}
/* 弹窗里剩余的原生控件统一升级：simpleForm 拼出来的 date / datetime-local / select
   不必逐个改模板，openModal 写入 DOM 后扫一遍，就地换成自绘控件。
   原控件只做视觉隐藏（保留 name、required、既有的 onchange 绑定），面板把值写回它，
   FormData 与提交逻辑零改动。datetime-local 的「时间」暂留原生 time 行——
   分钟级时间用芯片铺不满，原生 time 在行内显示 hh:mm，观感尚可。 */
function enhanceNativeControls(root){
 if(!root)return;
 root.querySelectorAll('input[type=date],input[type=datetime-local],select').forEach(el=>{
  if(el.closest('.pick-field'))return;
  const label=el.closest('label');
  const text=label?((label.childNodes[0]?.textContent)||'').trim():'';
  const wrap=document.createElement('div');wrap.className='pick-field';
  const lab=document.createElement('span');lab.className='pick-label';lab.textContent=text;
  const btn=document.createElement('button');btn.type='button';btn.className='fake-field';
  const panel=document.createElement('div');panel.className='fake-panel';panel.hidden=true;
  if(label){label.innerHTML='';label.appendChild(wrap);}else{el.parentNode.insertBefore(wrap,el);}
  el.classList.add('src-input');
  wrap.append(lab,btn,panel,el);
  if(el.tagName==='SELECT'){
   let html='';
   const chip=o=>`<button type="button" class="chip${o.selected?' on':''}" data-value="${esc(o.value)}">${esc(o.textContent)}</button>`;
   for(const node of el.children){
    if(node.tagName==='OPTGROUP')html+=`<i class="chip-group">${esc(node.label)}</i>`+[...node.children].map(chip).join('');
    else html+=chip(node);
   }
   panel.classList.add('chip-list');panel.innerHTML=html;
   const sync=()=>{const o=el.selectedOptions[0];btn.textContent=o?o.textContent:'请选择';};
   sync();
   btn.onclick=()=>togglePanel(btn,panel);
   panel.onclick=e=>{const c=e.target.closest('[data-value]');if(!c)return;
    panel.querySelectorAll('.chip').forEach(x=>x.classList.toggle('on',x===c));
    el.value=c.dataset.value;el.dispatchEvent(new Event('change',{bubbles:true}));sync();closeOpenPanel();};
  }else{
   const dtLocal=el.type==='datetime-local';
   panel.classList.add('mini-cal');
   let month=(el.value||today()).slice(0,7);
   const timeRow=dtLocal?`<div class="mc-time"><span>时间</span><input type="time" step="300" value="${esc((el.value||'').slice(11,16)||'20:00')}"></div>`:'';
   const paint=()=>{panel.innerHTML=miniCalHtml(month,(el.value||'').slice(0,10))+timeRow;};
   const sync=()=>{const v=el.value;btn.textContent=dtLocal?(v?`${formatDateCn(v.slice(0,10))} ${v.slice(11,16)}`:'选个时间'):(v?formatDateCn(v):'选个日子');};
   paint();sync();
   btn.onclick=()=>{if(openPanel&&openPanel.box===panel){closeOpenPanel();return;}month=(el.value||today()).slice(0,7);paint();togglePanel(btn,panel);};
   panel.onclick=e=>{
    const nav=e.target.closest('[data-mc-nav]');
    if(nav){let [y,m]=month.split('-').map(Number);m+=Number(nav.dataset.mcNav);if(m<1){m=12;y--;}if(m>12){m=1;y++;}month=`${y}-${String(m).padStart(2,'0')}`;paint();return;}
    const day=e.target.closest('[data-day]');
    if(day){
     if(dtLocal){const t=panel.querySelector('.mc-time input')?.value||'20:00';el.value=`${day.dataset.day}T${t}`;}
     else el.value=day.dataset.day;
     el.dispatchEvent(new Event('change',{bubbles:true}));sync();closeOpenPanel();}
   };
   if(dtLocal){const t=panel.querySelector('.mc-time input');if(t)t.onchange=e=>{if(el.value)el.value=`${el.value.slice(0,10)}T${e.target.value||'20:00'}`;};}
  }
 });
}
function simpleForm(title,fields,onSubmit,label='保存') {
 openModal(title,`<form class="modal-form" id="simple-form">${fields}${formError()}${modalActions(label)}</form>`);
 $('#simple-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,b=$('button[type=submit]',form);b.disabled=true;try{await onSubmit(Object.fromEntries(new FormData(form)),form);closeModal();await refresh();toast('已保存这份小美好');}catch(err){$('.form-error',form).textContent=err.message;}finally{b.disabled=false;}};
}
function personalWishForm(){const clientId=uuid();openModal('许下一份个人心愿',`<form class="modal-form" id="personal-wish-form"><label>心愿名称（对方可见）<input name="title" required maxlength="100" placeholder="例如：有一天想和你去看海"></label><label>具体心愿内容（需要密码才能查看）<textarea name="content" required maxlength="20000" placeholder="写下想留给自己的心愿…"></textarea></label><label>这条心愿的独立密码<input name="password" type="password" required minlength="6" maxlength="128" inputmode="numeric" autocomplete="new-password" placeholder="至少 6 位，建议纯数字"></label><p class="small-note">每条心愿都要设置不同密码。写下心愿的你可以直接回看内容；把密码告诉对方后，对方输入一次就能看到，之后不必再输。忘记密码无法找回。</p>${formError()}${modalActions('加密保存')}</form>`);$('#personal-wish-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);submit.disabled=true;try{await post('/personal-wishes',{...Object.fromEntries(new FormData(form)),client_id:clientId});closeModal();await refresh();toast('这份个人心愿已加密保存');}catch(err){$('.form-error',form).textContent=err.message;}finally{submit.disabled=false;}};}
function unlockPersonalWish(rid){const wish=state.records.find(r=>r.id===rid);if(!wish)return;openModal('打开这份个人心愿',`<form class="modal-form" id="unlock-personal-wish-form"><p class="meta">「${esc(wish.body.title)}」的内容已加密，请输入心愿本人交给你的密码。</p><label>心愿密码<input name="password" type="password" required maxlength="128" autocomplete="current-password" placeholder="向心愿本人获取这条心愿的密码"></label>${formError()}${modalActions('解锁心愿')}</form>`);$('#unlock-personal-wish-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,submit=$('button[type=submit]',form);submit.disabled=true;try{await post('/personal-wishes/'+encodeURIComponent(rid)+'/unlock',Object.fromEntries(new FormData(form)));closeModal();await refresh();toast('已解锁，内容现在直接显示在心愿卡片里');}catch(err){$('.form-error',form).textContent=err.message;}finally{submit.disabled=false;}};}
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
 openModal(actualKind==='chat'?'分享一个瞬间':record?'继续写我们的故事':kind==='diary'?'给自己的心里话':kind==='surprise'?'藏一份未来的惊喜':'记录此刻的小美好',`<form id="composer-form" class="modal-form">${actualKind!=='chat'?field('给这份回忆一个小标题（可选）','title',data.title||'','text','maxlength="200"'):''}<label>${actualKind==='diary'?'只有你能看见，放心写吧':'这一刻，想说些什么？'}<textarea name="content" maxlength="20000" placeholder="今天的小事，也值得认真收藏…">${esc(data.content||'')}</textarea></label>${actualKind!=='chat'?`<div class="form-row"><div class="pick-field"><span class="pick-label">事情发生的日期</span><button type="button" class="fake-field" id="date-pick-btn"></button><input type="hidden" name="date" value="${esc(data.date||today())}"><div class="fake-panel mini-cal" id="date-pick-box" hidden></div></div><div class="pick-field"><span class="pick-label">收进相册</span><button type="button" class="fake-field" id="album-pick-btn"></button><input type="hidden" name="album" value="${esc(data.album||state.album||'')}"><div class="fake-panel chip-list" id="album-chips" hidden data-placeholder="暂不分类"><button type="button" class="chip${(data.album||state.album||'')===''?' on':''}" data-value="">暂不分类</button>${recordsOf('album').map(a=>`<button type="button" class="chip${(data.album||state.album||'')===a.id?' on':''}" data-value="${esc(a.id)}">${esc(a.body.title)}</button>`).join('')}</div></div></div>`:''}${kind==='surprise'||actualKind==='surprise'?field('给 TA 看见的时间','publish_at',data.publish_at?localDateTime(data.publish_at):'','datetime-local','required'):''}<div class="upload-zone"><div class="upload-main"><label class="upload-tile"><span class="upload-ico">🖼️</span><b>照片 / 视频</b><small>选图或拍摄</small><input type="file" id="composer-files" accept="image/jpeg,image/png,image/webp,image/gif,image/heic,image/heif,video/mp4,video/quicktime,video/webm" multiple></label><label class="upload-tile"><span class="upload-ico">🎵</span><b>语音</b><small>上传已有音频</small><input type="file" id="composer-audio" accept="audio/*"></label><button type="button" class="upload-tile" data-action="record-audio"><span class="upload-ico">🎙️</span><b>录音</b><small>现场说两句</small></button></div><p class="small-note">原文件会被保留 · 最多三十个附件，可调整顺序，也支持把文件拖进来</p></div><div class="upload-preview" id="upload-preview"></div><div class="progress-slot"><span id="upload-progress" class="progress"></span></div><div class="form-error" role="alert"></div><p class="small-note">编辑内容自动暂存于当前浏览器。点击保存草稿，可同步到服务器。</p><div class="form-actions">${actualKind!=='chat'&&!record?.id?'<button class="button secondary" type="submit" name="mode" value="draft">保存草稿</button>':''}${draftKind?'<button class="button secondary" type="submit" name="mode" value="draft">继续存草稿</button>':''}<button class="button primary" type="submit" name="mode" value="${draftKind?'post':kind}">${actualKind==='chat'?'发送':kind==='diary'?'保存日记':kind==='surprise'?'藏好这份惊喜':record&&!draftKind?'保存修改':'发布到我们的时光'}</button></div></form>`,{cleanup:()=>{persist();closed=true;if(recording&&recording.state!=='inactive')recording.stop();stream?.getTracks().forEach(t=>t.stop());},sheet:actualKind==='post'||actualKind==='diary'||actualKind==='draft'||actualKind==='surprise'||actualKind==='chat'});
 const form=$('#composer-form'),progress=$('#upload-progress');
 /* 日期与相册分类：自绘面板，别再用系统 UI */
 wireDatePick(form,$('#date-pick-btn',form),$('[name=date]',form),$('#date-pick-box',form));
 wireChipsPick(form,$('#album-pick-btn',form),$('[name=album]',form),$('#album-chips',form));
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
 if(kind==='period')return periodForm(record);
 if(kind==='music')return musicForm(record);
 if(['post','diary','draft','surprise','chat'].includes(kind))return composer(kind,record);
 const b=record?.body||{};let fields='';
 if(kind==='mood')fields=selectField('今天的心情','emoji',MOOD_OPTIONS,b.emoji||'☀️')+field('心情日期','date',b.date||today(),'date','required');
 else if(kind!=='note'&&kind!=='ledger')fields+=field(kind==='question'?'想问 TA 的问题':'标题','title',b.title||'','text','required maxlength="200"');
 if(kind==='question')fields+='<label>或挑选一个内置问题<select id="preset-question"><option value="">选择一个问题…</option>'+QUESTION_BANK.map(([g,items])=>`<optgroup label="${esc(g)}">${items.map(q=>`<option>${esc(q)}</option>`).join('')}</optgroup>`).join('')+'</select></label>';
 if(kind==='anniversary')fields+=`<div class="form-row">${field('日期','date',b.date||today(),'date','required')}${field('提前几天提醒','remind_days',b.remind_days??1,'number','min="0" max="365"')}</div><label class="switch-row">重复方式<select name="annual"><option value="true" ${b.annual===true||b.annual===undefined?'selected':''}>每年公历日期</option><option value="lunar" ${b.annual==='lunar'?'selected':''}>每年农历日期</option><option value="false" ${b.annual===false?'selected':''}>只纪念一次</option></select></label>`;
 if(kind==='wish')fields+=`<div class="form-row">${selectField('分类','category',[['日常','日常'],['旅行','旅行'],['美食','美食'],['约会','约会'],['其他','其他']],b.category||'日常')}${field('约定日期（可选）','target',b.target||'','date')}</div>`;
 if(kind==='quest')fields+=`<div class="form-row">${selectField('分类','category',[['日常','日常'],['旅行','旅行'],['美食','美食'],['约会','约会'],['生活','生活'],['其他','其他']],b.category||'日常')}${field('计划日期（可选）','date',b.date||'','date')}</div>`;
 if(kind==='ledger')fields+=`<div class="form-row">${field('金额（元）','amount',b.amount??'','number','required min="0" max="100000000" step="0.01"')}${selectField('分类','category',[['餐饮','餐饮'],['交通','交通'],['旅行','旅行'],['礼物','礼物'],['生活','生活'],['娱乐','娱乐'],['其他','其他']],b.category||'餐饮')}</div>${field('花在哪天','date',b.date||today(),'date','required')}`;
 if(kind!=='album')fields+=`<label>${kind==='mood'?'再说一句今天的心情':kind==='note'?'想对 TA 说的话':kind==='ledger'?'备注（可选）':'补充一些小细节（可选）'}<textarea name="content" maxlength="20000" ${kind==='note'?'required':''}>${esc(b.content||'')}</textarea></label>`;
 simpleForm(record?'编辑'+kindLabel[kind]:'添加'+kindLabel[kind],fields,async(data)=>{data={...b,...data};if(kind==='anniversary'){const annVal=data.annual;data.annual=annVal==='true'?true:annVal==='lunar'?'lunar':false;data.remind_days=Number(data.remind_days);}if(kind==='ledger')data.amount=Number(data.amount);if(record)await put('/records/'+record.id,{kind,body:data});else await post('/records',{kind,body:data,client_id:uuid()});});
 if(kind==='question')$('#preset-question').onchange=e=>{$('#simple-form [name=title]').value=e.target.value;};
}

/* 首页「今天的心情」快捷记录：只有表情 + 一句话，日期固定今天。
   存下去就是一条 kind=mood 记录，和「心情手记」完全同一张表——记完两边立刻都能看到。 */
function quickMoodForm() {
 const fields=selectField('今天的心情','emoji',MOOD_OPTIONS,'☀️')
  +`<label>再说一句今天的心情<textarea name="content" maxlength="2000" placeholder="今天怎么样？一句话就好"></textarea></label>`
  +'<p class="small-note">记完会出现在「心情手记」里；想补标题或换日期，去那里编辑。</p>';
 simpleForm('今天的心情',fields,async data=>{
  await post('/records',{kind:'mood',body:{emoji:data.emoji,date:today(),content:(data.content||'').trim()},client_id:uuid()});
 },'记下今天');
}
/* ── 空间设置拆成四块：改什么就进哪一张表 ──────────────────────────────
   原先名称/日期/主题/封面/壁纸全塞在一张大表里，改个主题要滚半屏，还会把
   不相干的字段一起提交（PUT /api/space 是全量覆盖）。现在每张表只动自己那几个键，
   其余原样带回，谁也不碰谁。聊天气泡单独在 bubblePicker() 里选。 */
function spaceForm() {
 const s=state.me.space;
 simpleForm('空间信息',field('空间名称','name',s.name,'text','required maxlength="60"')+field('从哪一天开始相爱','since',s.since,'date')+'<p class="small-note">名字会出现在首页和分享出去的那张卡片上；日期决定首页「在一起第几天」从哪天算起。</p>',async(data)=>{
  await put('/space',{...s,name:data.name,since:data.since});
 });
}
function themeForm() {
 const s=state.me.space, root=document.documentElement;
 const cur=THEME_IDS.includes(s.theme)?s.theme:(s.theme==='custom'?'custom':'rose');
 const darkPref=localStorage.getItem(DARK_KEY)||'auto', oldDark=darkPref;
 const fontPref=localStorage.getItem(FONT_KEY)||'std';
 let pick=cur;
 const ALL=THEME_IDS.concat(['custom']);
 /* 选色卡先"就地预览"——主题是整站气质，光看一个小方块选不出来。
     取消（关弹窗）时由 cleanup 把 class 与内联变量还原，不会留下半套配色。 */
 const preview=(id)=>{
  ALL.forEach(x=>root.classList.remove('theme-'+x));
  root.classList.add('theme-'+id);
  const color=id==='custom'?($('#theme-color')?.value||s.custom_color||'#9A6B5A'):'';
  applyCustomColor(id,color);
  syncMetaThemeColor();
 };
 const swatches=ALL.map(id=>{
  const t=themeMeta(id,s.custom_color);
  const on=id===cur;
  return `<button type="button" class="theme-swatch${on?' on':''}" data-theme="${id}" aria-pressed="${on}">
   <span class="ts-art" style="--sw-a:${t.swatch[0]};--sw-b:${t.swatch[1]};--sw-c:${t.swatch[2]}"><i></i><em></em><b></b></span>
   <span class="ts-copy"><b>${esc(t.name)}</b><small>${esc(t.desc)}</small></span>
   <span class="ts-tick" aria-hidden="true">${icon('check')}</span>
  </button>`;
 }).join('');
 openModal('主题与外观',`<form class="modal-form" id="theme-form">
  <div class="theme-field"><span class="pick-label">主题配色<span class="tf-note">两个人共用</span></span><div class="theme-grid" id="theme-grid">${swatches}</div></div>
  <label id="theme-color-row" ${pick==='custom'?'':'hidden'}>自定义颜色<input type="color" id="theme-color" name="custom_color" value="${s.custom_color||'#9A6B5A'}"></label>
  <div class="form-row">
   ${selectField('夜间模式','dark',[['auto','跟随系统'],['on','始终开启'],['off','始终关闭']],darkPref)}
   ${selectField('字号','font',[['std','标准'],['large','大一号'],['xl','特大']],fontPref)}
  </div>
  <label class="switch-row">启用轻柔动效<input name="motion" type="checkbox" ${s.motion?'checked':''}></label>
  <p class="small-note">夜间模式与字号只记在这台设备上，只影响你自己看到的界面；主题配色是两个人共用的。选中的配色会立刻套用，取消即还原。</p>
  ${formError()}
  ${modalActions()}
 </form>`,{cleanup:()=>{ALL.forEach(x=>root.classList.remove('theme-'+x));root.classList.add('theme-'+cur);localStorage.setItem(DARK_KEY,oldDark);applyDarkMode();applyCustomColor(cur,s.custom_color||'');syncMetaThemeColor();}});
 const grid=$('#theme-grid');
 grid.onclick=e=>{
  const b=e.target.closest('[data-theme]');if(!b)return;
  pick=b.dataset.theme;
  $$('.theme-swatch',grid).forEach(x=>{const on=x===b;x.classList.toggle('on',on);x.setAttribute('aria-pressed',on);});
  const row=$('#theme-color-row');if(row)row.hidden=pick!=='custom';
  preview(pick);
 };
 /* 夜间模式也做即时预览（含色卡明暗）：不然选完"始终开启"要等到保存才变色，
     还以为没生效。取消时 cleanup 会把 DARK_KEY 恢复原值。 */
 $('#theme-form').addEventListener('change',e=>{
  if(e.target.name!=='dark')return;
  localStorage.setItem(DARK_KEY,e.target.value);
  applyDarkMode();
  ALL.forEach(id=>{const b=$(`[data-theme="${id}"]`,grid);if(!b)return;const t=themeMeta(id,s.custom_color);
   b.querySelector('.ts-art').style.cssText=`--sw-a:${t.swatch[0]};--sw-b:${t.swatch[1]};--sw-c:${t.swatch[2]}`;});
  preview(pick);
 });
 const colorIn=$('#theme-color');
 if(colorIn)colorIn.oninput=()=>{if(pick==='custom')preview('custom');};
 $('#theme-form').onsubmit=async e=>{
  e.preventDefault();
  const form=e.currentTarget,btn=$('button[type=submit]',form);
  btn.disabled=true;
  try{
   const data=Object.fromEntries(new FormData(form));
   localStorage.setItem(DARK_KEY,data.dark);
   localStorage.setItem(FONT_KEY,data.font||'std');
   applyDarkMode();applyFontScale();
   let custom=pick==='custom'?(data.custom_color||s.custom_color||'#9A6B5A'):'';
   await put('/space',{...s,theme:pick,custom_color:custom,motion:$('[name=motion]',form).checked});
   closeModal();await refresh();toast('主题换好了，两个人都看得见');
  }catch(err){$('.form-error',form).textContent=err.message;}
  finally{btn.disabled=false;}
 };
}
function homeBgForm() {
 const s=state.me.space;
 simpleForm('主页背景',`<div class="file-picker"><span class="file-picker-title">首页封面照片</span><label class="upload-tile file-picker-tile"><span class="upload-ico">🖼️</span><b>选择封面照片</b><small id="cover-file-name">${s.cover?'已设置封面，可重新选择':'选择一张照片作为我们的空间封面'}</small><input type="file" id="cover-file" accept="image/jpeg,image/png,image/webp"></label><button type="button" class="button soft" data-action="cover-album">从相册里选一张</button><div class="album-inline" id="cover-album-list" hidden></div><input type="hidden" id="cover-album" value=""><p class="small-note">换好照片保存后会直接弹出构图调整：按住图拖动摆位置、缩放挑画面大小。之后想换，回首页点封面右上角那颗图片按钮也一样。</p></div>`,async()=>{
  let cover=s.cover;
  const file=$('#cover-file').files[0];
  if(file)cover=(await uploadFile(file)).id;
  else if($('#cover-album').value)cover=$('#cover-album').value;
  if(!cover)throw new Error('还没选照片');
  await put('/space',{...s,cover,cover_pos:file?{x:50,y:50,z:1}:(s.cover_pos||{x:50,y:50,z:1})});
  if(file)setTimeout(()=>{if(!$('.modal'))coverCropModal(cover);},450);
 });
 const inp=$('#cover-file');
 if(inp)inp.onchange=e=>{const n=$('#cover-file-name');if(n)n.textContent=e.target.files[0]?.name||'选择一张照片作为我们的空间封面';};
}
/* 聊天页里的「换背景」：只管壁纸三件套，不用进空间设置翻一大张表。
   壁纸是 space 级设置，PUT /api/space 要带全量必填字段（name 等），所以这里摊上现有 space 再覆盖。 */
/* 背景色卡：按目标用户当前那份来画，切「设给谁」时整块重绘 */
function chatBgSwatches(uid){
 const cur=chatBgOf(uid),bg=cur.bg||'',wm=cur.media||'';
 return CHAT_BG_PRESETS.map(([key,label])=>{
  const on=key===bg;
  const art=key==='photo'
   ?(wm?`<span class="chat-wallpaper" aria-hidden="true" style="background-image:url('/media/${esc(wm)}?preview=true')"></span>`:'<span class="pico" aria-hidden="true">📷</span>')
   :(key?`<span class="chat-wallpaper" data-bg="${key}" aria-hidden="true"></span>`:'');
  return `<button type="button" class="wallpaper-swatch${on?' selected':''}${key==='photo'&&!wm?' photo-empty':''}" data-bg="${key}" aria-pressed="${on}">${art}<b>${label}</b></button>`;
 }).join('');
}
function chatBgForm(){
 const s=state.me.space||{},me=state.me.user.id;
 const cur=chatBgOf(me);
 const targetOpts=(state.me.users||[]).map(u=>`<option value="${u.id}" ${u.id===me?'selected':''}>${u.id===me?'我自己':esc(u.name)+'（TA 的手机）'}</option>`).join('');
 simpleForm('聊天背景',`<div class="wallpaper-picker"><label>设给谁<select name="chat_bg_target" id="bg-target">${targetOpts}</select></label><div class="wallpaper-swatches" id="wallpaper-swatches">${chatBgSwatches(me)}</div><label class="wallpaper-dim-row">背景遮罩 <input type="range" name="chat_bg_dim" id="wallpaper-dim" min="0" max="80" step="5" value="${cur.dim??35}"><span id="wallpaper-dim-val">${cur.dim??35}%</span></label><label class="upload-tile file-picker-tile"><span class="upload-ico">🖼️</span><b>用你们的照片</b><small id="wallpaper-file-name">${cur.media?'已设置背景照片，可重新选择':'选一张照片铺满整个聊天背景'}</small><input type="file" id="wallpaper-file" accept="image/jpeg,image/png,image/webp"></label><button type="button" class="button soft" data-action="bg-album">从相册里选一张</button><div class="album-inline" id="bg-album-list" hidden></div><input type="hidden" name="chat_bg" value="${esc(cur.bg||'')}"><input type="hidden" name="chat_bg_media" value="${esc(cur.media||'')}"><p class="small-note">你们各看各的背景，互不打扰；但谁都能替对方换一张——上面选「TA 的手机」就行。</p></div>`,async(data)=>{
  let media=data.chat_bg_media||'';
  const file=$('#wallpaper-file').files[0];
  if(file)media=(await uploadFile(file)).id;
  const key=data.chat_bg||'';
  if(key==='photo'&&!media)throw new Error('请先选择一张照片');
  /* 只改壁纸三项 + 目标用户，其余原样回传：PUT /api/space 的 name 等字段是必填的，
     少了会被判 422，把「换个背景」变成一次莫名其妙的失败。 */
  await put('/space',{...s,chat_bg_target:data.chat_bg_target||me,chat_bg:key,chat_bg_media:key==='photo'?media:'',chat_bg_dim:Math.min(80,Math.max(0,Number(data.chat_bg_dim)||0))});
 });
 /* 切「设给谁」→ 换成那个人当前那套（色卡选中、遮罩、照片提示跟着变） */
 $('#bg-target').onchange=e=>{
  const t=e.target.value,cur=chatBgOf(t),dim=cur.dim??35;
  $('#wallpaper-swatches').innerHTML=chatBgSwatches(t);
  $('#simple-form [name=chat_bg]').value=cur.bg||'';
  $('#simple-form [name=chat_bg_media]').value=cur.media||'';
  $('#wallpaper-dim').value=dim;
  $('#wallpaper-dim-val').textContent=dim+'%';
  $('#wallpaper-file-name').textContent=cur.media?'已设置背景照片，可重新选择':'选一张照片铺满整个聊天背景';
 };
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
/* ── 图片查看器：满屏铺展 + 缩放/拖拽 ─────────────────────────────
   布局：.lightbox-wrap 是唯一舞台（flex:1，深色底），图片 contain 吃满；
   缩放是叠加在 <img> 上的 transform，translate 以舞台中心为原点。
   交互：滚轮 / 双指捏合（以指针为锚点）缩放，放大后拖拽平移到边缘为止，
   双击或连续两次点按在「适应屏幕」与 2.5× 之间切换，
   右下角浮条另有 −/+ 逐步缩放与「适应」复位。 */
const lbZoom = { s: 1, x: 0, y: 0, MIN: 1, MAX: 6 };
const lbPts = new Map();
let lbDrag = null, lbPinch = null, lbTap = { t: 0, x: 0, y: 0 };

function lbStageEl(){ return $('.lightbox-wrap'); }
function lbImgEl(){ return $('.lightbox-image'); }

function lbApply(){
 const img = lbImgEl(); if(!img) return;
 const stage = lbStageEl();
 if(stage){
  // 用 clientWidth/offsetWidth 而不是 getBoundingClientRect：
  // 弹窗有 pop-in 缩放动画，rect 会被祖先 transform 缩放，量出来偏小
  const sw = stage.clientWidth, sh = stage.clientHeight;
  const w = img.offsetWidth, h = img.offsetHeight;
  const maxX = Math.max(0, (w * lbZoom.s - sw) / 2);
  const maxY = Math.max(0, (h * lbZoom.s - sh) / 2);
  lbZoom.x = Math.min(maxX, Math.max(-maxX, lbZoom.x));
  lbZoom.y = Math.min(maxY, Math.max(-maxY, lbZoom.y));
 }
 img.style.transform = `translate3d(${lbZoom.x}px,${lbZoom.y}px,0) scale(${lbZoom.s})`;
 img.classList.toggle('zoomed', lbZoom.s > 1.01);
 const val = $('.lightbox-zoomval');
 if(val) val.textContent = Math.round(lbZoom.s * 100) + '%';
}
function lbReset(){ lbZoom.s = 1; lbZoom.x = 0; lbZoom.y = 0; lbApply(); }
/* 把图缩放到 next 倍，并让 (cx,cy) 这个屏幕点在缩放前后停在原处 */
function lbScaleTo(next, cx, cy){
 const stage = lbStageEl(); if(!stage) return;
 next = Math.min(lbZoom.MAX, Math.max(lbZoom.MIN, next));
 if(Math.abs(next - lbZoom.s) < .002) return;
 const r = stage.getBoundingClientRect();
 const px = (cx == null ? r.left + r.width / 2 : cx) - (r.left + r.width / 2);
 const py = (cy == null ? r.top + r.height / 2 : cy) - (r.top + r.height / 2);
 const k = next / lbZoom.s;
 lbZoom.x = px - (px - lbZoom.x) * k;
 lbZoom.y = py - (py - lbZoom.y) * k;
 lbZoom.s = next;
 lbApply();
}
function lbStep(f){ lbScaleTo(lbZoom.s * f); }
function lbToggle(cx, cy){ if(lbZoom.s > 1.01) lbReset(); else lbScaleTo(2.5, cx, cy); }

document.addEventListener('wheel', e => {
 const stage = lbStageEl();
 if(!stage || !stage.contains(e.target)) return;
 e.preventDefault();
 lbScaleTo(lbZoom.s * (e.deltaY < 0 ? 1.16 : 1 / 1.16), e.clientX, e.clientY);
}, { passive: false });

document.addEventListener('pointerdown', e => {
 const stage = lbStageEl();
 if(!stage || !stage.contains(e.target) || e.target.closest('.photo-arrow,.lb-zoom')) return;
 if(e.pointerType === 'mouse' && e.button !== 0) return;
 lbPts.set(e.pointerId, { x: e.clientX, y: e.clientY });
 try { stage.setPointerCapture(e.pointerId); } catch(_) {}
 if(lbPts.size === 1){
  lbDrag = { x: e.clientX, y: e.clientY, ox: lbZoom.x, oy: lbZoom.y, moved: false, t: Date.now() };
  lbPinch = null;
 } else if(lbPts.size === 2){
  const [a, b] = [...lbPts.values()];
  lbPinch = { d: Math.hypot(a.x - b.x, a.y - b.y), s: lbZoom.s };
  lbDrag = null;
 }
});

document.addEventListener('pointermove', e => {
 if(!lbPts.has(e.pointerId)) return;
 lbPts.set(e.pointerId, { x: e.clientX, y: e.clientY });
 if(lbPinch && lbPts.size >= 2){
  const [a, b] = [...lbPts.values()];
  const d = Math.hypot(a.x - b.x, a.y - b.y);
  if(lbPinch.d > 8) lbScaleTo(lbPinch.s * (d / lbPinch.d), (a.x + b.x) / 2, (a.y + b.y) / 2);
  return;
 }
 if(!lbDrag || lbZoom.s <= 1.01) return;
 const dx = e.clientX - lbDrag.x, dy = e.clientY - lbDrag.y;
 if(!lbDrag.moved && Math.abs(dx) + Math.abs(dy) < 5) return;
 lbDrag.moved = true;
 lbZoom.x = lbDrag.ox + dx;
 lbZoom.y = lbDrag.oy + dy;
 lbApply();
});

function lbPointerEnd(e, allowTap){
 const d = lbDrag;
 if(lbPts.has(e.pointerId)) lbPts.delete(e.pointerId);
 if(lbPts.size < 2) lbPinch = null;
 if(lbPts.size === 0) lbDrag = null;
 if(!allowTap || !d || d.moved || Date.now() - d.t > 320) return;
 const now = Date.now();
 if(now - lbTap.t < 340 && Math.hypot(e.clientX - lbTap.x, e.clientY - lbTap.y) < 44){
  lbTap.t = 0;
  lbToggle(e.clientX, e.clientY);
 } else lbTap = { t: now, x: e.clientX, y: e.clientY };
}
document.addEventListener('pointerup', e => lbPointerEnd(e, true));
document.addEventListener('pointercancel', e => lbPointerEnd(e, false));
/* 换图（src 变更）后回到适应屏幕，避免带着上一张的缩放比；
   同时按这张图的长宽比把外壳宽度收拢，别让竖图两边空着一大片黑 */
document.addEventListener('load', e => {
 const t = e.target;
 if(t && t.classList && t.classList.contains('lightbox-image')){ lbReset(); lbFitFrame(); }
}, true);

function lbFitFrame(pass){
 const modal = document.querySelector('.modal.wide');
 const stage = lbStageEl(), img = lbImgEl();
 if(!modal || !stage || !img || !img.naturalWidth) return;
 if(window.innerWidth <= 640){ modal.style.removeProperty('--lb-w'); return; }
 const sr = { w: stage.clientWidth, h: stage.clientHeight };
 const want = Math.ceil(sr.h * (img.naturalWidth / img.naturalHeight)) + 2;
 const target = Math.max(360, Math.min(want, Math.round(window.innerWidth * .94), 1240));
 modal.style.setProperty('--lb-w', target + 'px');
 // 收窄后底部按钮可能换行、舞台变矮，再纠一次
 if(!pass) requestAnimationFrame(() => lbFitFrame(2));
}
window.addEventListener('resize', () => { if($('.lightbox-body')) lbFitFrame(); });

const lbZoomBar = `<div class="lb-zoom"><button type="button" data-action="lb-out" aria-label="缩小">−</button><span class="lightbox-zoomval">100%</span><button type="button" data-action="lb-in" aria-label="放大">+</button><button type="button" class="lb-fit" data-action="lb-fit">适应</button></div>`;
function photoBodyHtml(){
 const photos = state.photos || [];
 if (!photos.length) return '';
 if (photoIndex < 0) photoIndex = 0;
 if (photoIndex >= photos.length) photoIndex = photos.length - 1;
 const p = photos[photoIndex];
 const arrows = `${photoIndex > 0 ? `<button type="button" class="photo-arrow left" data-action="photo-prev" aria-label="上一张">${icon('back')}</button>` : ''}${photoIndex < photos.length - 1 ? `<button type="button" class="photo-arrow right" data-action="photo-next" aria-label="下一张">${icon('arrow')}</button>` : ''}`;
 const caption = (p.caption || '').trim();
 return `<div class="lightbox-wrap"><img class="lightbox-image" src="/media/${p.id}?preview=true" alt="${esc(p.caption||'我们的照片')}" decoding="async">${arrows}${lbZoomBar}</div>${caption ? `<p class="lightbox-caption">${esc(caption)}</p>` : ''}<div class="lightbox-bar"><span class="lightbox-count">${photoIndex + 1} / ${photos.length}</span><div class="photo-detail-actions"><a class="button secondary small" href="/media/${p.id}?download=true" download>${icon('download')} 下载原文件</a>${button('回到这条时光','notice-detail','small soft','book',`data-id="${p.record_id}"`)}</div></div>`;
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
/* 图片查看器分两条路：
   · state.photos 里的（时光/相册照片）→ 原「收藏的瞬间」，可以翻遍整个相册；
   · 不在相册里的（聊天消息、留言、导入记录里带的图）→ 按**它所属的那条记录**单独看。
   以前只有第一条，聊天里的图在相册里查不到，idx 变 -1 落到第一张，
   于是"点聊天里的照片"会莫名其妙跳到收藏相册的第一张。 */
function photoModal(mid){
 const idx = (state.photos || []).findIndex(p => p.id === mid);
 if(idx >= 0){ photoIndex = idx; renderPhotoModal(); return; }
 recordMediaModal(mid);
}
/* 单条记录内的图片查看器：只在这条消息/这条动态的图之间左右翻，不串到别人的相册 */
const mediaViewer = {ids:[], i:0};
function recordMediaIds(mid){
 const rec=(state.records||[]).find(r=>(r.media||[]).some(m=>m.id===mid));
 const imgs=(rec?.media||[]).filter(m=>!m.mime||m.mime.startsWith('image/'));
 return {ids: imgs.length?imgs.map(m=>m.id):[mid], title: rec?kindLabel[rec.kind]||'我们的记录':'照片'};
}
function mediaViewerHtml(innerOnly=false){
 const {ids,i}=mediaViewer;
 const arrows=`${i>0?`<button type="button" class="photo-arrow left" data-action="mv-prev" aria-label="上一张">${icon('back')}</button>`:''}${i<ids.length-1?`<button type="button" class="photo-arrow right" data-action="mv-next" aria-label="下一张">${icon('arrow')}</button>`:''}`;
 const inner=`<div class="lightbox-wrap"><img class="lightbox-image" src="/media/${ids[i]}?preview=true" alt="聊天图片" decoding="async">${arrows}${lbZoomBar}</div><div class="lightbox-bar">${ids.length>1?`<span class="lightbox-count">${i+1} / ${ids.length}</span>`:'<span></span>'}<div class="photo-detail-actions"><a class="button secondary small" href="/media/${ids[i]}?download=true" download>${icon('download')} 下载原文件</a></div></div>`;
 return innerOnly?inner:`<div class="lightbox-body">${inner}</div>`;
}
function recordMediaModal(mid){
 const {ids,title}=recordMediaIds(mid);
 mediaViewer.ids=ids; mediaViewer.i=Math.max(0,ids.indexOf(mid));
 openModal(title, mediaViewerHtml(), {wide:true});
}
function moveMediaViewer(step){
 const {ids}=mediaViewer;
 if(!ids.length)return;
 mediaViewer.i=Math.min(ids.length-1,Math.max(0,mediaViewer.i+step));
 const body=$('.lightbox-body');
 if(!body)return recordMediaModal(ids[mediaViewer.i]);
 // 原地换内容，别重开弹窗——重开会有一次 collapse→expand 的闪烁
 body.innerHTML=mediaViewerHtml(true);
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
 try {await post('/records',{kind:'chat',body,client_id:clientId});setPending(pendingChats().filter(p=>p.client_id!==clientId));}catch(e){paintChat($('#chat-log'));scrollChat();throw e;}
}

/* 点「一起看」时给对方留一张邀请卡。它只是一条普通 chat 记录，服务端
   create_record() 会自动 db.notice() + nudge_worker()，对方哪怕没开着页面也能
   从 SSE / Web Push / 第三方渠道收到「TA 邀请你一起看视频」。

   防重复有三道闸门，层层兜底：
   ① 内存级 watchInvitePending —— 同一次点击连击、并发重入直接短路；
   ② 前端时间节流 —— 同一作者 60 秒内无论点「一起看」还是点卡片「重新发起」都不再发；
   ③ 服务端幂等 —— 邀请卡用**确定性 client_id**（watch-invite-<作者id>-<当天>），
      同一天内重复提交，后端 create_record() 命中 author+client_id 直接返回已存在记录，
      绝不会堆出第二条。之前每次都生成新 uuid，导致后端幂等形同虚设，这是刷屏根因。 */
const WATCH_INVITE_KEY='love-watch-invite-at';
let watchInvitePending=false;
/* 邀请卡的稳定 client_id：按作者 + 当天去重，跨天自然允许再发一次。 */
function watchInviteClientId(){
 return 'watch-invite-'+state.me.user.id+'-'+today();
}
async function sendWatchInvite(){
 if(watchInvitePending)return false;
 if(!state.me)return false;
 const last=Number(localStorage.getItem(WATCH_INVITE_KEY)||0);
 if(Date.now()-last<60000){
  /* 刚邀请过：不再发，但给个明确反馈，别让用户以为点了没反应 */
  toast('刚刚已经邀请过 TA 啦，点上面的卡片就能进一起看');
  return false;
 }
 watchInvitePending=true;
 try{
  /* 传入确定性 client_id，让后端幂等去重真正生效 */
  await sendChat({content:'邀请你一起看视频',watch_invite:{v:1}},watchInviteClientId());
  localStorage.setItem(WATCH_INVITE_KEY,String(Date.now()));
  try{await refresh(false);}catch{}
  const wl=$('#watch-log');if(wl){paintChat(wl,true);watchScroll();}
  const cl=$('#chat-log');if(cl){paintChat(cl);scrollChat();}
  toast('已邀请 TA 一起看视频');
  return true;
 }catch(e){toast(e.message||'邀请没发出去');return false;}
 finally{watchInvitePending=false;}
}

async function act(action,id,el) {
 const r=state.records.find(x=>x.id===id);
 if(action==='reload')return boot();
 if(action==='load-more-timeline'){await loadTimeline(false);return renderPage();}
 if(action==='week-prev'||action==='week-next'){const next=(state.weekOffset||0)+(action==='week-prev'?-1:1);if(next>0)return;state.weekOffset=next;state.weekly=null;renderPage();await loadSpecial();return renderPage();}
 if(action==='week-copy'){const w=state.weekly;if(!w)return;const text=[`${w.label}的回忆周报（${w.start} 至 ${w.end}）`,w.message,`记录 ${w.total} 条 · 照片 ${w.photos} 张 · 有记录 ${w.days_active} 天`,`喜欢 ${w.likes} 次 · 留言与评论 ${w.comments} 条`].join('\n');try{await navigator.clipboard.writeText(text);toast('周报文字已复制');}catch{toast('复制失败，请手动选择文字');}return;}
 if(action==='toggle-dark'){const pref=localStorage.getItem(DARK_KEY)||'auto';const isDark=document.documentElement.classList.contains('dark');localStorage.setItem(DARK_KEY,isDark?'off':'on');applyDarkMode();const btn=el||$('#dark-toggle');if(btn)btn.innerHTML=icon(document.documentElement.classList.contains('dark')?'sun':'moon');return;}
 if(action==='open-search'){openSearchPanel();return;}
 if(action==='close-modal')return closeModal();
 if(action==='record-audio')return;
 if(action==='compose')return composer();
 if(action==='upload-album')return composer('post',null,{album:state.album||''});
 // 点日历某一天：切到那天去记录（记录项在记录卡里改，日历只负责选日期）
 if(action==='period-day'||action==='period-pick'){
  if(Date.now()-periodSwipeAt<450)return; // 刚划过月，别把松手时补的那次点击当成选了这天
  state.periodDay=el.dataset.day||today();
  renderPage();
  $('.period-log')?.scrollIntoView({block:'center',behavior:'smooth'});
  return;
 }
 // 周条左右翻一周，只挪选中日期
 // 顶部日历按整月翻；选中日期跟着挪到下月同一天（月末自动夹到该月最后一天）
 if(action==='period-month'){
  state.periodDay=shiftMonth(state.periodDay||today(),Number(el.dataset.delta||0));
  return renderPage();
 }
 if(action==='period-log')return periodLogSheet(el.dataset.field||'',el.dataset.day||today());
 if(action==='period-start')return periodStart(el.dataset.day||today());
 if(action==='period-end')return periodEnd(el.dataset.day||today());
 if(action==='period-more')return periodMore(el.dataset.day||today());
 // 分析页是 together 下的一个 tab，返回就是回到生理期页
 if(action==='period-analysis')return navigate('together','period-analysis');
 if(action==='period-back')return navigate('together','period');
 if(action==='period-del-episode'){
  const ids=String(el.dataset.ids||'').split(',').filter(Boolean);
  return confirmAction('删掉这次经期？',`这次经期被拆成了 ${ids.length} 段记录，会一起进回收站，三十天内可以恢复。`,async()=>{for(const one of ids)await del('/records/'+one);await refresh();});
 }
 if(action.startsWith('new-')){const kind=action.slice(4);return kind==='channel'?channelForm():kind==='personal-wish'?personalWishForm():recordForm(kind);}
 if(action==='unlock-personal-wish')return unlockPersonalWish(id);
 if(action.startsWith('tool-'))return navigate('together',action.slice(5));
 // 分析页是从生理期页进去的，顶栏返回就退回生理期，而不是跳回工具宫格
 if(action==='tools-back')return goBack('together',state.tab==='period-analysis'?'period':'');
 if(action==='mood')return recordForm('mood');
 if(action==='mood-quick')return quickMoodForm();
 if(action==='mood-history')return navigate('together','mood');
 if(action==='personal-tab')return id==='settings'?navigate('settings'):navigate('personal',id);
 if(action==='album-filter'){state.album=id;return renderPage();}
 if(action==='album-view'){state.albumView=el.dataset.view==='date'?'date':'album';return renderPage();}
 if(action==='edit-record')return recordForm(r.kind,r);
 if(action==='delete-record')return confirmAction('暂时收起这份回忆？',r.kind==='album'?'只删除相册分类，里面的照片仍会保留在全部照片中。':'记录会进入作者的回收站，三十天内可以恢复。',async()=>{await del('/records/'+id);if(state.album===id)state.album='';});
 if(action==='restore'){await post('/records/'+id+'/restore');await refresh();return toast('回忆已恢复');}
 if(action==='like'){await post('/records/'+id+'/like');return refresh();}
 if(action==='comment')return simpleForm('留一句温柔的回应','<label>你的回复<textarea name="content" required maxlength="5000"></textarea></label>',data=>post('/records/'+id+'/comments',data),'发送回复');
 if(action==='delete-comment')return confirmAction('删除这条回复？','删除后无法恢复。',()=>del('/comments/'+id));
 if(action==='answer'){const old=(r.answers||[]).find(a=>a.author===state.me.user.id);return simpleForm(r.body.title,`<label>我的答案<textarea name="content" required maxlength="5000">${esc(old?.content||'')}</textarea></label>`,data=>post('/records/'+id+'/answer',data));}
 if(action==='check'){await post('/records/'+id+'/check');await refresh();return toast('今天也一起向前了一小步');}
 if(action==='toggle-wish'){await put('/records/'+id,{kind:'wish',body:{...r.body,done:!r.body.done}});return refresh();}
 if(action==='toggle-quest'){await put('/records/'+id,{kind:'quest',body:{...r.body,done:!r.body.done}});return refresh();}
 if(action==='add-quest'){await post('/records',{kind:'quest',body:{title:el.dataset.title,category:el.dataset.cat,done:false},client_id:uuid()});return refresh();}
 /* 整页批量：默认双人可见，但健康数据必须能一键收回 */
 if(action==='love-card')return loveCardImage();
 if(action==='wish-memory')return composer('post',null,{title:'一起实现：'+r.body.title,content:r.body.content||'',completion_post:r.id});
 if(action==='anniversary-memories'){state.filters={date:el.dataset.date};return navigate('timeline');}
 if(action==='photo')return photoModal(id);
 if(action==='video')return videoModal(id);
 if(action==='mv-prev')return moveMediaViewer(-1);
 if(action==='mv-next')return moveMediaViewer(1);
 if(action==='photo-prev'||action==='photo-next'){photoIndex += action==='photo-next' ? 1 : -1; return updatePhotoModal();}
 if(action==='lb-in')return lbStep(1.6);
 if(action==='lb-out')return lbStep(1/1.6);
 if(action==='lb-fit')return lbReset();
 if(action==='space')return spaceForm();
 if(action==='theme-form')return themeForm();
 if(action==='home-bg')return homeBgForm();
 if(action==='chat-bubble')return bubblePicker();
 if(action==='cover-pick')return pickCover();
 if(action==='cover-album')return albumInline($('#cover-album-list'),mid=>{const h=$('#cover-album');if(h)h.value=mid;const n=$('#cover-file-name');if(n)n.textContent='已从相册选好，保存后生效';});
 if(action==='bg-album')return albumInline($('#bg-album-list'),mid=>{
  const f=$('#simple-form');
  const m=f&&f.querySelector('[name=chat_bg_media]');if(m)m.value=mid;
  const k=f&&f.querySelector('[name=chat_bg]');if(k)k.value='photo';
  const n=$('#wallpaper-file-name');if(n)n.textContent='已从相册选好，保存后生效';
 });
 if(action==='cover-crop')return coverCropModal();
 if(action==='profile')return profileForm();
 if(action==='invite')return inviteModal();
 if(action==='copy-invite'){const input=$('#invite-url');input.select();try{await navigator.clipboard.writeText(input.value);toast('邀请链接已复制');}catch{toast('请长按或按 Ctrl+C 复制链接');}return;}
 /* 对方手机还装着旧版、或根本进不来时，直接把安卓包地址发给他最省事 */
 if(action==='copy-apk-link'){let u;try{u=new URL(state.apkMirror||'/apk/download',location.origin).href;}catch{u=state.apkMirror||'';}try{await navigator.clipboard.writeText(u);toast('下载链接已复制，可以直接发给对方');}catch{toast('复制失败，地址是：'+u);}return;}
 if(action==='logout'){const userId=state.me?.user.id;if(browserPushSupported()&&!isNativeApp()){try{await disableBrowserPush({silent:true});}catch{}}if(isNativeApp()){try{const push=nativePushBridge();if(push?.clearTopic)await push.clearTopic();nativePushTopic=null;}catch{}}await post('/logout');state.me=null;await clearPrivateSession(userId);closeModal();return boot();}
 if(action==='read-notices'){await post('/notices/read');return refresh();}
 if(action==='delete-read-notices'){const count=state.notices.filter(n=>n.event!=='chat'&&n.seen).length;if(!count)return toast('没有可删除的已读提醒');return confirmAction('删除已读提醒？',`将删除 ${count} 条已读提醒，不会影响未读提醒、动态或聊天记录。`,async()=>{const result=await api('/notices/read',{method:'DELETE'});toast(`已删除 ${result.deleted||0} 条已读提醒`);});}
 /* 账本往前/往后翻月：往后不允许超过当前月（未来没有账可看） */
 if(action==='ledger-month'){
  const cur=state.ledgerMonth||today().slice(0,7);
  const d=new Date(cur+'-01T00:00:00');
  d.setMonth(d.getMonth()+Number(el.dataset.delta||0));
  const next=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');
  state.ledgerMonth=next>today().slice(0,7)?today().slice(0,7):next;
  return renderPage();
 }
 if(action==='link-probe'){await runLinkProbe();return;}
 if(action==='link-use'){await useLinkRoute(id);return;}
 if(action==='check-update'){try{const s=await api('/status');state.appVersion={version:s.version,build:s.build};renderShell();
  if(isNativeApp()){
   /* App 内只比 App 版本：网页是随服务器一起更新的，与本机判断无关。 */
   let nv=await detectAppVersion();
   state.apkVersion=nv;
   const latest=String(s.apk_version||'').trim();
   const ignored=localStorage.getItem('love_ignore_apk')||'';
   if(!latest)toast('服务器暂未提供 APK 版本信息，请稍后再试');
   else if(nv==='unknown')showUpdateModal(latest,'',s);
   else if(!newerVer(latest,nv))toast('已是最新版本 v'+nv);
   else if(ignored===latest)toast('已是最新（v'+latest+'，你已忽略过此更新）');
   else showUpdateModal(latest,nv,s);
  } else {
   /* 浏览器：页面靠 Service Worker 自动更新，用构建号（sha-日期）判断本页是否最新，
      版本号相同也能发现新构建，不必再靠字母后缀区分。 */
   const latestBuild=String(s.build||''),mine=String(state.localBuild||'');
   if(latestBuild&&mine&&latestBuild!==mine)toast('网页已更新到 v'+s.version+'，刷新页面即可加载新版');
   else toast('已是最新版本 v'+s.version);
  }
 }catch{openModal('检查更新失败','<p class="meta" style="margin:0">网络好像不太顺畅，点下方重试。</p><div class="form-actions" style="margin-top:12px"><button class="button primary" data-action="check-update">重试</button><button class="button soft" data-action="close-modal">取消</button></div>',{cleanup:null});}return;}
 if(action==='notice-detail'){closeModal();const detail=await api('/records/'+id);const unread=state.notices.filter(n=>n.record_id===id&&!n.seen);if(unread.length){try{await post('/notices/read?record_id='+encodeURIComponent(id));await refresh();}catch{}}if(detail.kind==='chat')return navigate('messages');openModal('这一刻的故事',recordCard(detail),{wide:true});return;}
 /* 开播提醒没有 record_id，不能走详情；点一下把这类提醒整体标已读再跳过去 */
 if(action==='notice-watch'){try{await post('/notices/read?event=watch');await refresh();}catch{}return navigate('watch');}
 if(action==='chat-attachment')return composer('chat');
 /* ── 输入栏「更多功能」面板 ───────────────────────────────── */
 if(action==='chat-fn'){const p=$('#chat-fn');if(!p)return;
  const d=$('#sticker-dock');if(d)d.hidden=true;
  if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();
  p.hidden=!p.hidden;
  if(!p.hidden)setTimeout(scrollChat,60);
  return;}
 if(action==='chat-fn-close'){const p=$('#chat-fn');if(p)p.hidden=true;return;}
 if(action==='chat-pick'){const p=$('#chat-fn');if(p)p.hidden=true;return id==='camera'?$('#chat-shot')?.click():chatAlbumPick();}
 if(action==='chat-voice'){const p=$('#chat-fn');if(p)p.hidden=true;return chatVoiceToggle();}
 if(action==='chat-locate')return chatLocate();
 if(action==='chat-open-map'){
  const lat=parseFloat(el.dataset.lat||''),lng=parseFloat(el.dataset.lng||'');
  if(!isFinite(lat)||!isFinite(lng))return toast('这条位置信息不完整');
  return openMap(lat,lng,'我们的位置');
 }
 if(action==='chat-watch'){const p=$('#chat-fn');if(p)p.hidden=true;sendWatchInvite();return navigate('watch');}
 /* 邀请卡：自己那侧是「重新发起」，对方那侧点一下直接进放映室。
    点自己的卡也用普通节流（不再 force 破例）——60 秒内重复点只导航不再发；
    即使真过了 60 秒再点，确定性 client_id 也在后端兜底，一天只留一条。 */
 if(action==='chat-watch-invite'){const p=$('#chat-fn');if(p)p.hidden=true;if(el&&el.dataset.mine==='1')sendWatchInvite();return navigate('watch');}
 if(action==='chat-song'){const p=$('#chat-fn');if(p)p.hidden=true;return songPicker();}
 if(action==='song-tab'){state.songTab=id;$$('.ss-tab').forEach(b=>b.classList.toggle('active',b.dataset.id===id));return renderSongPane();}
 if(action==='song-toggle')return songToggle(el);
 if(action==='song-try')return songTry(el);
 if(action==='chat-song-online')return sendOnlineSong(Number(el.dataset.idx||0));
 if(action==='chat-song-send')return sendSong(id);
 if(action==='chat-song-golist'){closeModal();return navigate('together','music');}
 /* 实时通话需要 WebRTC + 信令，属于独立一轮的量，这里明说而不是假装点了没反应 */
 if(action==='chat-call')return toast('实时通话还没接（要 WebRTC + 信令服务），先用语音说两句');
 if(action==='watch-back')return goBack('messages');
 if(action==='watch-pick')return watchPick();
 if(action==='watch-pick-local')return watchPickLocal();
 if(action==='watch-join')return watchJoin();
 /* 手动对齐：拉一次服务端状态并硬对齐（无视 updated 判断）。
    取消了实时进度校正后，长时间播放两边会漂移，靠这个按钮一键拉齐。 */
 if(action==='watch-align')return watchPull(true);
 if(action==='ws-back')return wsBack();
 if(action==='watch-tab'){
  WATCH_PICK.tab=id||'album';
  WATCH_PICK.detail=null;
  if(id==='drama'){
   WATCH_PICK.view='sources';
   watchPickOpen();
   /* 第一次进来可能还没探测完，先画骨架再补数据；主人若已翻页就别盖回去 */
   if(!WATCH_PICK.catalog){WATCH_PICK.catalog=await watchCatalog();wsSafeOpen();}
   return;
  }
  return watchPickOpen();
 }
 /* 组件卡主体：点进去看这个片源的分类分区首页 */
 if(action==='watch-src-open'||action==='watch-src')return watchOpenSource(id,el.dataset.prov||'');
 if(action==='watch-sources'||action==='watch-svc-open'||action==='watch-src-back')return watchSources();
 if(action==='watch-src-toggle')return watchToggleSource(id,el.dataset.prov||'');
 if(action==='watch-src-add')return watchAddSourceForm();
 if(action==='watch-src-del')return watchDropSource(id);
 if(action==='watch-src-done')return closeModal();
 if(action==='watch-home-more'||action==='watch-home-all'){
  const cs=(watchProvider()||{}).categories||[];
  WATCH_PICK.view='list';WATCH_PICK.cat=id||(cs[0]||{}).id||'';
  WATCH_PICK.q='';WATCH_PICK.page=1;WATCH_PICK.detail=null;
  return watchLoadDramas();
 }
 if(action==='watch-recent-play'){
  const row=watchRecentLoad().find(x=>x.id===id)||{};
  /* 直接续播没有详情对象，先补个瘦的，免得片名串成上一部剧 */
  WATCH_PICK.detail={id,title:row.title||'一段视频',poster:row.poster||'',episodes:[]};
  return watchChooseDrama(id,Number(el.dataset.ep||1),
   {svc:WATCH_PICK.svc,prov:WATCH_PICK.prov});
 }
 if(action==='watch-cat'){
  WATCH_PICK.view='list';WATCH_PICK.cat=id||'';WATCH_PICK.page=1;
  WATCH_PICK.q='';WATCH_PICK.detail=null;return watchLoadDramas();
 }
 if(action==='watch-more'){WATCH_PICK.view='list';WATCH_PICK.page=(WATCH_PICK.page||1)+1;return watchLoadDramas();}
 if(action==='watch-search')return watchSearchForm();
 if(action==='watch-drama')return watchDramaDetail(id);
 if(action==='watch-drama-back'){WATCH_PICK.detail=null;WATCH_PICK.view='list';return watchPickOpen();}
 if(action==='watch-drama-ep')return watchChooseDrama(id,Number(el.dataset.ep||1));
 if(action==='chat-bg')return chatBgForm();
 if(action==='chat-to-draft')return composer('post',null,{...r.body,mediaObjects:r.media});
 if(action==='retry-chat'){const p=pendingChats().find(p=>p.client_id===id);if(p){await sendChat(p.body,p.client_id);await refresh();}return;}
 if(action==='recall-chat')return confirmAction('撤回这条悄悄话？','撤回后双方都不会再看到这条消息。',async()=>{await post('/records/'+id+'/recall');await refresh();return toast('已撤回');});
 /* 引用：只记 id + 摘要，落在 body.reply_to 里；取消或发送后清空 */
 if(action==='chat-reply'){const rec=recordsOf('chat').find(x=>x.id===id);if(!rec)return;
  /* 纯附件/表情包的消息 content 是空的，摘要要自己编一句，否则引用条上只有一个 ✕ */
  const quote=((rec.body.content||'').trim()||(rec.body.sticker?'[表情包]':((rec.body.media||[]).length?'[图片或附件]':'一条消息')));
  state.chatReply={id:rec.id,text:quote.slice(0,60)};renderPage();setTimeout(()=>{$('#chat-text')?.focus();scrollChat();},30);return;}
 if(action==='chat-reply-cancel'){state.chatReply=null;return renderPage();}
 /* 置顶走独立端点：整体 PUT 会经过 clean_body 白名单，把 recalled 这类字段洗掉（等于偷偷取消撤回） */
 if(action==='chat-pin'){try{const r=await post('/records/'+id+'/pin');await refresh();toast(r.pinned?'已置顶这条消息':'已取消置顶');}catch(err){toast(err.message);}return;}
 if(action==='chat-jump'){const node=$('#msg-'+id);if(!node)return toast('这条消息不在最近加载的范围里');node.scrollIntoView({block:'center'});node.classList.add('flash');setTimeout(()=>node.classList.remove('flash'),1400);return;}
 if(action==='chat-search')return openSearchPanel('chat');
 if(action==='chat-search-clear'){state.chatSearch='';renderPage();setTimeout(scrollChat,20);return;}
 if(action==='sticker-panel')return stickerPanel();
 if(action==='sticker-tab'){state.stickerTab=id;return renderStickerTabs();}
 if(action==='sticker-emoji')return insertStickerText(id);
 if(action==='sticker-del'){setStickers(myStickers().filter(s=>s.mid!==id));return renderStickerTabs();}
 if(action==='sticker-send'){const dock=$('#sticker-dock');if(dock)dock.hidden=true;await sendChat({content:'',media:[id]});await refresh();scrollChat();return;}
 if(action==='sticker-pack-send'){const dock=$('#sticker-dock');if(dock)dock.hidden=true;await sendChat({content:'',sticker:id});await refresh();scrollChat();return;}
 if(action==='chat-back'){const ret=state.chatReturn||{page:'home',tab:''};return goBack(ret.page,ret.tab||'');}
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
 if(action==='cal-today'){state.calMonth=today().slice(0,7);state.calSelected='';return loadCalendar(true);}
 if(action==='cal-prev'||action==='cal-next'){if(!state.calMonth){const d=new Date();state.calMonth=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');}const [y,m]=state.calMonth.split('-').map(Number);const d=new Date(y,m-1+(action==='cal-next'?1:-1),1);state.calMonth=d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0');state.calSelected='';return loadCalendar(true);}
 if(action==='import-to-draft')return composer('post',null,{content:el.dataset.content,date:el.dataset.day||today()});
 if(action==='import-chat')return importChatModal();
 if(action==='open-import'){state.importId=id;return navigate('importdetail');}
 if(action==='imports-back')return navigate('imports');
 if(action==='delete-import')return confirmAction('删除这份聊天记录？','这是我们两人共用的记录，删除后双方都看不到，无法恢复。',async()=>{await del('/imports/'+id);state.importId='';navigate('imports');return toast('已删除这份聊天记录');});
}

/* 生理期月历左右滑动换月。「共同年历」用的是同一个 .calendar-grid，所以只认 .period-cal；
   滑动结束后浏览器还会补一次 click，用 periodSwipeAt 把那次「顺手选中某天」压掉。 */
const periodSwipe={on:false,x:0,y:0};
let periodSwipeAt=0;
document.addEventListener('touchstart',e=>{
 const g=e.target.closest&&e.target.closest('.period-cal');if(!g)return;
 const t=e.touches[0];periodSwipe.on=true;periodSwipe.x=t.clientX;periodSwipe.y=t.clientY;
},{passive:true});
document.addEventListener('touchend',e=>{
 if(!periodSwipe.on)return;
 periodSwipe.on=false;
 const t=e.changedTouches&&e.changedTouches[0];if(!t)return;
 const dx=t.clientX-periodSwipe.x,dy=t.clientY-periodSwipe.y;
 // 横向位移够大、且明显比纵向大，才算翻月；否则是页面上下滚动
 if(Math.abs(dx)<44||Math.abs(dx)<Math.abs(dy)*1.5)return;
 periodSwipeAt=Date.now();
 state.periodDay=shiftMonth(state.periodDay||today(),dx<0?1:-1);
 renderPage();
},{passive:true});
document.addEventListener('click',async e=>{$$('.more-menu[open]').forEach(d=>{if(!d.contains(e.target))d.removeAttribute('open');});const nav=e.target.closest('[data-nav]'),el=e.target.closest('[data-action]');try{if(nav||el)e.target.closest('.account-menu')?.removeAttribute('open');if(nav)return await navigate(nav.dataset.nav);if(el)await act(el.dataset.action,el.dataset.id||'',el);}catch(err){toast(err.message);}});
document.addEventListener('submit',async e=>{const isWatch=e.target.id==='watch-form';if(e.target.id!=='chat-form'&&!isWatch)return;e.preventDefault();const input=$(isWatch?'#watch-text':'#chat-text'),content=input.value.trim();if(!content)return;const btn=$('button[type=submit]',e.target);btn.disabled=true;try{const body={content,date:today(),media:[]};if(!isWatch&&state.chatReply)body.reply_to=state.chatReply;await sendChat(body);if(!isWatch)state.chatReply=null;input.value='';localStorage.removeItem('chat-text:'+state.me.user.id);
 /* 一起看页不能整页重渲染：视频是本机 objectURL，重渲染就把放映区清空了 */
 if(isWatch){await refresh(false);const log=$('#watch-log');if(log)paintChat(log,true);syncCompose();watchScroll();}
 else{await refresh();syncCompose();}
 }catch(err){toast(err.message);}finally{btn.disabled=false;}});
document.addEventListener('input',e=>{if(e.target.id==='chat-text'){localStorage.setItem('chat-text:'+state.me.user.id,e.target.value);syncCompose();}if(e.target.id==='watch-text'){syncCompose();}if(e.target.id==='filter-q'){state.filters={...(state.filters||{}),q:e.target.value};clearTimeout(state.filterTimer);state.filterTimer=setTimeout(async()=>{const pos=$('#filter-q')?.selectionStart;try{await loadTimeline(true);renderPage();$('#filter-q')?.focus();$('#filter-q')?.setSelectionRange(pos,pos);}catch(err){toast(err.message);}},250);}});
document.addEventListener('change',e=>{const map={'filter-author':'author','filter-date':'date','filter-media':'media'};if(map[e.target.id]){state.filters={...(state.filters||{}),[map[e.target.id]]:e.target.value};state.timelineCursor=null;loadTimeline(true).then(renderPage).catch(err=>toast(err.message));}});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){const menu=$('.more-menu[open]');if(menu){menu.removeAttribute('open');$('summary',menu)?.focus();}}if(e.key==='Escape'&&$('.modal'))closeModal();if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing&&(e.target?.id==='chat-text'||e.target?.id==='watch-text')){e.preventDefault();const form=e.target.form||$('#chat-form'),btn=form&&$('button[type=submit]',form);if(form&&btn&&!btn.disabled)form.requestSubmit();}if(e.key==='Tab'&&$('.modal')){const els=$$('button,input,textarea,select,a[href]',$('.modal')).filter(el=>!el.disabled),first=els[0],last=els.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last.focus();}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first.focus();}}});
// —— Android APK 系统通知桥（浏览器/PWA 无 Capacitor 时自动跳过，零影响）——
/* 原生环境识别不能只赌 window.Capacitor：APK 是「远程加载模式」（server.url 指向线上站），
   Capacitor 的桥接脚本只注入由它本地服务器提供的页面，远程页面里 window.Capacitor 常常是空的，
   于是以前「检查更新」永远走浏览器分支、拿网页版本去比，装 1.2.9 却说已是最新 1.2.7。
   现在 APK 在 capacitor.config.json 里配了 appendUserAgent，UA 里带 LoveSpaceApp/<版本>，
   这条信息不依赖任何注入，任何页面、任何请求都在，既当原生标记又当版本号来源。 */
const NATIVE_UA=/LoveSpaceApp\/([0-9][0-9.]*)/i;
function nativeUaVersion(){const m=NATIVE_UA.exec(navigator.userAgent||'');return m?m[1].replace(/\.+$/,''):'';}
function isNativeApp(){return Boolean(window.Capacitor&&Capacitor.isNativePlatform&&Capacitor.isNativePlatform())||Boolean(nativeUaVersion())||Boolean(window.LoveNative);}
/* 原生 App 里网页会铺到状态栏下面（Android 15 起强制 edge-to-edge），
   这里给 <html> 打标记，让 CSS 用 --safe-top 给顶栏让出状态栏高度。
   浏览器不加这个类，排版完全不变。脚本是 defer 的，此时 <html> 已存在，
   首屏绘制前就生效，不会出现「先顶上去再跳下来」的闪动。 */
if(isNativeApp())document.documentElement.classList.add('is-native-app');
/* 本机 App 版本：原生桥 > UA 标记，都拿不到才认输（返回 unknown）。 */
async function detectAppVersion(){
 let nv='unknown';
 try{const version=await nativePushBridge()?.version?.();const raw=typeof version?.version==='string'?version.version.trim():'';const m=raw.match(/\d+(?:\.\d+){1,2}/);if(m)nv=m[0];}catch{}
 if(nv==='unknown'&&nativeUaVersion())nv=nativeUaVersion();
 return nv;
}
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
function requestFirstLaunchPermissions(){if(!window.Capacitor||!window.Capacitor.Plugins)return;const done=localStorage.getItem('perm_guide_done');if(done)return;openModal('开启通知提醒',`<div style="text-align:center;padding:10px 0"><div style="font-size:calc(48px * var(--fs-scale));margin-bottom:12px">🔔</div><p>为了不错过对方的消息，请允许以下权限：</p><div class="setting-list" style="text-align:left;margin:16px 0"><button data-action="perm-notify">${icon('bell')} 通知权限<span class="meta">接收消息提醒</span></button><button data-action="perm-battery">${icon('gear')} 后台运行权限<span class="meta">允许 App 在后台保持提醒</span></button></div><div class="form-actions">${button('稍后再说','close-modal')}<button class="button primary" id="perm-done">我知道了</button></div></div>`);
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
/* 更新弹窗：下载（同源 /apk/download → 服务端 302 到站内 static 副本）、复制地址、忽略此版本、更新说明。 */
function showUpdateModal(latest,cur,s){
 const notes=String(s&&s.apk_notes||'').trim();
 const installed=cur?`当前已装 v${cur}`:'当前版本未知';
 const body=`<div style="text-align:center;padding:6px 0 2px"><div style="font-size:calc(44px * var(--fs-scale));margin-bottom:8px">⬇️</div><p style="margin:0 0 4px">发现新版本 <strong>v${latest}</strong></p><p class="meta" style="margin:0">${installed}</p></div>`+(notes?`<details style="margin:10px 0"><summary style="cursor:pointer">更新说明</summary><pre style="white-space:pre-wrap;font-family:inherit;font-size:var(--fs-sm);margin:8px 0 0">${esc(notes)}</pre></details>`:'')+`<div class="form-actions" style="flex-direction:column;gap:8px;margin-top:12px"><button class="button primary" id="apk-dl">下载新版本 v${latest}</button><button class="button secondary" id="apk-copy">复制下载地址</button><div style="display:flex;gap:8px"><button class="button soft" data-action="close-modal" style="flex:1">稍后</button><button class="button soft" id="apk-ignore" style="flex:1">忽略此版本</button></div></div>`;
 openModal('发现新版本',body,{cleanup:null});
 setTimeout(()=>{
  const dl=$('#apk-dl');if(dl)dl.onclick=()=>{closeModal();toast('正在唤起下载…');try{location.href=new URL((s&&s.apk_url)||'/apk/download',location.origin).href;}catch{location.href=s&&s.apk_url;}};
  /* 复制的是站内副本直链（apk_mirror）：仓库私有，GitHub 直连要登录才能下，不如给同源地址 */
  const cp=$('#apk-copy');if(cp)cp.onclick=async()=>{const u=(s&&s.apk_mirror)?new URL(s.apk_mirror,location.origin).href:new URL('/apk/download',location.origin).href;try{await navigator.clipboard.writeText(u);toast('已复制下载地址，可粘贴到手机浏览器');}catch{toast('复制失败，请直接点「下载新版本」');}};
  const ig=$('#apk-ignore');if(ig)ig.onclick=()=>{localStorage.setItem('love_ignore_apk',latest);closeModal();toast('已忽略 v'+latest+'；有新版本再提醒');};
 },50);
}
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
let lastRev=null,eventTimer=null,pendingRev='',pendingFlags={refresh:false,watch:false,chat:false,other:false};
/* flags.refresh —— 整站数据变了，要重拉记录/聊天/照片；
   flags.watch —— 一起看状态变了，只需要拉一次 /api/watch；
   flags.chat / flags.other —— 变化落在哪一类，决定要不要走"只重拉聊天"的快速路径。
   没有 revision 信息的通道（ntfy）不传 flags，按"强制整站刷新"处理。 */
function scheduleServerEvent(rev,flags){
 pendingRev=(typeof rev==='string')?rev:'';  // ntfy 那条通道不带 revision，留空即强制刷新
 if(flags){/* 逐项或：短窗口里排队的多条事件合并成一条。
              other 用或方向是对的——只要有一条说"别的也变了"，就必须整站刷新，
              宁可多拉一次也不能漏掉纪念日/相册的改动。 */
           pendingFlags.refresh=pendingFlags.refresh||!!flags.refresh;
           pendingFlags.watch=pendingFlags.watch||!!flags.watch;
           pendingFlags.chat=pendingFlags.chat||!!flags.chat;
           pendingFlags.other=pendingFlags.other||!!flags.other;}
 else pendingFlags.refresh=pendingFlags.chat=pendingFlags.other=true;
 clearTimeout(eventTimer);
 eventTimer=setTimeout(async()=>{
  const rev=pendingRev;pendingRev='';
  const flags=pendingFlags;pendingFlags={refresh:false,watch:false,chat:false,other:false};
  if(rev&&rev===lastRev&&!flags.watch)return;  // 数据没变，这一轮可以直接跳过
  // 无论 handleServerEvent 成功与否都要记下 rev：以前写在 try 里，一旦 refreshData 抛错
  // lastRev 就永远停在旧值，于是每次心跳都被当成"数据变了"，整页 5 秒重绘一次。
  try{await handleServerEvent(flags);}catch{}finally{if(rev)lastRev=rev;}
 },500);
}
/* 只有聊天变了时的快速刷新：只拉聊天窗口 + 通知。
   对方每发一条消息都会触发一轮刷新，而聊天占全部记录的 88%。走整站刷新的话，
   每句话都要搬 1000 条非聊天记录 + 整本相册 + /me；这里压成两个小请求。
   其它类型（纪念日、账本、相册、空间设置）一个字节都不用重拉。 */
async function refreshChatOnly(){
 const [chats,notices]=await Promise.all([api('/records?kind=chat&limit=200'),api('/notices')]);
 state.records=[...state.records.filter(r=>r.kind!=='chat'),...chats];
 state.notices=notices;
 syncNativePush();
}
async function handleServerEvent(flags){
 if(!state.me)return;
 if(refreshing){state.pendingRefresh=true;return;}
 flags=flags||{refresh:true,watch:true,chat:true,other:true};
 try{
  /* 一起看状态变了：只拉一次 /api/watch。对方拖了进度条、切了片，我这边立刻跟上，
     但记录、聊天、照片一个都不用重拉 —— 这是"事件触发式同步"省下来的大头。 */
  if(flags.watch&&state.page==='watch')await watchPull();
  if(!flags.refresh)return;   // 只有一起看变了：整站数据没动，不必重拉也不必重绘
  const oldNotice=state.notices[0]?.id||null;
  const focused=document.activeElement,canRender=!$('.modal')&&!$('.more-menu[open]')&&!['INPUT','TEXTAREA','SELECT'].includes(focused?.tagName);
  /* 变化只落在聊天上才走快速路径；只要"其它"也变了（哪怕同时还有聊天），
     一律退回整站刷新——宁可多拉一次，也不能漏掉纪念日/相册的改动。 */
  const chatOnly=flags.chat&&flags.other===false;
  if(chatOnly)await refreshChatOnly();else await refresh(false);
  if(state.page==='messages'&&$('#chat-log')){const log=$('#chat-log'),atBottom=log.scrollHeight-log.scrollTop-log.clientHeight<100;paintChat(log);if(atBottom)scrollChat();state.me.chat_unread=0;post('/notices/read?event=chat').catch(()=>{});}
  else if(state.page==='watch'&&$('#watch-log')){const log=$('#watch-log'),atBottom=log.scrollHeight-log.scrollTop-log.clientHeight<80;paintChat(log,true);if(atBottom)watchScroll();state.me.chat_unread=0;post('/notices/read?event=chat').catch(()=>{});}
  else if(canRender)renderShell();
  /* 系统弹窗/锁屏通知已停用：手机端通知改由第三方渠道（企业微信等）+ 浏览器 Web Push 送达；在聊天页停留时消息即时标记已读，后端不再推送 */
 }catch{}
}
let sseRetry=0;
function connectEvents(){clearTimeout(state.sseTimer);state.stream?.close();const es=new EventSource('/api/events');state.stream=es;es.onopen=()=>{sseRetry=0;};es.onmessage=e=>{let rev='',flags={refresh:true,watch:false,chat:true,other:true};try{const d=JSON.parse(e.data||'{}');rev=d.rev||'';/* 老服务端没有这些字段，等于"整站都变了"，按兼容处理 */flags={refresh:d.refresh===undefined?true:!!d.refresh,watch:!!d.watch,chat:d.chat===undefined?true:!!d.chat,other:d.other===undefined?true:!!d.other};}catch{}scheduleServerEvent(rev,flags);};/* 断线兜底：浏览器只自动重连“可恢复”断线（readyState=CONNECTING）；致命断流（401/代理掐断）进 CLOSED 后永不自愈 → 指数退避手动重建，1s 起步、30s 封顶，连上即清零 */
es.onerror=()=>{if(es.readyState!==EventSource.CLOSED)return;state.stream=null;clearTimeout(state.sseTimer);sseRetry=sseRetry?Math.min(sseRetry*2,30):1;state.sseTimer=setTimeout(()=>{if(state.me)connectEvents();},sseRetry*1000);};}
/* 回前台：SSE 可能已被系统挂死（尤其安卓 WebView 后台冻结）→ 死流重建 + 立即补刷一轮，兜住后台错过的消息 */
document.addEventListener('visibilitychange',()=>{if(document.hidden||!state.me)return;syncNativePush();if(!state.stream||state.stream.readyState===EventSource.CLOSED)connectEvents();if(!ntfyWs||ntfyWs.readyState!==WebSocket.OPEN)connectNtfy();handleServerEvent();});
window.addEventListener('focus',()=>{if(document.hidden||!state.me)return;if(!state.stream||state.stream.readyState===EventSource.CLOSED){connectEvents();handleServerEvent();}});
window.addEventListener('online',async()=>{state.online=true;try{await refresh();connectEvents();syncNativePush();}catch{}});
window.addEventListener('offline',()=>{state.online=false;toast('网络断开，未发送内容会保留');});
window.addEventListener('hashchange',()=>{
 const page=location.hash.slice(1);
 if(page){if(page!==state.page)navigate(page);return;}
 /* 退回到"入栈时那条没有 hash 的初始记录"：它其实就是首页。
    以前这里 page 为空直接跳过，表现为"按了返回，地址栏变了、界面一动不动"。
    也不能调 navigate('home')——那会再压一条 #home，返回键又开始走回头路。
    就地把它替换成 #home，再正常渲染。 */
 if(state.page!=='home'){history.replaceState(null,'',location.pathname+'#home');navigate('home');}
});
boot();

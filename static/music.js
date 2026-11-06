'use strict';

/* ── 共同歌单 / 歌曲分享（自 app.js 拆出）────────────────────────────────
   两条线：
   · 聊天里分享歌（songCardMarkup / songPicker / sendSong / sendOnlineSong）——
     气泡里只存摘要（歌名/歌手/媒体 id 或在线试听地址），不复制音频文件；
   · 「共同歌单」页（musicPage / musicCard / musicForm）——每首歌就是一个原生
     <audio>，能拖进度能暂停，手机上也不会被浏览器拦自动播放。

   播放器是手画的，没用原生 <audio controls>：原生控件在深色气泡里会带一条
   系统菜单，老 WebView 上还会多画一层边框。

   ⚠️ 和 app.js 共享全局作用域（classic script），不用 module 的原因见 app.js 首部。
   ⚠️ 必须排在 app.js 之前加载：boot() 会调 songReset()/paintSong()。

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

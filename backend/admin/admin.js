"use strict";
const $ = id => document.getElementById(id);
const apiBase = document.documentElement.dataset.adminBasePath + "/api/";
let state, proof = "", restoreRevision = null, busy = false;
const names = {"gpt-4o-mini-transcribe":"GPT-4o mini Transcribe · 日常口述", "gpt-4o-transcribe":"GPT-4o Transcribe", "whisper-1":"Whisper", "gpt-4o-transcribe-diarize":"GPT-4o Transcribe Diarize · 不支持词汇提示"};
const messages = {admin_signed_in:"管理员登录",provider_test_passed:"转写测试成功",provider_test_failed:"转写测试失败",provider_config_saved:"配置已生效",transcription_provider_error:"线上转写服务错误"};
function announce(text) { $("message").textContent = text; }
function invalidate() { proof = ""; restoreRevision = null; $("save").disabled = true; $("save").textContent = "保存并生效"; $("test-result").hidden = true; }
function setBusy(value) { busy=value; for(const id of ["test","restore","refresh","model","account","api-key","history"]) $(id).disabled=value; $("save").disabled=value||!proof; if(!value && (!state || state.history.length<2)){ $("restore").disabled=true; $("history").disabled=true; } }
async function api(path, body) {
  const result = await fetch(apiBase+path, {method:body===undefined?"GET":"POST", headers:body===undefined?{}:{"Content-Type":"application/json"}, body:body===undefined?undefined:JSON.stringify(body), credentials:"same-origin", cache:"no-store"});
  const data = await result.json();
  if(!result.ok) {
    if(result.status===401) showLogin();
    throw new Error(typeof data.detail === "string" ? data.detail : "请求未完成，请检查输入。");
  }
  return data;
}
function showLogin(){ $("login-panel").hidden=false; $("console").hidden=true; $("logout").hidden=true; state=null; invalidate(); $("api-key").value=""; }
function timeLabel(value){return value ? new Date(value).toLocaleString() : "服务器初始配置";}
function option(value,text){const node=document.createElement("option");node.value=value;node.textContent=text;return node;}
function render(){
  $("login-panel").hidden=true;$("console").hidden=false;$("logout").hidden=false;
  const c=state.current;
  $("current-model").textContent=c.model;$("current-account").textContent=c.account_id;
  $("current-key").textContent=c.key_configured ? "密钥指纹 · "+c.key_fingerprint : "尚未配置密钥";
  $("current-time").textContent=timeLabel(c.updated_at);
  $("model").replaceChildren(...state.models.map(m=>option(m.id,names[m.id]||m.id)));$("model").value=c.model;
  $("account").value=c.account_id;$("api-key").value="";
  $("history").replaceChildren(...state.history.slice(1).map(h=>option(h.revision,h.model+" · "+timeLabel(h.updated_at))));
  $("restore").disabled=state.history.length<2;$("history").disabled=state.history.length<2;
  $("restore-hint").textContent=state.history.length<2?"第一次保存后，这里会保留之前的配置。":"恢复不会改变用户积分或交易记录。";
  $("events").replaceChildren();
  for(const e of state.events){const item=document.createElement("li"),label=document.createElement("span"),t=document.createElement("time");label.textContent=(messages[e.kind]||e.kind)+(e.model?" · "+e.model:"")+(e.latency_ms?" · "+(e.latency_ms/1000).toFixed(1)+" 秒":"")+(e.status?" · "+e.status:"");t.textContent=new Date(e.time*1000).toLocaleString();item.append(label,t);$("events").append(item);}
  if(!state.events.length){const item=document.createElement("li");item.textContent="暂无活动";$("events").append(item);}
  invalidate(); modelHelp();
}
function modelHelp(){const m=state?.models.find(x=>x.id===$("model").value);if(!m)return;$("model-help").textContent=m.pricing.basis==="audio_minutes"?"按音频时长计费；价格与计费规则由服务端统一管理。":"按供应商返回的用量计费；价格与计费规则由服务端统一管理。";}
function payload(){return {model:$("model").value,account_id:$("account").value.trim(),api_key:$("api-key").value.trim(),expected_revision:state.current.revision,restore_revision:restoreRevision,test_token:proof};}
async function load(){state=await api("state");render();}
async function test(restore=false){
  if(busy||!state)return;
  if(!restore&&!$("config-form").reportValidity())return;
  invalidate();restoreRevision=restore?$("history").value:null;
  if(restore&&!restoreRevision)return;
  setBusy(true);announce("正在测试合成语音，当前生效配置保持不变…");
  try{const result=await api("test",payload());proof=result.test_token;$("test-result").textContent="测试成功 · "+(result.latency_ms/1000).toFixed(1)+" 秒\n"+result.transcript;$("test-result").hidden=false;$("save").textContent=restore?"确认恢复此配置":"保存并生效";announce(restore?"旧配置测试成功，点击“确认恢复此配置”生效。":"测试成功，点击“保存并生效”应用更改。");}
  catch(e){proof="";announce(e.message);}finally{setBusy(false);}
}
$("login-form").addEventListener("submit",async e=>{e.preventDefault();const button=e.submitter;button.disabled=true;try{await api("login",{password:$("password").value});$("password").value="";await load();announce("");}catch(error){announce(error.message);}finally{button.disabled=false;}});
$("logout").addEventListener("click",async()=>{try{await api("logout",{});showLogin();announce("已退出。");}catch(e){announce(e.message);}});
$("refresh").addEventListener("click",async()=>{try{await load();announce("状态已刷新。");}catch(e){announce(e.message);}});
for(const id of ["model","account","api-key","history"])$(id).addEventListener("input",()=>{invalidate();modelHelp();});
$("test").addEventListener("click",()=>test());$("restore").addEventListener("click",()=>test(true));
$("config-form").addEventListener("submit",async e=>{e.preventDefault();if(busy||!proof)return;setBusy(true);try{await api("config",payload());await load();announce("新配置已生效。");}catch(error){invalidate();announce(error.message);}finally{setBusy(false);}});
load().catch(e=>{if(!state)showLogin();announce(e.message.includes("sign in")?"":e.message);});

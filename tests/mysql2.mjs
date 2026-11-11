// Integration tests for the REAL SQL catalogs through the selected mysql2 driver.
// Requires an isolated local MySQL 8.4; no Express or live LLM/API calls.
import mysql from 'mysql2/promise';
import {readFile, writeFile} from 'node:fs/promises';
import {randomBytes, createHash} from 'node:crypto';
import assert from 'node:assert/strict';

const root=new URL('../',import.meta.url);
const db=`starter_verify_${randomBytes(6).toString('hex')}`;
const config={host:process.env.DB_HOST||'127.0.0.1',port:Number(process.env.DB_PORT||33306),
 user:process.env.DB_USER||'root',password:process.env.DB_PASSWORD||'',namedPlaceholders:true,
 supportBigNumbers:true,bigNumberStrings:true,dateStrings:true,timezone:'Z',multipleStatements:false};
const connections=[];const passed=[];const catalogs=new Map();
const read=name=>readFile(new URL(name,root),'utf8');
const clean=s=>s.split('\n').filter(l=>!l.trimStart().startsWith('--')&&!/^\s*USE /i.test(l)).join('\n');
function split(source){
 const s=clean(source),out=[];let quote=null,start=0;
 for(let i=0;i<s.length;i++){
  const ch=s[i];
  if(quote){
   if(ch==='\\'){i++;continue;}
   if(ch===quote){if(s[i+1]===quote)i++;else quote=null;}
  } else if(ch==="'"||ch==='"'||ch==='`')quote=ch;
  else if(ch===';'){if(s.slice(start,i).trim())out.push(s.slice(start,i).trim());start=i+1;}
 }
 if(s.slice(start).trim())out.push(s.slice(start).trim());return out;
}
const digest=s=>createHash('sha256').update(s).digest('hex');
async function connection(use=true){const c=await mysql.createConnection(config);connections.push(c);
 await c.query("SET time_zone='+00:00'");if(use)await c.query(`USE \`${db}\``);return c;}
async function q(code,p={},c=main){let result;for(const sql of split(catalogs.get(code))) [result]=await c.query(sql,p);return result;}
function ok(name,value=true){assert.ok(value,name);passed.push(name);console.log(`PASS: ${name}`);}
async function rejects(name,fn,errno){await assert.rejects(fn,e=>!errno||e.errno===errno);ok(name);}
async function tx(c,fn){await c.beginTransaction();try{const r=await fn();await c.commit();return r;}catch(e){await c.rollback();throw e;}}
let main;
try{
 main=await connection(false);
 await main.query(`CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci`);
 await main.query(`USE \`${db}\``);
 for(const name of ['01_schema.sql','08_prompt_schema.sql','09_ai_schema.sql','03_seed.sql']){
  const text=(await read(name)).replaceAll('vacancy_aggregator',db);
  for(const sql of split(text))await main.query(sql);
 }
 await main.query(`USE \`${db}\``);
 for(const name of ['02_queries.sql','05_auth_queries.sql','06_prompt_queries.sql','10_pipeline_queries.sql']){
  const text=await read(name),matches=[...text.matchAll(/^-- (Q(?:A|P|I)?\d{2})\./gm)];
  for(let i=0;i<matches.length;i++)catalogs.set(matches[i][1],text.slice(matches[i].index,matches[i+1]?.index??text.length));
 }
 const [tables]=await main.query('SHOW TABLES');ok('all 17 tables created from canonical scripts',tables.length===17);
 const [empty]=await main.query('SELECT COUNT(*) AS n FROM users');ok('catalog seed contains no accounts',Number(empty[0].n)===0);
 const [columns]=await main.query('SHOW COLUMNS FROM vacancies');ok('no raw source JSON or contact columns',!columns.some(x=>/raw_payload|contact|email|phone/i.test(x.Field)));
 async function register(subject,email){await tx(main,async()=>{await q('QA01',{auth_subject:subject,email,normalized_email:email.toLowerCase(),password_hash:'TEST_ONLY_NOT_A_REAL_PASSWORD_HASH',role:'admin'});await q('QA02',{auth_subject:subject,display_name:subject});});
  return (await q('QA03',{auth_subject:subject}))[0].user_id;}
 const u1=await register('account-one','First@Example.invalid'),u2=await register('account-two','second@example.invalid');
 ok('registration defaults to user despite extra role parameter',(await q('QA03',{auth_subject:'account-one'}))[0].role==='user');
 await rejects('case-variant duplicate email rejected',()=>q('QA01',{auth_subject:'dup',email:'FIRST@example.invalid',normalized_email:'FIRST@EXAMPLE.INVALID',password_hash:'TEST'}),1062);
 await register('account-three','third@example.invalid');
 const clients=await Promise.all(Array.from({length:6},()=>connection()));
 const profiles=await Promise.all(clients.map(c=>q('QA02',{auth_subject:'account-three',display_name:'retry'},c)));
 ok('concurrent profile creation returns one ID',new Set(profiles.map(x=>x[0].user_id)).size===1);
 ok('unknown principal creates no profile',(await q('QA02',{auth_subject:'missing',display_name:'none'})).length===0);
 await main.query("UPDATE users SET status='blocked' WHERE id='account-two'");
 ok('blocked account fails profile resolution',(await q('QA03',{auth_subject:'account-two'})).length===0);
 await main.query("UPDATE users SET status='active' WHERE id='account-two'");
 const demo=split(await read('07_demo_profile_seed.sql'));for(let repeat=0;repeat<2;repeat++)for(const sql of demo)await main.query(sql,{auth_subject:'account-one'});
 const [skills]=await main.query('SELECT * FROM user_skills WHERE user_id=?',[u1]);ok('personal demo seed idempotent',skills.length===3);
 const defaults={user_id:u1,search:'',city:null,region_name:null,country_code:null,region_code:null,specialisation:null,typical_positions_json:null,
  include_remote:0,work_format:null,schedule_type:null,contract_type:null,employment_type:null,min_salary:null,currency:'RUB',salary_period:'month',salary_gross:null,
  only_no_experience:0,require_all_required:0,experience_months:null,page_size:100,offset:0};
 const search=over=>q('Q03',{...defaults,...over});const ids=rows=>rows.map(r=>Number(r.id)).sort((a,b)=>a-b);
 const expect=async(name,filters,want)=>{assert.deepEqual(ids(await search(filters)),want);ok(name);};
 await expect('missing optional prompt fields still find active vacancies',{},[1,2,3,4,5]);
 await expect('remote filter',{work_format:'remote'},[2,5]);
 await expect('hybrid filter',{work_format:'hybrid'},[4]);
 await expect('hybrid retains city constraint',{work_format:'hybrid',city:'Донецк',include_remote:1},[]);
 await expect('city plus remote',{city:'Донецк',include_remote:1},[1,2,3,5]);
 await expect('region code',{region_code:'9300000000000'},[1,3]);
 await expect('specialisation filter',{specialisation:'Информационные технологии'},[2,4]);
 await expect('canonical profession array',{typical_positions_json:JSON.stringify(['Программист'])},[2,4]);
 await expect('full-time filter',{employment_type:'full_time'},[1,2,3,4]);
 await expect('five-two schedule',{schedule_type:'five_two'},[2,3,4]);
 await expect('salary filter',{min_salary:60000},[2,4]);
 await expect('salary tax basis',{min_salary:60000,salary_gross:1},[4]);
 await expect('no experience',{experience_months:0},[1,2,3,5]);
 await expect('required skills',{require_all_required:1},[1,2,3,5]);
 await expect('Cyrillic fulltext',{search:'магазине'},[1,3]);
 ok('unknown skills do not produce 100 percent',(await search({})).find(x=>Number(x.id)===5).skill_match_percent===null);
 await main.query("UPDATE vacancies SET contract_type='fixed_term' WHERE id=3");
 await expect('full-time does not imply permanent',{employment_type:'full_time',contract_type:'permanent'},[1,2,4]);
 await main.query("UPDATE vacancies SET contract_type='permanent' WHERE id=3");
 ok('pagination works with mysql2 named values',(await search({page_size:1,offset:0}))[0].id!==(await search({page_size:1,offset:1}))[0].id);
 await main.query("UPDATE vacancies SET work_format='unknown' WHERE id=2");await expect('unknown format excluded by strict filter',{work_format:'remote'},[5]);await main.query("UPDATE vacancies SET work_format='remote' WHERE id=2");
 await q('Q05',{user_id:u1,vacancy_id:1});await q('Q05',{user_id:u1,vacancy_id:1});
 const [f]=await main.query('SELECT * FROM favorites WHERE user_id=? AND vacancy_id=1',[u1]);ok('favorite deduplicated',f.length===1);
 await q('Q06',{user_id:u2,vacancy_id:1});ok('another user cannot remove favorite',(await q('Q07',{user_id:u1,page_size:100,offset:0})).some(x=>Number(x.id)===1));
 ok('archived favorite remains visible',(await q('Q07',{user_id:u1,page_size:100,offset:0})).some(x=>Number(x.id)===6));
 ok('click returns stored original URL',(await q('Q08',{user_id:u1,vacancy_id:1}))[0].original_url==='https://example.com/demo/v1');
 ok('click history private',(await q('Q09',{user_id:u2,page_size:100,offset:0})).length===0);
 const company=(await q('Q01',{source_id:1,company_external_id:'test',company_name:'Test',company_url:null}))[0].company_id;
 const imported={source_id:1,external_id:'company:test',company_id:company,title:'Test vacancy',typical_position:null,code_profession:null,specialisation:null,
  description:'Only test',requirements:null,responsibilities:null,original_url:'https://example.com/test',country_code:'RU',region_name:null,region_code:null,
  latitude:null,longitude:null,city:null,address_text:null,work_format:'unknown',employment_type:'unknown',schedule_text:null,schedule_type:'unknown',contract_type:'unknown',
  salary_min:null,salary_max:null,currency:null,salary_period:'unknown',salary_gross:null,experience_months_min:null,status:'active',published_at:null,source_updated_at:null};
 const importedId=(await q('Q02',imported))[0].vacancy_id;
 const hash=async id=>(await main.query('SELECT HEX(content_hash) AS h FROM vacancies WHERE id=?',[id]))[0][0].h;
 const hash1=await hash(importedId);ok('import upsert stable ID',(await q('Q02',imported))[0].vacancy_id===importedId);
 ok('same content keeps hash despite poll time update',await hash(importedId)===hash1);
 await q('Q02',{...imported,title:'Updated'});ok('changed input invalidates hash',await hash(importedId)!==hash1);
 await rejects('negative salary rejected',()=>main.query('UPDATE vacancies SET salary_min=-1 WHERE id=1'),3819);
 await rejects('invalid coordinates rejected',()=>main.query('UPDATE vacancies SET latitude=91 WHERE id=1'),3819);
 await rejects('company must belong to same source',()=>main.query('UPDATE vacancies SET company_id=1 WHERE id=?',[importedId]),1452);
 await q('Q12',{source_id:1,external_id:imported.external_id});ok('explicit archive',(await main.query('SELECT status FROM vacancies WHERE id=?',[importedId]))[0][0].status==='archived');
 // Refresh-token persistence: test fixtures store no real plaintext password/token.
 const token='ab'.repeat(32),auth={auth_subject:'account-one',token_hash_hex:token,expires_at:'2099-01-01 00:00:00',verified_password_hash:'TEST_ONLY_NOT_A_REAL_PASSWORD_HASH'};
 await q('QA05',auth);const locked=await tx(main,()=>q('QA06',{token_hash_hex:token}));ok('valid refresh token found',locked.length===1);
 await q('QA07',{refresh_id:locked[0].id,auth_subject:'account-one'});ok('consumed refresh cannot be reused',(await q('QA06',{token_hash_hex:token})).length===0);
 ok('wrong verified hash cannot create refresh',(await q('QA05',{...auth,token_hash_hex:'cd'.repeat(32),verified_password_hash:'wrong'})).affectedRows===0);
 await q('QA05',{...auth,token_hash_hex:'12'.repeat(32)});await tx(main,()=>q('QA08',{auth_subject:'account-one'}));
 ok('logout all bumps token version',(await q('QA03',{auth_subject:'account-one'}))[0].token_version===1);
 ok('logout all revokes refresh',(await q('QA06',{token_hash_hex:'12'.repeat(32)})).length===0);
 await rejects('account deletion restricted while profile exists',()=>main.query("DELETE FROM users WHERE id='account-one'"),1451);
 // Source/scope-specific cursor and import audit.
 const scope={source_id:1,scope_hash_hex:digest('regions:93'),scope_json:JSON.stringify({regions:['9300000000000']}),mode:'full',window_from:null,window_to:'2026-11-10 10:00:00'};
 const run=await q('QI02',scope);await rejects('one running import per source/scope',()=>q('QI02',scope),1062);
 ok('running import does not advance cursor',(await q('QI01',scope))[0].modified_through===null);
 const counters={source_id:1,import_run_id:run.insertId,status:'succeeded',records_seen:5,inserted_count:4,updated_count:1,skipped_count:0,error_code:null};await q('QI03',counters);
 ok('successful full import advances scope cursor',(await q('QI01',scope))[0].modified_through==='2026-11-10 10:00:00.000000');
 const partial=await q('QI02',{...scope,mode:'incremental',window_from:scope.window_to,window_to:'2026-11-10 11:00:00'});await q('QI03',{...counters,import_run_id:partial.insertId,status:'partial',error_code:'UPSTREAM_TIMEOUT'});
 ok('partial import never advances cursor',(await q('QI01',scope))[0].modified_through==='2026-11-10 10:00:00.000000');
 ok('another region scope has separate cursor',(await q('QI01',{...scope,scope_hash_hex:digest('regions:61')}))[0].modified_through===null);
 ok('partial run cannot mark source fully successful',(await q('Q13',{source_id:1,import_run_id:partial.insertId})).affectedRows===0);
 await q('Q13',{source_id:1,import_run_id:run.insertId});
 ok('import row lookup finds canonical vacancy',(await tx(main,()=>q('QI14',{source_id:1,external_id:imported.external_id}))).length===1);
 ok('audit reports import counts',(await q('QI04',{page_size:100,offset:0})).length===2);
 // AI cache and real concurrent SKIP LOCKED transactions.
 const version={provider:'test',model:'model',prompt_version:'v1'};
 await q('QI05',{...version,vacancy_id:1});await q('QI05',{...version,vacancy_id:1});await q('QI05',{...version,vacancy_id:2});
 const [queued]=await main.query('SELECT * FROM vacancy_ai_summaries');ok('cache enqueue idempotent',queued.length===2);
 const c1=clients[0],c2=clients[1];await c1.beginTransaction();await c2.beginTransaction();
 const j1=(await q('QI06',{},c1))[0],j2=(await q('QI06',{},c2))[0];ok('SKIP LOCKED assigns different jobs',j1.id!==j2.id);
 const claim1={summary_id:j1.id,lease_token_hex:'11'.repeat(16),lease_seconds:60},claim2={summary_id:j2.id,lease_token_hex:'22'.repeat(16),lease_seconds:60};
 ok('invalid lease duration rejected',(await q('QI07',{...claim1,lease_seconds:0},c1)).affectedRows===0);
 await q('QI07',claim1,c1);await q('QI07',claim2,c2);await c1.commit();await c2.commit();
 ok('claimed current content available',(await q('QI08',claim1)).length===1);
 const summary=JSON.stringify({simpleTitle:'Работа',whatYouDo:['Помогать'],requirements:['Навыки'],conditions:['По договорённости'],beginnerFriendly:true});
 await rejects('malformed AI object rejected',()=>q('QI09',{...claim1,result_json:'{}'}),3819);
 await q('QI09',{...claim1,result_json:summary});ok('valid current cache returned',(await q('QI13',{...version,vacancy_id:j1.vacancy_id})).length===1);
 ok('late duplicate completion rejected',(await q('QI09',{...claim1,result_json:summary})).affectedRows===0);
 await main.query('UPDATE vacancies SET description=CONCAT(description,?) WHERE id=?',[' Изменение',j1.vacancy_id]);
 ok('changed vacancy never returns stale cache',(await q('QI13',{...version,vacancy_id:j1.vacancy_id})).length===0);
 await q('QI05',{...version,vacancy_id:j1.vacancy_id});
 const next=await tx(main,async()=>{const j=(await q('QI06'))[0];await q('QI07',{summary_id:j.id,lease_token_hex:'33'.repeat(16),lease_seconds:60});return j;});
 await main.query('UPDATE vacancy_ai_summaries SET lease_expires_at=TIMESTAMPADD(SECOND,-1,UTC_TIMESTAMP(6)) WHERE id=?',[next.id]);
 ok('expired lease cannot complete',(await q('QI09',{summary_id:next.id,lease_token_hex:'33'.repeat(16),result_json:summary})).affectedRows===0);
 await q('QI11',{max_attempts:3,retry_seconds:0});
 const reclaim=await tx(main,async()=>{const j=(await q('QI06'))[0];await q('QI07',{summary_id:j.id,lease_token_hex:'44'.repeat(16),lease_seconds:60});return j;});
 ok('expired job requeued',reclaim.id===next.id);
 ok('old worker fenced after reclaim',(await q('QI09',{summary_id:next.id,lease_token_hex:'33'.repeat(16),result_json:summary})).affectedRows===0);
 await q('QI10',{summary_id:next.id,lease_token_hex:'44'.repeat(16),error_code:'PROVIDER_DOWN'});
 ok('AI failure uses original-text fallback',(await q('QI13',{...version,vacancy_id:next.vacancy_id})).length===0);
 ok('bounded failure can retry',(await q('QI12',{summary_id:next.id,max_attempts:3,retry_seconds:0})).affectedRows===1);
 // Recommendation directions can only reference saved SQL candidates of same run.
 const rec=(await q('QP01',{user_id:u1,prompt_text:'Знаю C# и SQL, хочу постоянную удалённую работу.'})).insertId;
 const owner={run_id:rec,user_id:u1},foreign={run_id:rec,user_id:u2};
 ok('foreign user cannot parse run',(await q('QP02',{...foreign,parsed_profile:'{}',parser_model:'test'})).affectedRows===0);
 await rejects('parsed profile must be object',()=>q('QP02',{...owner,parsed_profile:'[]',parser_model:'test'}),3819);
 await q('QP02',{...owner,parsed_profile:JSON.stringify({skills:['C#','SQL'],interests:['IT'],education:'колледж',work_format:'remote'}),parser_model:'test'});
 await q('QP03',{...owner,recommendation_model:'test',prompt_version:'v1'});
 await q('QP04',{...owner,vacancy_id:1,position:1,skill_match_percent:100});await q('QP04',{...owner,vacancy_id:2,position:2,skill_match_percent:67});
 await rejects('top candidate limit enforced',()=>q('QP04',{...owner,vacancy_id:3,position:51,skill_match_percent:100}),3819);
 const d=(await q('QP06',{...owner,position:1,title:'Разработка',why_suitable:'Есть C# и SQL.'})).insertId;
 await q('QP07',{...owner,direction_id:d,vacancy_id:2,position:1});
 ok('LLM cannot link a noncandidate',(await q('QP07',{...owner,direction_id:d,vacancy_id:4,position:2})).affectedRows===0);
 await rejects('DB FK also blocks fabricated candidate membership',()=>main.query('INSERT INTO recommendation_direction_vacancies(run_id,direction_id,vacancy_id,position) VALUES (?,?,4,2)',[rec,d]),1452);
 ok('foreign user cannot link result',(await q('QP07',{...foreign,direction_id:d,vacancy_id:1,position:2})).affectedRows===0);
 await q('QP08',{...owner,result_note:null});
 ok('owner sees grouped result',(await q('QP11',owner)).length===1);
 ok('other user cannot read grouped result',(await q('QP11',foreign)).length===0);
 ok('recommendation history persists',(await q('QP10',{user_id:u1,page_size:10,offset:0})).length===1);
 ok('finished result cannot be overwritten by late error',(await q('QP09',{...owner,error_code:'LATE'})).affectedRows===0);
 const [versionRow]=await main.query('SELECT VERSION() AS version');
 await writeFile(new URL('VERIFICATION.md',root),`# Проверка БД\n\nДата: 11 ноября 2026. MySQL ${versionRow[0].version}, mysql2 — версия из package-lock.json.\n\nПройдено проверок: **${passed.length}**. Использованы реальные SQL-каталоги, именованные параметры mysql2, две одновременные транзакции очереди и временная БД.\n\n${passed.map(s=>'- '+s).join('\n')}\n\nПроверка не запускает Express, внешний импорт и LLM. Хеширование паролей, JWT, валидацию Zod, удаление контактных блоков и API-политики реализует и проверяет backend. Фикстуры паролей здесь не являются рабочими хешами.\n`);
 console.log(`ALL ${passed.length} CHECKS PASSED`);
} finally {
 for(const c of connections)try{await c.rollback();}catch{}
 if(main)try{await main.query(`DROP DATABASE IF EXISTS \`${db}\``);}catch{}
 await Promise.allSettled(connections.map(c=>c.end()));
}

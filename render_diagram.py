"""Generate selected-field ER views and Mermaid from the canonical SQL files."""
from pathlib import Path
import html
import re
import subprocess

ROOT=Path(__file__).resolve().parent
source='\n'.join((ROOT/name).read_text() for name in ['01_schema.sql','08_prompt_schema.sql','09_ai_schema.sql'])
schemas=dict(re.findall(r'CREATE TABLE (\w+) \(([\s\S]*?)\) ENGINE=InnoDB;',source))
# All 17 tables; labels show important columns, SQL holds the complete definitions.
tables={
 'sources':('Источники','#0f766e',['id','code','name','last_success_at']),
 'companies':('Работодатели','#0f766e',['id','source_id','external_id','name']),
 'vacancies':('Вакансии','#1d4ed8',['id','source_id','external_id','company_id','title','typical_position','specialisation','region_code','work_format','schedule_type','salary_min','salary_max','content_hash']),
 'users':('Учётные записи','#be123c',['id','normalized_email','password_hash','role','status','token_version']),
 'refresh_tokens':('Обновление входа','#be123c',['id','user_subject','token_hash','expires_at','revoked_at']),
 'user_profiles':('Соискатели','#b45309',['id','auth_subject','display_name','city']),
 'skills':('Справочник навыков','#7c3aed',['id','name','normalized_name']),
 'user_skills':('Навыки пользователя','#7c3aed',['user_id','skill_id']),
 'vacancy_skills':('Навыки вакансии','#7c3aed',['vacancy_id','skill_id','is_required']),
 'favorites':('Избранное','#475569',['user_id','vacancy_id','created_at']),
 'outbound_clicks':('Переходы к источнику','#475569',['id','user_id','vacancy_id','clicked_at']),
 'import_runs':('Журнал импорта','#0f766e',['id','source_id','scope_hash','status','window_from','window_to','inserted_count','updated_count']),
 'vacancy_ai_summaries':('Кеш и очередь ИИ','#0369a1',['id','vacancy_id','provider','model','prompt_version','source_hash','status','lease_token','lease_expires_at','result_json']),
 'recommendation_runs':('Рассказ и подборка','#0369a1',['id','user_id','prompt_text','parsed_profile','status','created_at']),
 'recommendation_candidates':('SQL-кандидаты (до 50)','#0369a1',['run_id','vacancy_id','position','source_hash','skill_match_percent']),
 'recommendation_directions':('Направления (до 5)','#0369a1',['id','run_id','position','title','why_suitable']),
 'recommendation_direction_vacancies':('Вакансии направлений','#0369a1',['run_id','direction_id','vacancy_id','position']),
}
edges=[
 ('sources','companies'),('sources','vacancies'),('sources','import_runs'),('companies','vacancies'),
 ('users','user_profiles'),('users','refresh_tokens'),('user_profiles','user_skills'),('skills','user_skills'),
 ('skills','vacancy_skills'),('vacancies','vacancy_skills'),('user_profiles','favorites'),('vacancies','favorites'),
 ('user_profiles','outbound_clicks'),('vacancies','outbound_clicks'),('vacancies','vacancy_ai_summaries'),
 ('user_profiles','recommendation_runs'),('recommendation_runs','recommendation_candidates'),
 ('vacancies','recommendation_candidates'),('recommendation_runs','recommendation_directions'),
 ('recommendation_directions','recommendation_direction_vacancies'),('recommendation_candidates','recommendation_direction_vacancies')]

def meta(name):
 s=schemas[name]
 cols=dict(re.findall(r'^  ([a-z]\w*)\s+([A-Z]+)[^\n]*',s,re.M))
 pk=set()
 for group in re.findall(r'PRIMARY KEY \(([^)]+)\)',s): pk.update(x.strip() for x in group.split(','))
 for line in s.splitlines():
  if 'PRIMARY KEY' in line and re.match(r'^  [a-z]',line):pk.add(line.strip().split()[0])
 fk={x.strip() for group in re.findall(r'FOREIGN KEY \(([^)]+)\)',s) for x in group.split(',')}
 return cols,pk,fk

mermaid=['erDiagram']
for a,b in edges:
 link='||--o|' if (a,b)==('users','user_profiles') else '||--o{'
 if (a,b)==('companies','vacancies'):link='o|--o{'
 mermaid.append(f'    {a} {link} {b} : "связь"')
for name,(_,_,fields) in tables.items():
 types,pk,fk=meta(name);mermaid.append(f'    {name} {{')
 for f in fields:
  flags=','.join(x for x,yes in [('PK',f in pk),('FK',f in fk)] if yes)
  mermaid.append(f'        {types[f].lower()} {f} {flags}'.rstrip())
 mermaid.append('    }')
(ROOT/'04_diagram.mmd').write_text('\n'.join(mermaid)+'\n')

def render(stem,names,title):
 lines=['digraph ER {','graph [rankdir=LR, bgcolor="white",pad=0.4,nodesep=0.35,ranksep=0.8,splines=polyline,',
        f'fontname="DejaVu Sans",fontsize=20,labelloc=t,label="СТАРТЕР  /  {title}\\nMySQL 8.4 · Node.js / mysql2"];',
        'node [shape=plain,fontname="DejaVu Sans",fontsize=11];',
        'edge [color="#94a3b8",arrowsize=0.7,fontname="DejaVu Sans",fontsize=9];']
 for name in names:
  title,color,fields=tables[name];_,pk,fk=meta(name)
  header=f'<TR><TD BGCOLOR="{color}" ALIGN="LEFT"><FONT COLOR="white"><B>{name}</B><BR/>{title}</FONT></TD></TR>'
  rows=''
  for f in fields:
   flags=', '.join(x for x,yes in [('PK',f in pk),('FK',f in fk)] if yes)
   label=(flags+' ' if flags else '')+f
   rows+=f'<TR><TD ALIGN="LEFT">{html.escape(label)}</TD></TR>'
  lines.append(f'{name} [label=<<TABLE BORDER="1" COLOR="#cbd5e1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="6">{header}{rows}</TABLE>>];')
 for a,b in edges:
  if a in names and b in names:
   tail='0..1' if (a,b)==('companies','vacancies') else '1'
   head='0..1' if (a,b)==('users','user_profiles') else '0..N'
   lines.append(f'{a} -> {b} [taillabel="{tail}",headlabel="{head}"];')
 lines.append('}')
 path=ROOT/(stem+'.dot');path.write_text('\n'.join(lines))
 for fmt in ['png','pdf','svg']:subprocess.run(['dot','-T'+fmt,'-Gdpi=120',str(path),'-o',str(ROOT/(stem+'.'+fmt))],check=True)
render('diagram',list(tables),'схема БД')
render('diagram-pipeline',['vacancies','vacancy_ai_summaries','user_profiles','recommendation_runs','recommendation_candidates','recommendation_directions','recommendation_direction_vacancies'],'кеш ИИ и рекомендации')
print('Generated 17-table diagram, pipeline view and Mermaid')

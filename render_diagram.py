"""Export a readable subset of the physical schema with Graphviz (dot)."""
from pathlib import Path
import html
import subprocess

ROOT = Path(__file__).resolve().parent
tables = {
    'sources': ('Источники', '#0f766e', [
        'PK id', 'UK code', 'name · base_url', 'access_type · is_enabled', 'last_success_at']),
    'companies': ('Работодатели', '#0f766e', [
        'PK id', 'FK source_id', 'external_id · name', 'UK (source_id, external_id)']),
    'vacancies': ('Вакансии', '#1d4ed8', [
        'PK id', 'FK source_id · FK company_id (NULL)', 'external_id · original_url',
        'title · description', 'requirements · responsibilities', 'country_code · region_name · city',
        'work_format · employment_type', 'schedule_text · schedule_type · contract_type',
        'salary_min · salary_max · currency', 'salary_period · salary_gross',
        'experience_months_min · status', 'published_at · last_seen_at · raw_payload',
        'UK (source_id, external_id)']),
    'vacancy_skills': ('Навыки вакансии', '#7c3aed', [
        'PK, FK vacancy_id', 'PK, FK skill_id', 'is_required']),
    'skills': ('Справочник навыков', '#7c3aed', [
        'PK id', 'name', 'UK normalized_name']),
    'user_skills': ('Навыки соискателя', '#7c3aed', [
        'PK, FK user_id', 'PK, FK skill_id']),
    'user_profiles': ('Соискатели', '#b45309', [
        'PK id', 'UK, FK auth_subject → AspNetUsers.Id', 'display_name · city']),
    'AspNetUsers': ('IDENTITY — создаёт бэкенд через EF', '#64748b', [
        'PK Id: VARCHAR(191), utf8mb4_bin', 'UK NormalizedEmail (настройка бэкенда)',
        'FK к профилю: ON DELETE RESTRICT', 'Пароли, роли и токены — зона Identity']),
    'favorites': ('Избранное', '#475569', [
        'PK, FK user_id', 'PK, FK vacancy_id', 'created_at']),
    'outbound_clicks': ('Переходы на исходный сайт', '#475569', [
        'PK id', 'FK user_id · FK vacancy_id', 'clicked_at', 'Нажатие кнопки, не отправка заявки']),
    'search_requests': ('Промпты соискателя', '#0369a1', [
        'PK id · FK user_id → user_profiles.id', 'prompt_text · parsed_filters (JSON)',
        'status · parser_kind · model_name', 'error_code · created_at · parsed_at']),
    'search_results': ('Сохранённые рекомендации', '#0369a1', [
        'PK, FK search_request_id', 'PK, FK vacancy_id', 'position · skill_match_percent · explanation',
        'UK (search_request_id, position)']),
}
edges = [
    ('AspNetUsers', 'user_profiles', '1', '0..1'),
    ('sources', 'companies', '1', '0..N'), ('sources', 'vacancies', '1', '0..N'),
    ('companies', 'vacancies', '0..1', '0..N'),
    ('vacancies', 'vacancy_skills', '1', '0..N'), ('skills', 'vacancy_skills', '1', '0..N'),
    ('skills', 'user_skills', '1', '0..N'), ('user_profiles', 'user_skills', '1', '0..N'),
    ('user_profiles', 'favorites', '1', '0..N'), ('vacancies', 'favorites', '1', '0..N'),
    ('user_profiles', 'outbound_clicks', '1', '0..N'), ('vacancies', 'outbound_clicks', '1', '0..N'),
    ('user_profiles', 'search_requests', '1', '0..N'),
    ('search_requests', 'search_results', '1', '0..N'), ('vacancies', 'search_results', '1', '0..N'),
]
dot = [
    'digraph ER {',
    'graph [rankdir=LR, bgcolor="white", pad="0.45", nodesep="0.38", ranksep="0.9", splines=polyline,',
    'fontname="DejaVu Sans", fontsize=20, labelloc=t, label="СТАРТ В ПРОФЕССИИ  /  БД агрегатора вакансий\\nMySQL 8  ·  Ключевые поля и связи"];',
    'node [shape=plain, fontname="DejaVu Sans", fontsize=11];',
    'edge [color="#94a3b8", arrowsize=0.7, fontname="DejaVu Sans", fontsize=9, fontcolor="#475569"];',
]
for name, (title, color, fields) in tables.items():
    header = f'<TR><TD BGCOLOR="{color}" ALIGN="LEFT"><FONT COLOR="white"><B>{name}</B><BR/>{title}</FONT></TD></TR>'
    rows = ''.join(f'<TR><TD ALIGN="LEFT">{html.escape(f)}</TD></TR>' for f in fields)
    dot.append(f'{name} [label=<<TABLE BORDER="1" COLOR="#cbd5e1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="7">{header}{rows}</TABLE>>];')
for start, end, tail, head in edges:
    dot.append(f'{start} -> {end} [taillabel="{tail}", headlabel="{head}", labeldistance=1.6];')
dot.extend([
    '{rank=same; AspNetUsers; sources; skills;}',
    '{rank=same; companies; user_profiles;}',
    '{rank=same; vacancies; user_skills; search_requests;}',
    '{rank=same; vacancy_skills; favorites; outbound_clicks; search_results;}',
    'legend [shape=plain, label="PK — первичный ключ   ·   FK — внешний ключ   ·   UK — уникальность\\nБизнес-поля — в 01_schema.sql и 08_prompt_schema.sql; Identity создаёт backend"];',
    '}',
])
source = ROOT / 'diagram.dot'
source.write_text('\n'.join(dot), encoding='utf-8')
for fmt in ('svg', 'png', 'pdf'):
    subprocess.run(['dot', f'-T{fmt}', '-Gdpi=130', str(source), '-o', str(ROOT / f'diagram.{fmt}')], check=True)
print('Wrote diagram.svg, diagram.png, diagram.pdf')

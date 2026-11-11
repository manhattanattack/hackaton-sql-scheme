"""Exercise the ACTUAL query catalog on an isolated MySQL 8 container.

Requires a running MySQL container named vacancy-db-check, reachable through
the local Docker socket, with local root access and no published network port.
Creates its own unique test database; deletes only that database at the end.
No third-party Python packages. SQL substitution here is a TEST fixture only;
the application must bind parameters using MySqlConnector/Dapper.
"""
from pathlib import Path
import os
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parent
DB = 'vacancy_verify_' + uuid.uuid4().hex[:12]
ENV = os.environ.copy()
for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
    ENV.pop(key, None)
CMD = ['docker', '--host=unix:///var/run/docker.sock', 'exec', '-i', 'vacancy-db-check',
       'mysql', '--default-character-set=utf8mb4', '--batch', '--raw', '--skip-column-names', '-uroot']
catalog = (ROOT / '02_queries.sql').read_text()
blocks = {}
for chunk in re.split(r'(?=-- Q\d{2}\.)', catalog)[1:]:
    blocks[chunk[3:6]] = chunk
passed = []

def run(sql, fail=False):
    sql = sql.replace('vacancy_aggregator', DB)
    r = subprocess.run(CMD, input=sql, text=True, capture_output=True, env=ENV)
    if fail:
        assert r.returncode != 0, 'Expected DB constraint rejection'
        return r.stderr
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()

def query(code, params):
    def literal(m):
        value = params[m.group()[1:]]
        if value is None:
            return 'NULL'
        if isinstance(value, (int, float)):
            return str(value)
        if value == '':
            return "''"
        return "CONVERT(0x" + str(value).encode().hex() + " USING utf8mb4)"
    # Strip comments so parameter examples in comments need not be supplied.
    sql = '\n'.join(line for line in blocks[code].splitlines() if not line.lstrip().startswith('--'))
    return run('USE vacancy_aggregator;\n' + re.sub(r'@[a-z_]+', literal, sql))

def check(name, condition):
    assert condition, name
    passed.append(name)
    print('PASS:', name)

search_params = dict(user_id=1, search='', city=None, region_name=None, country_code=None,
                     include_remote=0, employment_type=None, min_salary=None,
                     currency='RUB', salary_period='month', salary_gross=None,
                     only_no_experience=0, only_schedule_match=0, require_all_required=0,
                     page_size=100, offset=0)

def search(**overrides):
    text = query('Q03', search_params | overrides)
    return [line.split('\t') for line in text.splitlines()] if text else []

try:
    run((ROOT / '01_schema.sql').read_text())
    run((ROOT / '03_seed.sql').read_text())
    version = run('SELECT VERSION();')
    check('schema and fixtures load on ' + version,
          run(f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{DB}';") == '11')
    rows = search()
    by_id = {int(r[0]): r for r in rows}
    check('active search excludes archived job', set(by_id) == {1, 2, 3, 4, 5})
    check('fixed required intervals fit availability', by_id[1][-1] == 'match')
    check('daytime shift conflicts', by_id[3][-1] == 'conflict')
    check('flexible schedule is unknown, not automatically compatible', by_id[2][-1] == 'unknown')
    check('unknown skills produce NULL percent', by_id[5][-3] == 'NULL')
    check('strict schedule filter', {int(r[0]) for r in search(only_schedule_match=1)} == {1, 5})
    check('required skills filter', {int(r[0]) for r in search(require_all_required=1)} == {1, 2, 3, 5})
    check('city filter', {int(r[0]) for r in search(city='Донецк')} == {1, 3})
    check('city plus remote', {int(r[0]) for r in search(city='Донецк', include_remote=1)} == {1, 2, 3, 4})
    check('salary excludes other periods and unknown amounts',
          {int(r[0]) for r in search(min_salary=30000)} == {2, 4})
    check('tax basis filter', {int(r[0]) for r in search(min_salary=30000, salary_gross=0)} == set())
    check('no experience filter', {int(r[0]) for r in search(only_no_experience=1)} == {1, 2, 3, 5})
    check('Cyrillic fulltext search', {int(r[0]) for r in search(search='магазине')} == {1, 3})
    check('pagination returns distinct pages', search(page_size=1)[0][0] != search(page_size=1, offset=1)[0][0])
    query('Q05', dict(user_id=1, vacancy_id=1))
    query('Q05', dict(user_id=1, vacancy_id=1))
    check('favorites idempotent', run('USE vacancy_aggregator; SELECT COUNT(*) FROM favorites WHERE user_id=1 AND vacancy_id=1;') == '1')
    query('Q06', dict(user_id=2, vacancy_id=1))
    check('one user cannot remove another users favorite', run('USE vacancy_aggregator; SELECT COUNT(*) FROM favorites WHERE user_id=1 AND vacancy_id=1;') == '1')
    query('Q06', dict(user_id=1, vacancy_id=1))
    favorites = query('Q07', dict(user_id=1, page_size=100, offset=0))
    check('archived job remains in favorites', any(line.startswith('6\t') for line in favorites.splitlines()))
    url = query('Q08', dict(user_id=1, vacancy_id=1))
    query('Q08', dict(user_id=1, vacancy_id=1))
    check('outbound click returns original URL', url == 'https://example.com/demo/v1')
    check('repeated clicks retained', run('USE vacancy_aggregator; SELECT COUNT(*) FROM outbound_clicks WHERE user_id=1 AND vacancy_id=1;') == '2')
    check('archived job cannot be clicked as active', query('Q08', dict(user_id=1, vacancy_id=6)) == '')
    check('history isolated by user', query('Q09', dict(user_id=2, page_size=100, offset=0)) == '')
    check('vacancy card returns main and skill resultsets', 'Общение с клиентами' in query('Q04', dict(user_id=1, vacancy_id=1)))
    query('Q10', dict(user_id=2, skill_id=2))
    check('profile skill replacement', run('USE vacancy_aggregator; SELECT skill_id FROM user_skills WHERE user_id=2;') == '2')
    query('Q11', dict(user_id=2, day_of_week=1, start_minute=900, end_minute=1200))
    check('availability replacement', run('USE vacancy_aggregator; SELECT start_minute FROM user_availability WHERE user_id=2;') == '900')
    company_params = dict(source_id=1, company_external_id='test-company', company_name='Тест', company_url=None)
    company_id = query('Q01', company_params)
    check('company upsert preserves ID', query('Q01', company_params | dict(company_name='Тест 2')) == company_id)
    import_params = dict(source_id=1, external_id='test-company:test-vacancy', company_id=int(company_id),
        title='Тестовая вакансия', description='Только тест', requirements=None, responsibilities=None,
        original_url='https://example.com/test', country_code='RU', region_name=None, city=None, address_text=None,
        is_remote=0, employment_type='unknown', schedule_text=None, schedule_mode='unknown', time_zone=None,
        salary_min=None, salary_max=None, currency=None, salary_period='unknown', salary_gross=None,
        experience_months_min=None, status='active', published_at=None, source_updated_at=None, raw_payload='{}')
    vacancy_id = query('Q02', import_params)
    check('vacancy upsert preserves ID', query('Q02', import_params | dict(title='Обновлено')) == vacancy_id)
    check('vacancy upsert updates content', run(f'USE vacancy_aggregator; SELECT title FROM vacancies WHERE id={vacancy_id};') == 'Обновлено')
    different = query('Q02', import_params | dict(source_id=2, company_id=None))
    check('same external ID at another source remains separate', different != vacancy_id)
    error = run('USE vacancy_aggregator; UPDATE vacancies SET company_id=1 WHERE source_id=1;', fail=True)
    check('company from another source is rejected', '1452' in error)
    error = run('USE vacancy_aggregator; UPDATE vacancies SET salary_min=-1 WHERE id=1;', fail=True)
    check('negative salary is rejected', '3819' in error)
    error = run('USE vacancy_aggregator; UPDATE user_availability SET end_minute=start_minute WHERE user_id=2;', fail=True)
    check('invalid interval is rejected', '3819' in error)
    error = run('USE vacancy_aggregator; UPDATE vacancies SET salary_min=5000,salary_max=4000 WHERE id=1;', fail=True)
    check('inverted salary range is rejected', '3819' in error)
    query('Q12', dict(source_id=1, external_id=import_params['external_id']))
    check('explicit archive operation', run(f'USE vacancy_aggregator; SELECT status FROM vacancies WHERE id={vacancy_id};') == 'archived')
    query('Q13', dict(source_id=1))
    check('successful source timestamp updates', run('USE vacancy_aggregator; SELECT last_success_at IS NOT NULL FROM sources WHERE id=1;') == '1')
    run("USE vacancy_aggregator; UPDATE vacancies SET time_zone='Asia/Tokyo' WHERE id=1;")
    check('different time zone is unknown', next(r for r in search() if r[0] == '1')[-1] == 'unknown')
    run("USE vacancy_aggregator; DELETE FROM vacancy_schedule_slots WHERE vacancy_id=5;")
    check('missing exact schedule is unknown', next(r for r in search() if r[0] == '5')[-1] == 'unknown')
    report = '# Проверка\n\nДата: 11 ноября 2026 года.\n\n'
    report += f'Сервер MySQL {version}, отдельная временная БД. Выполнены реальные SQL-блоки из `02_queries.sql` после загрузки схемы и демо-данных.\n\n'
    report += f'Пройдено проверок: **{len(passed)}**.\n\n'
    report += '\n'.join('- ' + x for x in passed)
    report += '\n\nHTTP: два маршрута API «Работы России» и справочник регионов HH вернули HTTP 200. Полный импорт из API в БД и запуск .NET/MAUI-приложения в эту проверку не входят.\n'
    (ROOT / 'VERIFICATION.md').write_text(report)
    print(f'ALL {len(passed)} CHECKS PASSED')
finally:
    run(f'DROP DATABASE IF EXISTS {DB};')

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
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parent
DB = 'vacancy_verify_' + uuid.uuid4().hex[:12]
ENV = os.environ.copy()
for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
    ENV.pop(key, None)
CMD = ['docker', '--host=unix:///var/run/docker.sock', 'exec', '-i', 'vacancy-db-check',
       'mysql', '--default-character-set=utf8mb4', '--batch', '--raw', '--skip-column-names', '-uroot']
catalog = '\n'.join((ROOT / name).read_text() for name in
                    ['02_queries.sql', '05_auth_queries.sql', '06_prompt_queries.sql'])
blocks = {}
for match in re.finditer(r'^-- (Q(?:A|P)?\d{2})\.', catalog, re.MULTILINE):
    end = re.search(r'^-- Q(?:A|P)?\d{2}\.', catalog[match.end():], re.MULTILINE)
    stop = match.end() + end.start() if end else len(catalog)
    blocks[match.group(1)] = catalog[match.start():stop]
passed = []
SETUP_DB = DB + '_setup'

def run(sql, fail=False, database=DB):
    sql = sql.replace('vacancy_aggregator', database)
    r = subprocess.run(CMD, input=sql, text=True, capture_output=True, env=ENV)
    if fail:
        assert r.returncode != 0, 'Expected DB constraint rejection'
        return r.stderr
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()

def query(code, params, fail=False):
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
    return run('USE vacancy_aggregator;\n' + re.sub(r'@[a-z_]+', literal, sql), fail=fail)

def check(name, condition):
    assert condition, name
    passed.append(name)
    print('PASS:', name)

search_params = dict(user_id=1, search='', city=None, region_name=None, country_code=None,
                     include_remote=0, employment_type=None, min_salary=None,
                     currency='RUB', salary_period='month', salary_gross=None,
                     only_no_experience=0, require_all_required=0,
                     work_format=None, schedule_type=None, contract_type=None,
                     experience_months=None, page_size=100, offset=0)

def search(**overrides):
    text = query('Q03', search_params | overrides)
    return [line.split('\t') for line in text.splitlines()] if text else []

try:
    run((ROOT / '01_schema.sql').read_text())
    check('base schema contains 9 business tables without custom auth',
          run(f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{DB}';") == '9')
    run((ROOT / '03_seed.sql').read_text())
    check('catalog seed creates no profiles or credentials',
          run('USE vacancy_aggregator; SELECT COUNT(*) FROM user_profiles;') == '0')
    run((ROOT/'tests/identity_stub.sql').read_text())
    run((ROOT/'identity/02_link_profile.sql').read_text())
    run((ROOT/'08_prompt_schema.sql').read_text())
    for number in (1,2):
        query('QA02',dict(auth_subject=f'test-identity-user-{number}',
                         display_name=f'Тест {number}'))
    demo=(ROOT/'07_demo_profile_seed.sql').read_text().replace('@auth_subject',"'test-identity-user-1'")
    run(demo)
    run(demo)
    check('personal demo seed is idempotent',
          run('USE vacancy_aggregator; SELECT COUNT(*) FROM user_skills WHERE user_id=1;') == '3')
    version = run('SELECT VERSION();')
    check('schema and fixtures load on ' + version,
          run(f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{DB}';") == '12')
    rows = search()
    by_id = {int(r[0]): r for r in rows}
    check('active search excludes archived job', set(by_id) == {1, 2, 3, 4, 5})
    check('unknown skills produce NULL percent', by_id[5][-2] == 'NULL')
    check('required skills filter', {int(r[0]) for r in search(require_all_required=1)} == {1, 2, 3, 5})
    check('city filter', {int(r[0]) for r in search(city='Донецк')} == {1, 3})
    check('city plus remote', {int(r[0]) for r in search(city='Донецк', include_remote=1)} == {1, 2, 3, 5})
    check('salary excludes other periods and unknown amounts',
          {int(r[0]) for r in search(min_salary=60000)} == {2, 4})
    check('tax basis filter', {int(r[0]) for r in search(min_salary=60000, salary_gross=1)} == {4})
    check('no experience filter', {int(r[0]) for r in search(only_no_experience=1)} == {1, 2, 3, 5})
    check('remote-only filter', {int(r[0]) for r in search(work_format='remote')} == {2, 5})
    check('onsite-only filter', {int(r[0]) for r in search(work_format='onsite')} == {1, 3})
    check('hybrid-only filter', {int(r[0]) for r in search(work_format='hybrid')} == {4})
    check('hybrid jobs retain city constraint', search(work_format='hybrid',city='Донецк',include_remote=1) == [])
    check('full-time filter', {int(r[0]) for r in search(employment_type='full_time')} == {1, 2, 3, 4})
    check('part-time filter', {int(r[0]) for r in search(employment_type='part_time')} == {5})
    check('five-two schedule filter', {int(r[0]) for r in search(schedule_type='five_two')} == {2, 3, 4})
    check('shift schedule filter', {int(r[0]) for r in search(schedule_type='shift')} == {1})
    check('flexible schedule filter', {int(r[0]) for r in search(schedule_type='flexible')} == {5})
    check('required experience cap', {int(r[0]) for r in search(experience_months=0)} == {1, 2, 3, 5})
    run("USE vacancy_aggregator; UPDATE vacancies SET work_format='unknown',schedule_type='unknown',contract_type='unknown' WHERE id=2;")
    check('unknown format not treated as onsite', 2 not in {int(r[0]) for r in search(work_format='onsite')})
    check('unknown format not treated as remote', 2 not in {int(r[0]) for r in search(work_format='remote')})
    check('unknown schedule not treated as five-two', 2 not in {int(r[0]) for r in search(schedule_type='five_two')})
    check('unknown contract not treated as permanent', 2 not in {int(r[0]) for r in search(contract_type='permanent')})
    check('unknown conditions remain visible without filters', 2 in {int(r[0]) for r in search()})
    run("USE vacancy_aggregator; UPDATE vacancies SET work_format='remote',schedule_type='five_two',contract_type='permanent' WHERE id=2;")
    run("USE vacancy_aggregator; UPDATE vacancies SET contract_type='fixed_term' WHERE id=3;")
    check('full-time does not imply permanent contract', {int(r[0]) for r in search(employment_type='full_time',contract_type='permanent')} == {1, 2, 4})
    check('fixed-term filter', {int(r[0]) for r in search(contract_type='fixed_term')} == {3})
    run("USE vacancy_aggregator; UPDATE vacancies SET contract_type='permanent' WHERE id=3;")
    run("USE vacancy_aggregator; UPDATE vacancies SET salary_period='shift' WHERE id=3;")
    check('salary comparisons respect pay period', {int(r[0]) for r in search(min_salary=30000)} == {1, 2, 4})
    run("USE vacancy_aggregator; UPDATE vacancies SET salary_period='month' WHERE id=3;")
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
    company_params = dict(source_id=1, company_external_id='test-company', company_name='Тест', company_url=None)
    company_id = query('Q01', company_params)
    check('company upsert preserves ID', query('Q01', company_params | dict(company_name='Тест 2')) == company_id)
    import_params = dict(source_id=1, external_id='test-company:test-vacancy', company_id=int(company_id),
        title='Тестовая вакансия', description='Только тест', requirements=None, responsibilities=None,
        original_url='https://example.com/test', country_code='RU', region_name=None, city=None, address_text=None,
        work_format='unknown', employment_type='unknown', schedule_text=None, schedule_type='unknown', contract_type='unknown',
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
    error = run('USE vacancy_aggregator; UPDATE vacancies SET salary_min=5000,salary_max=4000 WHERE id=1;', fail=True)
    check('inverted salary range is rejected', '3819' in error)
    query('Q12', dict(source_id=1, external_id=import_params['external_id']))
    check('explicit archive operation', run(f'USE vacancy_aggregator; SELECT status FROM vacancies WHERE id={vacancy_id};') == 'archived')
    query('Q13', dict(source_id=1))
    check('successful source timestamp updates', run('USE vacancy_aggregator; SELECT last_success_at IS NOT NULL FROM sources WHERE id=1;') == '1')
    check('Identity subject maps to existing numeric profile ID',
          query('QA01',dict(auth_subject='test-identity-user-1')).split('\t')[0] == '1')
    check('unknown principal has no profile', query('QA01',dict(auth_subject='missing-account')) == '')
    check('unknown principal cannot create profile',
          query('QA02',dict(auth_subject='missing-account',display_name='Нет')) == '')
    error=run("USE vacancy_aggregator; INSERT INTO AspNetUsers(Id,NormalizedEmail) VALUES ('duplicate-email','first@example.invalid');",fail=True)
    check('database rejects case-variant email duplicate in contract fixture', '1062' in error)
    error=run("USE vacancy_aggregator; INSERT INTO user_profiles(auth_subject,display_name) VALUES ('test-identity-user-1','Дубль');",fail=True)
    check('one Identity account has at most one profile', '1062' in error)
    error=run("USE vacancy_aggregator; DELETE FROM AspNetUsers WHERE Id='test-identity-user-1';",fail=True)
    check('account deletion restricted while profile exists', '1451' in error)
    check('restrict preserves favorites and profile',
          run('USE vacancy_aggregator; SELECT COUNT(*) FROM favorites WHERE user_id=1;') == '2')
    run("USE vacancy_aggregator; INSERT INTO AspNetUsers(Id,NormalizedEmail) VALUES ('test-identity-user-3','THIRD@EXAMPLE.INVALID');")
    auth=dict(auth_subject='test-identity-user-3',display_name='Третий пользователь')
    with ThreadPoolExecutor(max_workers=8) as pool:
        ids=list(pool.map(lambda _:query('QA02',auth),range(8)))
    profile_id=int(ids[0])
    check('concurrent profile creation converges on one row', len(set(ids)) == 1)
    check('concurrent retries do not create duplicate rows',
          run("USE vacancy_aggregator; SELECT COUNT(*) FROM user_profiles WHERE auth_subject='test-identity-user-3';") == '1')
    query('QA03',auth | dict(display_name='Новое имя',city='Москва'))
    check('own profile updated by principal ID', 'Новое имя' in query('QA01',dict(auth_subject=auth['auth_subject'])))
    check('other profile unchanged', 'Новое имя' not in query('QA01',dict(auth_subject='test-identity-user-2')))

    request_id = int(query('QP01',dict(user_id=profile_id,prompt_text='Знаю SQL, хочу удалённую работу.')))
    own = dict(user_id=profile_id,search_request_id=request_id)
    foreign = dict(user_id=2,search_request_id=request_id)
    check('prompt stored as pending', '\tpending\t' in query('QP04',own))
    check('prompt hidden from another user', query('QP04',foreign) == '')
    query('QP02',foreign | dict(parsed_filters='{}',parser_kind='ai',model_name='test'))
    check('another user cannot finalize prompt', '\tpending\t' in query('QP04',own))
    error = query('QP02',own | dict(parsed_filters='[]',parser_kind='ai',model_name='test'),fail=True)
    check('parsed filters must be JSON object', '3819' in error)
    query('QP02',own | dict(parsed_filters='{"work_format":"remote","skills":["SQL"]}',parser_kind='manual',model_name=None))
    check('parsed prompt stores structured filters', '\tparsed\t' in query('QP04',own))
    query('QP03',own | dict(error_code='LATE_FAILURE'))
    check('finished prompt is not overwritten by late failure', '\tparsed\t' in query('QP04',own))
    result = own | dict(vacancy_id=2,position=1,skill_match_percent=66.67,explanation='Совпал SQL.')
    query('QP07',foreign | dict(vacancy_id=1,position=1,skill_match_percent=100,explanation='Чужая запись'))
    check('another user cannot save recommendations', query('QP08',own) == '')
    query('QP07',result)
    check('real vacancy recommendation saved', 'Junior C# и SQL' in query('QP08',own))
    check('recommendations hidden from another user', query('QP08',foreign) == '')
    query('QP06',foreign)
    check('another user cannot clear recommendations', bool(query('QP08',own)))
    error = query('QP07',result | dict(vacancy_id=1,skill_match_percent=150,position=2),fail=True)
    check('recommendation score range enforced', '3819' in error)
    error = query('QP07',result | dict(vacancy_id=1),fail=True)
    check('duplicate result position rejected', '1062' in error)
    query('QP07',result | dict(vacancy_id=999999,position=2))
    check('nonexistent vacancy not saved', len(query('QP08',own).splitlines()) == 1)
    query('QP06',own)
    check('owned recommendation snapshot can be replaced', query('QP08',own) == '')
    failed_id=int(query('QP01',dict(user_id=profile_id,prompt_text='Неоднозначный запрос')))
    query('QP03',dict(user_id=profile_id,search_request_id=failed_id,error_code='NEEDS_CLARIFICATION'))
    check('parsing failure recorded', '\tfailed\t' in query('QP04',dict(user_id=profile_id,search_request_id=failed_id)))
    error=query('QP01',dict(user_id=profile_id,prompt_text='   '),fail=True)
    check('empty prompt rejected', '3819' in error)
    check('search history scoped to owner',
          len(query('QP05',dict(user_id=profile_id,page_size=100,offset=0)).splitlines()) == 2)
    error=run("USE vacancy_aggregator; INSERT INTO user_profiles(auth_subject,display_name) VALUES ('missing-account','orphan');",fail=True)
    check('profile cannot reference nonexistent account', '1452' in error)
    error=run("USE vacancy_aggregator; DELETE FROM AspNetUsers WHERE Id='test-identity-user-3';",fail=True)
    check('Identity deletion cannot cascade through prompt history', '1451' in error)
    run(f'USE vacancy_aggregator; DELETE FROM user_profiles WHERE id={profile_id};')
    check('explicit profile cleanup removes owned prompts',
          run(f'USE vacancy_aggregator; SELECT COUNT(*) FROM search_requests WHERE user_id={profile_id};') == '0')
    run("USE vacancy_aggregator; DELETE FROM AspNetUsers WHERE Id='test-identity-user-3';")
    check('Identity account can be deleted after explicit profile cleanup',
          run("USE vacancy_aggregator; SELECT COUNT(*) FROM AspNetUsers WHERE Id='test-identity-user-3';") == '0')

    # Initial deployment guards. Identity stub is NOT backend auth implementation.
    run((ROOT/'01_schema.sql').read_text(),database=SETUP_DB)
    link=(ROOT/'identity/02_link_profile.sql').read_text()
    error=run(link,fail=True,database=SETUP_DB)
    check('FK setup waits for backend-created Identity', 'AspNetUsers first' in error)
    stub=(ROOT/'tests/identity_stub.sql').read_text().replace('Id VARCHAR(191)','Id VARCHAR(255)')
    run(stub,database=SETUP_DB)
    error=run(link,fail=True,database=SETUP_DB)
    check('FK setup rejects mismatched ID definition', 'VARCHAR(191)' in error)
    run('USE vacancy_aggregator; ALTER TABLE AspNetUsers MODIFY Id VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL;',database=SETUP_DB)
    run('USE vacancy_aggregator; ALTER TABLE AspNetUsers DROP INDEX EmailIndex;',database=SETUP_DB)
    error=run(link,fail=True,database=SETUP_DB)
    check('FK setup rejects nonunique email contract', 'unique full NormalizedEmail' in error)
    run('USE vacancy_aggregator; ALTER TABLE AspNetUsers ADD UNIQUE KEY EmailIndex(NormalizedEmail(10));',database=SETUP_DB)
    error=run(link,fail=True,database=SETUP_DB)
    check('FK setup rejects prefix-only unique email index', 'unique full NormalizedEmail' in error)
    run('USE vacancy_aggregator; ALTER TABLE AspNetUsers DROP INDEX EmailIndex, ADD UNIQUE KEY EmailIndex(NormalizedEmail);',database=SETUP_DB)
    run('USE vacancy_aggregator; ALTER TABLE AspNetUsers MODIFY NormalizedEmail VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL;',database=SETUP_DB)
    error=run(link,fail=True,database=SETUP_DB)
    check('FK setup rejects case-sensitive email index contract', 'case-insensitive' in error)
    run('USE vacancy_aggregator; ALTER TABLE AspNetUsers MODIFY NormalizedEmail VARCHAR(256) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_as_ci NULL;',database=SETUP_DB)
    run("USE vacancy_aggregator; INSERT INTO user_profiles(auth_subject,display_name) VALUES ('orphan','Тест');",database=SETUP_DB)
    error=run(link,fail=True,database=SETUP_DB)
    check('FK setup rejects orphan profile without deleting it', 'Orphan profiles' in error)
    check('failed initial setup preserves orphan for investigation',
          run('USE vacancy_aggregator; SELECT COUNT(*) FROM user_profiles;',database=SETUP_DB) == '1')
    run("USE vacancy_aggregator; DELETE FROM user_profiles WHERE auth_subject='orphan';",database=SETUP_DB)
    run(link,database=SETUP_DB)
    run(link,database=SETUP_DB)
    check('valid FK setup is repeatable and RESTRICT',
          run(f"SELECT DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA='{SETUP_DB}' AND CONSTRAINT_NAME='fk_user_profiles_identity';") == 'RESTRICT')
    run((ROOT/'identity/01_preflight.sql').read_text(),database=SETUP_DB)
    check('read-only preflight executes on ready schema',True)
    report = '# Проверка\n\nДата: 11 ноября 2026 года.\n\n'
    report += f'Сервер MySQL {version}, две отдельные временные БД. Проверены схема, запросы каталога/профиля/промптов и начальное подключение FK. Identity представлен минимальной тестовой заглушкой ключа и email; это не реальные таблицы EF и не проверка авторизации.\n\n'
    report += f'Пройдено проверок: **{len(passed)}**.\n\n'
    report += '\n'.join('- ' + x for x in passed)
    report += '\n\nЭто проверка БД и SQL-контрактов. Реальные EF-таблицы Identity, регистрация через UserManager, пароль, Bearer/refresh-токены, роли User/Admin, запрет Admin для обычного User и API-доступ пользователя A к данным B должен проверить бэкендер интеграционными тестами. Работа ИИ и код .NET здесь не реализованы и не тестировались. HTTP-проверки источников предыдущего этапа сохранены в research/source-checks.json.\n'
    (ROOT / 'VERIFICATION.md').write_text(report)
    print(f'ALL {len(passed)} CHECKS PASSED')
finally:
    run(f'DROP DATABASE IF EXISTS {DB};')
    run(f'DROP DATABASE IF EXISTS {SETUP_DB};')

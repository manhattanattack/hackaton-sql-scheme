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
catalog = '\n'.join((ROOT / name).read_text() for name in
                    ['02_queries.sql', '05_auth_queries.sql', '06_prompt_queries.sql'])
blocks = {}
for match in re.finditer(r'^-- (Q(?:A|P)?\d{2})\.', catalog, re.MULTILINE):
    end = re.search(r'^-- Q(?:A|P)?\d{2}\.', catalog[match.end():], re.MULTILINE)
    stop = match.end() + end.start() if end else len(catalog)
    blocks[match.group(1)] = catalog[match.start():stop]
passed = []
MIGRATION_DB = DB + '_migration'

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
                     only_no_experience=0, only_schedule_match=0, require_all_required=0,
                     is_remote=None, experience_months=None, page_size=100, offset=0)

def search(**overrides):
    text = query('Q03', search_params | overrides)
    return [line.split('\t') for line in text.splitlines()] if text else []

try:
    run((ROOT / '01_schema.sql').read_text())
    run((ROOT / '03_seed.sql').read_text())
    version = run('SELECT VERSION();')
    check('schema and fixtures load on ' + version,
          run(f"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='{DB}';") == '15')
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
    check('remote-only filter', {int(r[0]) for r in search(is_remote=1)} == {2, 4})
    check('onsite-only filter', {int(r[0]) for r in search(is_remote=0)} == {1, 3, 5})
    check('required experience cap', {int(r[0]) for r in search(experience_months=0)} == {1, 2, 3, 5})
    run('USE vacancy_aggregator; UPDATE vacancies SET is_remote=NULL WHERE id=2;')
    check('unknown work format is not treated as onsite', 2 not in {int(r[0]) for r in search(is_remote=0)})
    check('unknown work format is not treated as remote', 2 not in {int(r[0]) for r in search(is_remote=1)})
    run('USE vacancy_aggregator; UPDATE vacancies SET is_remote=1 WHERE id=2;')
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

    # Account/password VERIFICATION belongs to backend. Dummy hashes below are
    # fixtures for SQL contracts only; no cryptographic authentication is claimed.
    auth = dict(auth_subject='test-auth-account', email='Test@Example.invalid',
                normalized_email='test@example.invalid', password_hash='TEST_ONLY_NOT_A_REAL_HASH',
                display_name='Тестовый пользователь', time_zone='Europe/Moscow')
    profile_id = int(query('QA01', auth))
    check('registration creates linked account and profile',
          run(f"USE vacancy_aggregator; SELECT auth_subject FROM user_profiles WHERE id={profile_id};") == auth['auth_subject'])
    error = query('QA01', auth | dict(auth_subject='duplicate-email-account'), fail=True)
    check('duplicate email rejects registration', '1062' in error)
    check('failed registration leaves no partial account',
          run("USE vacancy_aggregator; SELECT COUNT(*) FROM users WHERE id='duplicate-email-account';") == '0')
    error = run("USE vacancy_aggregator; UPDATE users SET normalized_email='UPPER@example.invalid' WHERE id='test-auth-account';", fail=True)
    check('email normalization enforced', '3819' in error)
    check('login lookup returns hash only to server',
          query('QA02',dict(normalized_email=auth['normalized_email'])).endswith(auth['password_hash']))
    check('blocked demo accounts cannot log in', query('QA02',dict(normalized_email='demo1@example.invalid')) == '')
    token = 'ab' * 32
    session = dict(auth_subject=auth['auth_subject'],token_hash_hex=token,
                   verified_password_hash=auth['password_hash'],expires_at='2099-01-01 00:00:00')
    query('QA03',session)
    check('session resolves authenticated profile',
          str(profile_id) in query('QA04',dict(token_hash_hex=token)).split('\t'))
    check('unknown token cannot authenticate', query('QA04',dict(token_hash_hex='cd'*32)) == '')
    error = query('QA03',session,fail=True)
    check('duplicate token digest rejected', '1062' in error)
    query('QA03',session | dict(token_hash_hex='ee'*32,verified_password_hash='WRONG_HASH'))
    check('password change race prevents session creation', query('QA04',dict(token_hash_hex='ee'*32)) == '')
    query('QA03',session | dict(token_hash_hex='ff'*32,expires_at='2000-01-01 00:00:00'))
    check('expired session creation rejected', query('QA04',dict(token_hash_hex='ff'*32)) == '')
    query('QA03',session | dict(token_hash_hex='short'))
    check('invalid digest cannot create session',
          run("USE vacancy_aggregator; SELECT COUNT(*) FROM auth_sessions WHERE user_subject='test-auth-account';") == '1')
    run("USE vacancy_aggregator; UPDATE users SET status='blocked' WHERE id='test-auth-account';")
    check('blocking account invalidates session lookup', query('QA04',dict(token_hash_hex=token)) == '')
    run("USE vacancy_aggregator; UPDATE users SET status='active' WHERE id='test-auth-account';")
    query('QA05',dict(auth_subject='demo-user-2',token_hash_hex=token))
    check('one account cannot revoke another session', bool(query('QA04',dict(token_hash_hex=token))))
    query('QA05',dict(auth_subject=auth['auth_subject'],token_hash_hex=token))
    check('logout revokes current session', query('QA04',dict(token_hash_hex=token)) == '')
    query('QA03',session | dict(token_hash_hex='12'*32))
    query('QA03',session | dict(token_hash_hex='34'*32))
    query('QA06',dict(auth_subject=auth['auth_subject']))
    check('logout all revokes remaining sessions',
          run("USE vacancy_aggregator; SELECT COUNT(*) FROM auth_sessions WHERE user_subject='test-auth-account' AND revoked_at IS NULL;") == '0')
    run("USE vacancy_aggregator; INSERT INTO auth_sessions (user_subject,token_hash,created_at,expires_at) VALUES ('test-auth-account',UNHEX(REPEAT('56',32)),'2020-01-01','2020-01-02');")
    check('existing expired token cannot authenticate', query('QA04',dict(token_hash_hex='56'*32)) == '')
    query('QA07',dict(auth_subject=auth['auth_subject']))
    check('successful login timestamp', run("USE vacancy_aggregator; SELECT last_login_at IS NOT NULL FROM users WHERE id='test-auth-account';") == '1')

    request_id = int(query('QP01',dict(user_id=profile_id,prompt_text='Знаю SQL, хочу удалённую работу.')))
    own = dict(user_id=profile_id,search_request_id=request_id)
    foreign = dict(user_id=2,search_request_id=request_id)
    check('prompt stored as pending', '\tpending\t' in query('QP04',own))
    check('prompt hidden from another user', query('QP04',foreign) == '')
    query('QP02',foreign | dict(parsed_filters='{}',parser_kind='ai',model_name='test'))
    check('another user cannot finalize prompt', '\tpending\t' in query('QP04',own))
    error = query('QP02',own | dict(parsed_filters='[]',parser_kind='ai',model_name='test'),fail=True)
    check('parsed filters must be JSON object', '3819' in error)
    query('QP02',own | dict(parsed_filters='{"is_remote":true,"skills":["SQL"]}',parser_kind='manual',model_name=None))
    check('parsed prompt stores structured filters', '\tparsed\t' in query('QP04',own))
    query('QP03',own | dict(error_code='LATE_FAILURE'))
    check('finished prompt is not overwritten by late failure', '\tparsed\t' in query('QP04',own))
    result = own | dict(vacancy_id=2,position=1,skill_match_percent=66.67,explanation='Совпал SQL.')
    query('QP07',foreign | dict(vacancy_id=1,position=1,skill_match_percent=100,explanation='Чужая запись'))
    check('another user cannot save recommendations', query('QP08',own) == '')
    query('QP07',result)
    check('real vacancy recommendation saved', 'Стажёр C# и SQL' in query('QP08',own))
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
    run("USE vacancy_aggregator; DELETE FROM users WHERE id='test-auth-account';")
    check('account deletion cascades profile sessions and prompts',
          run(f"USE vacancy_aggregator; SELECT (SELECT COUNT(*) FROM user_profiles WHERE id={profile_id}) + (SELECT COUNT(*) FROM auth_sessions WHERE user_subject='test-auth-account') + (SELECT COUNT(*) FROM search_requests WHERE user_id={profile_id});") == '0')

    # Upgrade the exact previous schema + data, then compare physical schemas.
    run((ROOT/'tests/legacy_schema.sql').read_text(),database=MIGRATION_DB)
    run((ROOT/'tests/legacy_seed.sql').read_text(),database=MIGRATION_DB)
    run((ROOT/'migrations/001_accounts_and_search.sql').read_text(),database=MIGRATION_DB)
    check('upgrade preserves existing vacancies',
          run('USE vacancy_aggregator; SELECT COUNT(*) FROM vacancies;',database=MIGRATION_DB) == '6')
    check('upgrade preserves existing favorites',
          run('USE vacancy_aggregator; SELECT COUNT(*) FROM favorites;',database=MIGRATION_DB) == '2')
    check('upgrade creates blocked legacy accounts without invented passwords',
          run("USE vacancy_aggregator; SELECT COUNT(*) FROM users WHERE status='blocked' AND password_hash='!MIGRATED_NO_PASSWORD_HASH';",database=MIGRATION_DB) == '2')
    tables=run('USE vacancy_aggregator; SHOW TABLES;').splitlines()
    same=True
    for table in tables:
        clean=lambda x: re.sub(r' AUTO_INCREMENT=\d+','',x)
        a=clean(run(f'USE vacancy_aggregator; SHOW CREATE TABLE `{table}`;'))
        b=clean(run(f'USE vacancy_aggregator; SHOW CREATE TABLE `{table}`;',database=MIGRATION_DB))
        if a!=b:
            print('SCHEMA MISMATCH',table)
            same=False
    check('fresh and upgraded table definitions match',same)
    report = '# Проверка\n\nДата: 11 ноября 2026 года.\n\n'
    report += f'Сервер MySQL {version}, две отдельные временные БД. Выполнены реальные SQL-блоки из `02_queries.sql`, `05_auth_queries.sql`, `06_prompt_queries.sql`; проверена миграция старой схемы с данными.\n\n'
    report += f'Пройдено проверок: **{len(passed)}**.\n\n'
    report += '\n'.join('- ' + x for x in passed)
    report += '\n\nЭто проверка БД и SQL-контрактов. Хеширование и проверка паролей, генерация токенов, работа ИИ и код .NET здесь не реализованы и не тестировались. HTTP-проверки источников предыдущего этапа сохранены в research/source-checks.json.\n'
    (ROOT / 'VERIFICATION.md').write_text(report)
    print(f'ALL {len(passed)} CHECKS PASSED')
finally:
    run(f'DROP DATABASE IF EXISTS {DB};')
    run(f'DROP DATABASE IF EXISTS {MIGRATION_DB};')

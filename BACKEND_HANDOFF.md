# СТАРТЕР — handoff бэкендеру (Node.js / Express / mysql2)

Это каноническая часть **БД**, а не готовое Express-приложение. В репозитории есть схема, SQL-каталоги, демо-каталог, диаграммы и интеграционные тесты mysql2. HTTP-ручки, импортёр, JWT, password hasher, Zod, LLM-клиент и клиентское приложение реализует команда бэкенда/фронтенда.

## 1. Принятые решения

- MySQL **8.4**, InnoDB, utf8mb4. Драйвер **mysql2**, ORM не добавляем. Таблиц AspNetUsers/Identity и привязки к EF больше нет.
- БД ещё проектируется: только первоначальное создание, без миграций старых версий.
- Фокус — постоянная работа по навыкам/опыту/условиям. Личного календаря, доступных часов пользователя и сравнения часовых интервалов нет.
- История одна: **recommendation_runs**. Старые search_requests/search_results заменены на runs + кандидаты + направления. Не создавайте вторую параллельную историю.
- Контакты из вакансий не сохраняем: ФИО контактного лица, телефоны, email, contact_list и сырые ответы источника исключаются. Колонки raw_payload больше нет. Email регистрации нашего пользователя относится к авторизации, это отдельные данные.
- ИИ может быть недоступен: каталог и оригинальный текст всегда работают независимо от него.

## 2. Первоначальное создание

1. `01_schema.sql` — 12 таблиц: users, refresh_tokens, user_profiles, sources, companies, vacancies, skills, user_skills, vacancy_skills, favorites, outbound_clicks, import_runs.
2. `08_prompt_schema.sql` — recommendation_runs, recommendation_candidates, recommendation_directions, recommendation_direction_vacancies.
3. `09_ai_schema.sql` — vacancy_ai_summaries (кеш + очередь).
4. Для демонстрации один раз `03_seed.sql`: только вымышленные компании/вакансии/навыки. Реальных аккаунтов/паролей/контактов нет.
5. Создать пользователя через свой регистрационный API, затем при необходимости `07_demo_profile_seed.sql` с его account ID.

Всего **17 таблиц**. `tests/mysql2.mjs` создаёт и удаляет собственную временную БД для проверки. Для теста локально: MySQL на 127.0.0.1:33306, затем `npm ci && npm test`. Настройки тестового подключения берутся из DB_HOST, DB_PORT, DB_USER, DB_PASSWORD. Не направляйте SQL-тесты на рабочую БД.

## 3. Как выполнять SQL через mysql2

SQL-каталоги: `02_queries.sql`, `05_auth_queries.sql`, `06_prompt_queries.sql`, `10_pipeline_queries.sql`. Метки Q03/QA01/QP01/QI01 обозначают операции. В одном блоке иногда несколько команд; выполняйте каждую отдельно и последовательно на **одном соединении**. Схемы выполняются один раз, каталоги запросов целиком не выполняются.

```js
import mysql from 'mysql2/promise';
const pool = mysql.createPool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  namedPlaceholders: true,
  supportBigNumbers: true,
  bigNumberStrings: true,
  dateStrings: true,
  timezone: 'Z',
  multipleStatements: false
});
const conn = await pool.getConnection();
try {
  await conn.query("SET time_zone = '+00:00'");
  // SQL из выбранной операции, параметры через объект:
  // const [rows] = await conn.query(sql, { user_id: profileId, ...filters });
} finally { conn.release(); }
```

Настраивайте UTC для каждого нового соединения. Для транзакции: getConnection → beginTransaction → query по очереди → commit; при любой ошибке rollback; finally release. Не держите транзакцию во время HTTP к источнику или LLM.

- Именованные параметры имеют вид **:user_id**, а не @user_id. Это синтаксис mysql2 с namedPlaceholders=true.
- Передавайте **все** параметры выбранного запроса: отсутствующий фильтр = настоящий JS null, не undefined и не строка "null".
- Объекты/массивы для JSON-колонок и JSON-параметров сначала `JSON.stringify(...)`.
- BIGINT ID отдавайте в API строками и не приводите через Number(id). DECIMAL mysql2 возвращает строками: сохраняйте точность денег при описании OpenAPI.
- `insertId` результата INSERT используйте для новой записи. Для повторного upsert Q01/Q02 возвращается SELECT LAST_INSERT_ID на том же соединении.
- SQL и имена таблиц не принимаются из LLM или пользовательского текста.
- Проверяйте affectedRows там, где требуется ровно одна изменённая строка. Значение 0 не является успешным обновлением чужого/законченного запуска.

## 4. Учётные записи и авторизация

`users.id` — строковый UUID, генерирует backend. `user_profiles.auth_subject` — уникальный FK на users.id с ON DELETE RESTRICT. `user_profiles.id` — внутренний числовой профиль, его используют все бизнес-таблицы как user_id.

Регистрация: валидировать email/пароль → нормализовать email одинаково при регистрации и входе (trim/lowercase) → вычислить salted password hash через выбранный password hasher → BEGIN → QA01 → QA02 → COMMIT. Не передавать пользовательский role в INSERT: QA01 всегда использует default **user**. Дубликат email — конфликт регистрации. Роли: **user/admin**.

Вход: QA04 возвращает хеш только серверу → backend проверяет пароль → генерирует короткоживущий access JWT и случайный refresh token (не менее 256 бит) → QA05 сохраняет SHA-256 **refresh-токена**, а не пароль и не исходный токен. verified_password_hash — реально проверенный хеш из QA04. JWT/пароль не проверяются SQL-запросом.

В JWT sub = users.id. После проверки подписи/срока по QA03 определить profile ID, актуальный status/role/token_version. При проверке token_version запросы блокируются после logout-all/смены credentials. Без такой проверки access JWT живёт до своего срока — нельзя обещать мгновенный logout.

Refresh: BEGIN → QA06 FOR UPDATE по хешу предъявленного токена → если строки нет, rollback/401 → QA07 (1 affected row) → QA05 с новым случайным токеном и хешем → COMMIT. Новый access JWT формируется сервером. Старый refresh повторно не используется. При сбое вся ротация откатывается. Не создавайте новую сессию, если QA06/QA07 не подтвердили старую.

Logout: отозвать refresh через QA07; logout-all/смена credentials — QA08 в одной транзакции. Пароль меняется только после проверки прав/старого пароля; готовый новый хеш обновляет backend в этой же транзакции. Административные операции защищаются Express middleware, MySQL не знает роль HTTP-клиента.

Владельца в Q03–Q10 и QP-операциях берём из серверного QA03. Клиентский userId не даёт доступ к чужим данным. Удаление аккаунта блокируется, пока есть профиль: очистка/сохранение бизнес-данных — отдельный явный сценарий.

## 5. Импорт и нормализация

Первый адаптер — «Работа России», SuperJob после получения ключа. `npm run import:trudvsem` должен появиться **в репозитории backend**: здесь импортёра нет. HTTP-загрузка и проверка status тела выполняются до транзакции записи.

| Вход источника | Каноническая колонка |
|---|---|
| job-name / name | title |
| typicalPosition | typical_position |
| code_profession | code_profession (строка, не терять ведущие нули) |
| category.specialisation | specialisation |
| duty | responsibilities |
| requirements | requirements |
| salary_min/max, currency | salary_min/max, currency; «руб.»/RUR → RUB |
| experience в подтверждённых годах | experience_months_min = years × 12 |
| region.region_code | region_code (канонический региональный код, строка) |
| addresses.address[].lat/lng | latitude/longitude (первая/выбранная точка, при отсутствии NULL) |
| vac_url / alternate_url | original_url |

`description` — нормализованное описание из разрешённых блоков обязанностей/условий/требований. Удалять контактные разделы и в свободном тексте **до записи**, не логировать сырые ответы. SQL не распознаёт ФИО в произвольной прозе: очистку и её тестовые примеры обязан реализовать адаптер. Объекты contact_list/contact_person/company.email не передавать в SQL. Официальное название компании — отдельное поле, контактное лицо не подставлять в него.

Период зарплаты/налоговую базу/стаж не угадывать. Нет подтверждения периода — salary_period=unknown. Ноль стажа означает явное отсутствие требования, NULL — неизвестно. Не превращать все пустые поля источника в 0.

Формат work_format: onsite/remote/hybrid/unknown; employment_type: full_time/part_time/internship/unknown; schedule_type: five_two/six_one/shift/flexible/other/unknown; contract_type: permanent/fixed_term/unknown. Полный день не доказывает график 5/2 и бессрочность договора.

Уникальный ключ вакансии: (source_id, external_id). Для Trudvsem external_id = companycode + ':' + vacancy.id. Компания тоже уникальна в рамках источника. Сопоставление регионов SuperJob/других сайтов делайте с общим кодом, не записывайте их произвольный town ID как region_code.

Перед Q02 внутри короткой транзакции QI14 читает предыдущую запись: это позволяет отличить добавление/обновление для счётчиков и пропустить более старый source_updated_at. Затем Q01 → Q02 → заменить навыки по полному снимку → commit. Для Q01/Q02/связей одно соединение. Не перезаписывайте полное описание поисковым сниппетом.

### Журнал и инкрементальный курсор

1. Сформировать канонический scope JSON (те же отсортированные регионы/фильтры), scope_hash = SHA256 от его стабильной сериализации.
2. QI01 читает последний полностью успешный window_to **для этого источника и scope**.
3. Захватить новый window_to до выгрузки. Для incremental передать modifiedFrom предыдущего курсора (с небольшим перекрытием), modifiedTo нового window_to, если API поддерживает.
4. QI02 создаёт running, уникальность запрещает второй одновременный запуск того же scope.
5. Последовательно получить все страницы/регионы с ретраями, таймаутом и паузами. Для Trudvsem проверить и HTTP, и JSON status. Семантику offset сначала проверить соседними страницами по ID.
6. После завершения QI03 записывает реальные records_seen/inserted/updated/skipped и succeeded. При неполной выгрузке — partial/failed и безопасный error_code, без сырого ответа.
7. Только succeeded продвигает курсор QI01. Q13 отмечает мониторинговое время источника по успешному import_run. После падения процесса зависший running нужно явно закрыть как failed перед новым запуском, убедившись, что старый импортёр остановлен.

Не используйте sources.last_success_at как общий modifiedFrom для разных регионов. Отсутствие вакансии на одной странице или в ограниченной выборке не означает архив: Q12 только по явному подтверждению или отдельно реализованной полной сверке.

## 6. Каталог и поиск

GET /api/vacancies → Q03. API-параметры map: text→search, region→region_code, specialisation→specialisation, salaryFrom→min_salary, noExperience→only_no_experience. Не забыть проверенную пагинацию page_size 1..100 / offset >=0. SQL-таблицы имеют snake_case, API может иметь camelCase по вашему OpenAPI.

Q03 нужно передать полный набор: user_id, search (обычно ''), city, region_name, country_code, region_code, specialisation, typical_positions_json, include_remote, work_format, schedule_type, contract_type, employment_type, min_salary, currency, salary_period, salary_gross, only_no_experience, require_all_required, experience_months, page_size, offset. Не заданные scalar-фильтры → NULL, флаги → 0, пустой массив профессий → NULL. Навыки ранжируют, обязательные навыки исключают кандидатов только при соответствующем флаге.

GET /api/vacancies/:id → Q04 (два SELECT отдельно). original_url хранится из проверенного источника. Для списка профессий перед LLM можно Q14. Каталог и карточку в MVP защищаем авторизацией.

Обычный FULLTEXT работает с кириллицей, но не делает русскую лемматизацию. ngram не включён автоматически: это парсер для символьных n-грамм, основной документированный сценарий CJK; качество русского поиска нужно измерять. Короткие навыки C#/C++ ищутся через справочник навыков. Для MVP достаточно обычного FULLTEXT, нормализованных типовых профессий/специализаций и навыков.

## 7. ИИ-упрощение: кеш и очередь MySQL

Ключ кеша: vacancy_id + provider + model + prompt_version + source_hash. Добавлен provider, потому что одинаковое имя модели может встречаться у разных провайдеров. source_hash генерирует MySQL из нормализованных полей, используемых для упрощения. Повторный poll того же содержимого сохраняет хеш. Изменение текста/условий меняет его.

Результат хранится в result_json:

```json
{"simpleTitle":"Продавец","whatYouDo":["Помогать покупателям"],"requirements":["Общение с клиентами"],"conditions":["Полный день"],"beginnerFriendly":true}
```

Zod проверяет полный формат/типы/элементы массивов и допустимую длину **до** QI09. SQL дополнительно проверяет объект, обязательные ключи и основные типы. В result_json не сохраняется сырой ответ провайдера, HTML или секреты.

1. QI05 ставит актуальную версию в pending идемпотентно.
2. На отдельном соединении BEGIN → QI06 FOR UPDATE SKIP LOCKED → если нет задания, rollback/выход → QI07 с новым случайным lease_token_hex (32 hex-символа) и lease_seconds 1..3600 → commit.
3. QI08 получает исходные поля только при совпадении с текущим content_hash. Нет строки — старое задание завершить ошибкой SOURCE_CHANGED, поставить текущую версию QI05.
4. Выполнить LLM вызов вне транзакции; ограничить параллельность и таймаут по провайдеру.
5. Валидный JSON → QI09. Ошибка → QI10 с безопасным error_code.
6. Периодически QI11 восстанавливает просроченные lease, с пределом attempts; QI12 делает ограниченный retry transient-ошибок с задержкой.
7. QI13 читает только done той же текущей версии. Нет результата/ИИ недоступен — UI получает оригинальный текст вакансии.

Поздний воркер не завершит чужую попытку: QI09/QI10 проверяют lease-token и срок. Старый кеш не возвращается для изменённой вакансии. Не держать транзакцию открытой во время LLM. Для первой демонстрации можно один воркер, Redis не нужен.

## 8. Рекомендации направлений

POST /api/recommendations принимает один prompt. LLM-extraction выдаёт JSON: skills, interests, education, experience_months и обычные фильтры условий/региона из JSON_CONTRACT.md. Неизвестное → NULL, а не выдуманный факт. Zod проверяет объект.

Последовательность:

1. QP01 сохраняет рассказ, insertId = run_id.
2. LLM-разбор вне транзакции; QP02 записывает parsed_profile и parsed. Ошибка — QP09.
3. BEGIN → заблокировать свой user_profiles FOR UPDATE → полностью заменить user_skills через SQL Q10 без его вложенных START/COMMIT → QP03 (1 affected row) → Q03 с page_size <=50 → сохранить каждую реальную вакансию QP04 → commit.
4. QP05 читает сохранённые кандидаты; передать их и исходные условия одним запросом LLM. Типовые позиции получать из Q14/каталога, не выдумывать жёсткие фильтры, отсутствующие в данных.
5. Ответ: до 5 направлений с title, whySuitable и массивом candidate vacancy IDs. Обычно 3–5, но при малой/пустой выдаче не выдумывать недостающие направления. Zod проверяет ссылки по whitelist кандидатов.
6. BEGIN → заблокировать принадлежащий пользователю recommendation_runs FOR UPDATE → QP06/QP07 для направлений/ссылок → QP08 → commit. При ошибке rollback и QP09. Ноль кандидатов может завершиться с result_note и без направлений.
7. QP10 — моя история, QP11 — моя сгруппированная подборка. Чужие run ID не дают доступа к данным.

FK в recommendation_direction_vacancies дополнительно запрещает ссылку вне кандидатов того же run. source_unchanged показывает, совпадает ли текущая карточка с версией на момент подбора. Не обещать, что условия старой подборки всегда актуальны.

Суммарное объяснение LLM не заменяет реальные зарплаты/требования. После извлечения пользователь может искать без части условий; SQL уже поддерживает NULL-фильтры. Формат VECTOR/эмбеддинги не добавлялись: для хакатона достаточно SQL-кандидатов + LLM.

## 9. Переход к работодателю и клиент

Q08 записывает переход и возвращает original_url, Q09 читает мою историю. Для MAUI с JWT удобнее авторизованный **POST /api/vacancies/:id/go → JSON с originalUrl**, затем системный браузер открывает оригинал. При GET→302 HttpClient может автоматически пройти редирект и получить HTML, а системный браузер не добавит ваш Bearer автоматически. Согласуйте контракт до генерации C#-клиента. GET также может вызываться предварительной загрузкой, поэтому его счётчик — приблизительная метрика переходов.

OpenAPI должен описывать строковые ID, nullable-поля и реальные JSON-форматы. C#-клиент генерируется из него в репозитории приложения. БД хранит переход, а не доказанный отклик работодателю.

## 10. Что изменилось относительно предыдущей ASP.NET-версии

- AspNetUsers/Identity и каталог identity/ удалены. users + refresh_tokens создаются нашей схемой, связь профиля теперь на users.id.
- SQL использует :name и mysql2; роль user/admin. Никаких EF-таблиц.
- Добавлены поля профессии/региона/координат и вычисляемый content_hash. experience_months_min и responsibilities сохранены как канонические имена вместо дублирования experience_years/duty.
- raw_payload удалён, импортируются только очищенные разрешённые поля.
- search_requests/search_results заменены одной историей recommendation_runs с кандидатами и направлениями.
- Добавлены import_runs и vacancy_ai_summaries. Личного расписания/миграций старой БД по-прежнему нет.

## 11. Приёмка backend

Проверить реальные password hashing/JWT/refresh rotation/роли; импорт соседних страниц/инкрементальный scope/контакты; Zod + ограниченные ретраи; LLM fallback; чужие profile/run ID; MAX кандидатов и whitelist; корректность OpenAPI/MAUI перехода. SQL-проверки: `npm test`, список в VERIFICATION.md. Backend unit/integration — Vitest + Supertest, QA может проверять HTTP снаружи pytest. Эти инструменты не заменяют друг друга.

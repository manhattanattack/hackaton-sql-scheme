# Проверка

Дата: 11 ноября 2026 года.

Сервер MySQL 8.4.13, две отдельные временные БД. Проверены схема, запросы каталога/профиля/промптов и начальное подключение FK. Identity представлен минимальной тестовой заглушкой ключа и email; это не реальные таблицы EF и не проверка авторизации.

Пройдено проверок: **86**.

- base schema contains 11 business tables without custom auth
- catalog seed creates no profiles or credentials
- personal demo seed is idempotent
- schema and fixtures load on 8.4.13
- active search excludes archived job
- fixed required intervals fit availability
- daytime shift conflicts
- flexible schedule is unknown, not automatically compatible
- unknown skills produce NULL percent
- strict schedule filter
- required skills filter
- city filter
- city plus remote
- salary excludes other periods and unknown amounts
- tax basis filter
- no experience filter
- remote-only filter
- onsite-only filter
- required experience cap
- unknown work format is not treated as onsite
- unknown work format is not treated as remote
- Cyrillic fulltext search
- pagination returns distinct pages
- favorites idempotent
- one user cannot remove another users favorite
- archived job remains in favorites
- outbound click returns original URL
- repeated clicks retained
- archived job cannot be clicked as active
- history isolated by user
- vacancy card returns main and skill resultsets
- profile skill replacement
- availability replacement
- company upsert preserves ID
- vacancy upsert preserves ID
- vacancy upsert updates content
- same external ID at another source remains separate
- company from another source is rejected
- negative salary is rejected
- invalid interval is rejected
- inverted salary range is rejected
- explicit archive operation
- successful source timestamp updates
- different time zone is unknown
- missing exact schedule is unknown
- Identity subject maps to existing numeric profile ID
- unknown principal has no profile
- unknown principal cannot create profile
- database rejects case-variant email duplicate in contract fixture
- one Identity account has at most one profile
- account deletion restricted while profile exists
- restrict preserves favorites and profile
- concurrent profile creation converges on one row
- concurrent retries do not create duplicate rows
- own profile updated by principal ID
- other profile unchanged
- prompt stored as pending
- prompt hidden from another user
- another user cannot finalize prompt
- parsed filters must be JSON object
- parsed prompt stores structured filters
- finished prompt is not overwritten by late failure
- another user cannot save recommendations
- real vacancy recommendation saved
- recommendations hidden from another user
- another user cannot clear recommendations
- recommendation score range enforced
- duplicate result position rejected
- nonexistent vacancy not saved
- owned recommendation snapshot can be replaced
- parsing failure recorded
- empty prompt rejected
- search history scoped to owner
- profile cannot reference nonexistent account
- Identity deletion cannot cascade through prompt history
- explicit profile cleanup removes owned prompts
- Identity account can be deleted after explicit profile cleanup
- FK setup waits for backend-created Identity
- FK setup rejects mismatched ID definition
- FK setup rejects nonunique email contract
- FK setup rejects prefix-only unique email index
- FK setup rejects case-sensitive email index contract
- FK setup rejects orphan profile without deleting it
- failed initial setup preserves orphan for investigation
- valid FK setup is repeatable and RESTRICT
- read-only preflight executes on ready schema

Это проверка БД и SQL-контрактов. Реальные EF-таблицы Identity, регистрация через UserManager, пароль, Bearer/refresh-токены, роли User/Admin, запрет Admin для обычного User и API-доступ пользователя A к данным B должен проверить бэкендер интеграционными тестами. Работа ИИ и код .NET здесь не реализованы и не тестировались. HTTP-проверки источников предыдущего этапа сохранены в research/source-checks.json.

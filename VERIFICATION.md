# Проверка

Дата: 11 ноября 2026 года.

Сервер MySQL 8.4.13, две отдельные временные БД. Выполнены реальные SQL-блоки из `02_queries.sql`, `05_auth_queries.sql`, `06_prompt_queries.sql`; проверена миграция старой схемы с данными.

Пройдено проверок: **83**.

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
- registration creates linked account and profile
- duplicate email rejects registration
- failed registration leaves no partial account
- email normalization enforced
- login lookup returns hash only to server
- blocked demo accounts cannot log in
- session resolves authenticated profile
- unknown token cannot authenticate
- duplicate token digest rejected
- password change race prevents session creation
- expired session creation rejected
- invalid digest cannot create session
- blocking account invalidates session lookup
- one account cannot revoke another session
- logout revokes current session
- logout all revokes remaining sessions
- existing expired token cannot authenticate
- successful login timestamp
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
- account deletion cascades profile sessions and prompts
- upgrade preserves existing vacancies
- upgrade preserves existing favorites
- upgrade creates blocked legacy accounts without invented passwords
- fresh and upgraded table definitions match

Это проверка БД и SQL-контрактов. Хеширование и проверка паролей, генерация токенов, работа ИИ и код .NET здесь не реализованы и не тестировались. HTTP-проверки источников предыдущего этапа сохранены в research/source-checks.json.

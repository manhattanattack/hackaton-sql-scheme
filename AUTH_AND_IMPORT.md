# Авторизация и импорт — актуальная точка входа

Стек изменён на Node.js/Express + mysql2. Старая инструкция ASP.NET Identity заменена.

Полная инструкция: **[BACKEND_HANDOFF.md](BACKEND_HANDOFF.md)**.

- Авторизация: users + refresh_tokens; users.id → user_profiles.auth_subject, с RESTRICT.
- Учётные записи/роли создаёт ваш Express API; SQL хранит готовые хеши, backend проверяет пароль/JWT.
- Импорт: адаптер приводит данные к очищенному каноническому формату; Q01/Q02 сохраняют их без дублей.
- Журнал import_runs и QI01 учитывают отдельный инкрементальный курсор для каждого source/scope.
- ИИ-кеш и очередь: vacancy_ai_summaries; направления и история: recommendation_runs.
- SQL-параметры :name, драйвер mysql2, ORM не требуется. Схема создаётся с нуля, миграций нет.

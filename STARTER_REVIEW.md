# Актуализация прежних правок

Файл STARTER_DB_CHANGES.md относился к ASP.NET Core Identity. После решения команды перейти на Node.js/Express эти требования заменены нейтральной схемой users/refresh_tokens.

Текущие решения и handoff: [PLAN_REVIEW.md](PLAN_REVIEW.md), [BACKEND_HANDOFF.md](BACKEND_HANDOFF.md).

Сохраняются прежние согласованные принципы: BIGINT профиль и бизнес-связи, RESTRICT при удалении аккаунта, отсутствие миграций существующей БД и личного календаря, права пользователя/администратора на уровне backend. Конкретные таблицы AspNetUsers, EF, Bearer Identity и скрипты identity/ удалены.

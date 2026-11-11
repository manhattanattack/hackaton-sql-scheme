# Разбор плана команды и решения БД

План «данные → ИИ-упрощение → рекомендации → клиент/демо» подходит. Изменения внесены только в каноническую БД; реализацию HTTP/LLM/импорта выполняет backend.

| Предложение | Решение |
|---|---|
| Node/Express/mysql2 | Убрана зависимость от ASP.NET Identity, добавлены нейтральные users/refresh_tokens, SQL :name |
| Поля профессии/региона/географии | Добавлены typical_position/code_profession/specialisation/region_code/latitude/longitude |
| experience_years/duty | Сохранены канонические experience_months_min/responsibilities, преобразование делает адаптер |
| Контакты не сохранять | Нет контактных колонок/raw_payload; очистка текста до записи — обязанность адаптера |
| Upsert | Сохранён уникальный source_id + external_id |
| Журнал импорта | import_runs с per-source/per-scope курсором, только succeeded продвигает watermark |
| modifiedFrom | Использовать с фиксированным modifiedTo и перекрытием, не продвигать после partial |
| ngram для русского | Не включён вслепую: документированный основной сценарий CJK, автоматической русской морфологии он не даёт |
| Кеш ИИ | vacancy_ai_summaries с provider/model/prompt_version/source_hash; хеш генерирует БД |
| Очередь MySQL | Pending/processing/done/failed, FOR UPDATE SKIP LOCKED, временный lease и fencing-token |
| История рекомендаций | Единые recommendation_runs вместо дублирования старой search_requests; top-50 кандидатов и направления |
| Проверка LLM-ссылок | Составные FK разрешают только кандидатов того же запуска |
| VECTOR | Не добавляли, для MVP достаточно SQL-кандидатов + LLM |
| GET go → 302 | Для MAUI/JWT удобнее POST → originalUrl → системный браузер; контракт согласовать до генерации C# |
| Vitest/Supertest и pytest | Разные уровни проверки, правило зафиксировано в AGENTS.md |

## Поправки к техническим утверждениям

- MySQL ngram создавался прежде всего для CJK и режет текст на символьные n-граммы. Обычный FULLTEXT понимает кириллицу, но не русскую морфологию. Для MVP оставлен FULLTEXT + словарь навыков/профессий. [MySQL 8.4](https://dev.mysql.com/doc/refman/8.4/en/fulltext-search-ngram.html).
- У GigaChat есть **частичная совместимость** с OpenAI SDK и официальный пример. Поэтому «вообще несовместим» — слишком категорично. Требуются учёт ограничений и обновление access-token; gpt2giga остаётся возможным прокси. Не обещать переключение любого провайдера только двумя env без проверки формата/авторизации. [Документация GigaChat](https://developers.sber.ru/docs/ru/gigachat/guides/compatible-openai).
- Для разных регионов нельзя брать один общий last_success_at как cursor. Сохраняем scope/hash и полностью успешное окно, чтобы не пропустить обновления.
- Сама очередь не спасает от погибшего воркера: нужны lease/recovery. Они включены в SQL; лимит параллельности конкретного провайдера задаётся backend.
- Сырые API-ответы часто содержат контакты: удалена колонка raw_payload, обязательна allowlist-нормализация до SQL.

Точка входа бэкендера: BACKEND_HANDOFF.md. Предыдущая ASP.NET-инструкция больше не актуальна.

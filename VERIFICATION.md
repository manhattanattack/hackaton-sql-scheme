# Проверка

Дата: 11 ноября 2026 года.

Сервер MySQL 8.4.13, отдельная временная БД. Выполнены реальные SQL-блоки из `02_queries.sql` после загрузки схемы и демо-данных.

Пройдено проверок: **37**.

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

HTTP: два маршрута API «Работы России» и справочник регионов HH вернули HTTP 200. Полный импорт из API в БД и запуск .NET/MAUI-приложения в эту проверку не входят.

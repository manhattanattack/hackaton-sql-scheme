-- CATALOG DEMO ONLY: no accounts, profiles, password hashes or tokens.
-- Create demo accounts through backend registration API; see 07_demo_profile_seed.sql.
-- Run once on a fresh schema after 01_schema.sql; not a production migration.
USE vacancy_aggregator;
SET time_zone = '+00:00';

INSERT INTO sources (id, code, name, base_url, access_type, is_enabled) VALUES
  (1,'trudvsem','Работа России','https://trudvsem.ru','api',TRUE),
  (2,'hh','HeadHunter','https://hh.ru','api',FALSE),
  (3,'demo','ДЕМО — вымышленные объявления','https://example.com','manual',TRUE);

INSERT INTO companies (id, source_id, external_id, name) VALUES
  (1,3,'demo-shop','ДЕМО: Магазин'),
  (2,3,'demo-it','ДЕМО: IT-студия');

INSERT INTO skills (id,name,normalized_name) VALUES
  (1,'C#','c#'),(2,'SQL','sql'),(3,'Общение с клиентами','общение с клиентами'),
  (4,'Python','python'),(5,'Blazor','blazor');
INSERT INTO vacancies (
 id,source_id,external_id,company_id,title,description,requirements,responsibilities,
 original_url,country_code,region_name,city,work_format,employment_type,schedule_text,
 schedule_type,contract_type,salary_min,salary_max,currency,salary_period,salary_gross,
 experience_months_min,status,published_at
) VALUES
 (1,3,'demo-v1',1,'ДЕМО: Продавец-консультант',
  'Постоянная работа в магазине. Учебное объявление.',
  'Общение с клиентами. Опыт не требуется.','Помогать покупателям, выкладывать товары.',
  'https://example.com/demo/v1','RU','Донецкая Народная Республика','Донецк','onsite','full_time',
  'Полный день, сменный график.','shift','permanent',35000,45000,'RUB','month',0,0,'active','2026-11-11 08:00:00'),
 (2,3,'demo-v2',2,'ДЕМО: Junior C# и SQL разработчик',
  'Постоянная удалённая работа с C# и SQL. Учебное объявление.',
  'Базовые C# и SQL. Blazor желателен.','Писать запросы и обработчики API.',
  'https://example.com/demo/v2','RU','Ростовская область','Ростов-на-Дону','remote','full_time',
  'Полный день, 5/2.','five_two','permanent',60000,80000,'RUB','month',0,0,'active','2026-11-11 08:10:00'),
 (3,3,'demo-v3',1,'ДЕМО: Кассир',
  'Постоянная работа в магазине. Учебное объявление.',
  'Общение с клиентами.','Работа на кассе.',
  'https://example.com/demo/v3','RU','Донецкая Народная Республика','Донецк','onsite','full_time',
  'Полный день, 5/2.','five_two','permanent',40000,50000,'RUB','month',0,0,'active','2026-11-11 08:20:00'),
 (4,3,'demo-v4',2,'ДЕМО: Python-разработчик',
  'Постоянная разработка на Python. Учебное объявление.',
  'Python и SQL, опыт от года.','Разрабатывать сервисы.',
  'https://example.com/demo/v4','RU','Москва','Москва','hybrid','full_time',
  'Гибрид, 5/2.','five_two','permanent',70000,100000,'RUB','month',1,12,'active','2026-11-11 08:30:00'),
 (5,3,'demo-v5',1,'ДЕМО: Специалист поддержки',
  'Постоянная удалённая поддержка. Учебное объявление.',
  NULL,'Отвечать на обращения клиентов.',
  'https://example.com/demo/v5','RU','Ростовская область','Ростов-на-Дону','remote','part_time',
  'Неполный день, гибкий график.','flexible','permanent',NULL,NULL,NULL,'unknown',NULL,0,'active','2026-11-11 08:40:00'),
 (6,3,'demo-v6',1,'ДЕМО: Архивная вакансия',
  'Закрытая вакансия для проверки истории. Учебное объявление.',
  NULL,NULL,'https://example.com/demo/v6','RU','Москва','Москва','onsite','full_time',
  '5/2.','five_two','permanent',NULL,NULL,NULL,'unknown',NULL,NULL,'archived','2026-11-10 08:00:00');

INSERT INTO vacancy_skills (vacancy_id,skill_id,is_required) VALUES
  (1,3,1),(2,1,1),(2,2,1),(2,5,0),(3,3,1),(4,4,1),(4,2,1);

UPDATE vacancies SET typical_position='Продавец-консультант',code_profession='17351',
 specialisation='Продажи',region_code='9300000000000',latitude=48.0159,longitude=37.8029 WHERE id=1;
UPDATE vacancies SET typical_position='Программист',specialisation='Информационные технологии',
 region_code='6100000000000' WHERE id=2;
UPDATE vacancies SET typical_position='Кассир',specialisation='Продажи',region_code='9300000000000' WHERE id=3;
UPDATE vacancies SET typical_position='Программист',specialisation='Информационные технологии',region_code='7700000000000' WHERE id=4;
UPDATE vacancies SET typical_position='Специалист поддержки',specialisation='Поддержка клиентов',region_code='6100000000000' WHERE id=5;

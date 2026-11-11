-- DEMONSTRATION DATA ONLY. No real employers, jobs, users or application links.
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

-- Deliberately blocked: these placeholders are NOT usable login credentials.
INSERT INTO users (id,email,normalized_email,password_hash,status) VALUES
  ('demo-user-1','demo1@example.invalid','demo1@example.invalid','!DEMO_NO_PASSWORD_HASH','blocked'),
  ('demo-user-2','demo2@example.invalid','demo2@example.invalid','!DEMO_NO_PASSWORD_HASH','blocked');

INSERT INTO user_profiles (id,auth_subject,display_name,city,time_zone) VALUES
  (1,'demo-user-1','Демо-студент','Донецк','Europe/Moscow'),
  (2,'demo-user-2','Другой демо-пользователь','Ростов-на-Дону','Europe/Moscow');

INSERT INTO skills (id,name,normalized_name) VALUES
  (1,'C#','c#'),(2,'SQL','sql'),(3,'Общение с клиентами','общение с клиентами'),
  (4,'Python','python'),(5,'Blazor','blazor');
INSERT INTO user_skills (user_id,skill_id) VALUES (1,1),(1,2),(1,3);
INSERT INTO user_availability (user_id,day_of_week,start_minute,end_minute) VALUES
  (1,1,960,1320),(1,3,960,1320),(1,6,540,1080);

INSERT INTO vacancies (
 id,source_id,external_id,company_id,title,description,requirements,responsibilities,
 original_url,country_code,region_name,city,is_remote,employment_type,schedule_text,
 schedule_mode,time_zone,salary_min,salary_max,currency,salary_period,salary_gross,
 experience_months_min,status,published_at
) VALUES
 (1,3,'demo-v1',1,'ДЕМО: Помощник продавца',
  'Подработка в магазине после занятий. Учебное объявление.',
  'Общение с клиентами. Опыт не требуется.','Помогать покупателям, выкладывать товары.',
  'https://example.com/demo/v1','RU','Донецкая Народная Республика','Донецк',0,'part_time',
  'Понедельник и среда, 17:00–21:00.','fixed_weekly','Europe/Moscow',1500,2000,'RUB','shift',0,0,'active','2026-11-11 08:00:00'),
 (2,3,'demo-v2',2,'ДЕМО: Стажёр C# и SQL',
  'Удалённая стажировка по C# и SQL. Учебное объявление.',
  'Базовые C# и SQL.','Писать запросы и простые обработчики API.',
  'https://example.com/demo/v2','RU','Ростовская область','Ростов-на-Дону',1,'internship',
  'Гибкое время, точные часы согласуются.','flexible','Europe/Moscow',25000,35000,'RUB','month',1,0,'active','2026-11-11 08:10:00'),
 (3,3,'demo-v3',1,'ДЕМО: Кассир днём',
  'Дневная смена в магазине. Учебное объявление.',
  'Общение с клиентами.','Работа на кассе.',
  'https://example.com/demo/v3','RU','Донецкая Народная Республика','Донецк',0,'part_time',
  'Понедельник, 09:00–15:00.','fixed_weekly','Europe/Moscow',1700,2100,'RUB','shift',0,0,'active','2026-11-11 08:20:00'),
 (4,3,'demo-v4',2,'ДЕМО: Python-разработчик',
  'Разработка на Python. Учебное объявление.',
  'Python и SQL, опыт от года.','Разрабатывать сервисы.',
  'https://example.com/demo/v4','RU','Москва','Москва',1,'full_time',
  'График уточняется.','unknown',NULL,70000,100000,'RUB','month',1,12,'active','2026-11-11 08:30:00'),
 (5,3,'demo-v5',1,'ДЕМО: Сезонный помощник',
  'Сезонная работа по субботам. Учебное объявление.',
  NULL,'Помощь на складе.',
  'https://example.com/demo/v5','RU','Ростовская область','Ростов-на-Дону',0,'seasonal',
  'Суббота, 10:00–16:00.','fixed_weekly','Europe/Moscow',NULL,NULL,NULL,'unknown',NULL,0,'active','2026-11-11 08:40:00'),
 (6,3,'demo-v6',1,'ДЕМО: Архивная вакансия',
  'Закрытая вакансия для проверки истории. Учебное объявление.',
  NULL,NULL,'https://example.com/demo/v6','RU','Москва','Москва',0,'temporary',
  NULL,'unknown',NULL,NULL,NULL,NULL,'unknown',NULL,NULL,'archived','2026-11-10 08:00:00');

INSERT INTO vacancy_skills (vacancy_id,skill_id,is_required) VALUES
  (1,3,1),(2,1,1),(2,2,1),(2,5,0),(3,3,1),(4,4,1),(4,2,1);
INSERT INTO vacancy_schedule_slots (vacancy_id,day_of_week,start_minute,end_minute) VALUES
  (1,1,1020,1260),(1,3,1020,1260),(3,1,540,900),(5,6,600,960);
INSERT INTO favorites (user_id,vacancy_id) VALUES (1,2),(1,6);

INSERT INTO search_requests (id,user_id,prompt_text,parsed_filters,status,parser_kind,parsed_at) VALUES
  (1,1,'Знаю C# и SQL. Ищу удалённую стажировку без опыта от 25000 рублей в месяц.',
   '{"skills":["C#","SQL"],"is_remote":true,"employment_type":"internship","min_salary":25000,"currency":"RUB","salary_period":"month","experience_months":0}',
   'parsed','manual',UTC_TIMESTAMP(6));
INSERT INTO search_results (search_request_id,vacancy_id,position,skill_match_percent,explanation) VALUES
  (1,2,1,66.67,'Совпали C# и SQL, Blazor не указан. Удалённая стажировка; точные часы нужно уточнить.');

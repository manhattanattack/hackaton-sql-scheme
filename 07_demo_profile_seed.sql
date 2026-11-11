-- OPTIONAL personal demo data, AFTER Identity account + QA02 profile exist.
-- Bind @auth_subject to a real demo account ID returned by UserManager/API.
-- No account, password hash, security stamp or token is inserted here.
-- Repeat calls are idempotent; no account/profile found => no data inserted.
USE vacancy_aggregator;
INSERT INTO user_skills (user_id,skill_id)
SELECT p.id,s.id FROM user_profiles p JOIN AspNetUsers u ON u.Id=p.auth_subject
JOIN skills s ON s.normalized_name IN ('c#','sql','общение с клиентами')
WHERE p.auth_subject=@auth_subject
ON DUPLICATE KEY UPDATE skill_id=user_skills.skill_id;

INSERT INTO user_availability (user_id,day_of_week,start_minute,end_minute)
SELECT p.id,t.day_of_week,t.start_minute,t.end_minute
FROM user_profiles p JOIN AspNetUsers u ON u.Id=p.auth_subject
JOIN (
  SELECT 1 AS day_of_week,960 AS start_minute,1320 AS end_minute
  UNION ALL SELECT 3,960,1320
  UNION ALL SELECT 6,540,1080
) t
WHERE p.auth_subject=@auth_subject
ON DUPLICATE KEY UPDATE id=user_availability.id;

INSERT INTO favorites (user_id,vacancy_id)
SELECT p.id,v.id FROM user_profiles p JOIN AspNetUsers u ON u.Id=p.auth_subject
JOIN vacancies v JOIN sources s ON s.id=v.source_id
WHERE p.auth_subject=@auth_subject AND s.code='demo' AND v.external_id IN ('demo-v2','demo-v6')
ON DUPLICATE KEY UPDATE created_at=favorites.created_at;

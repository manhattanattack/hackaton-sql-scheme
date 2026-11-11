-- One canonical recommendation history. Bind owner from verified backend account.
USE vacancy_aggregator;

-- QP01. Save original prompt. Use insertId from mysql2 result.
INSERT INTO recommendation_runs(user_id,prompt_text) VALUES (:user_id,:prompt_text);

-- QP02. Save validated LLM extraction; all optional filters remain nullable.
UPDATE recommendation_runs SET parsed_profile=:parsed_profile,status='parsed',
 parser_model=:parser_model,parsed_at=UTC_TIMESTAMP(6)
WHERE id=:run_id AND user_id=:user_id AND status='pending';

-- QP03. Claim parsed run, then snapshot SQL candidates with QP04 (same short transaction).
UPDATE recommendation_runs SET status='processing',recommendation_model=:recommendation_model,
 prompt_version=:prompt_version WHERE id=:run_id AND user_id=:user_id AND status='parsed';

-- QP04. Save one actual SQL candidate; repeat for top <=50. Backend requires affectedRows=1.
INSERT INTO recommendation_candidates(run_id,vacancy_id,position,source_hash,skill_match_percent)
SELECT q.id,v.id,:position,v.content_hash,:skill_match_percent
FROM recommendation_runs q JOIN vacancies v ON v.id=:vacancy_id AND v.status='active'
WHERE q.id=:run_id AND q.user_id=:user_id AND q.status='processing';

-- QP05. Candidate cards for the grouping LLM; no external invented vacancy IDs allowed.
SELECT c.vacancy_id,c.position,c.skill_match_percent,v.title,v.typical_position,
 v.specialisation,v.description,v.requirements,v.responsibilities,v.original_url,
 (c.source_hash=v.content_hash) AS source_unchanged
FROM recommendation_candidates c JOIN recommendation_runs q ON q.id=c.run_id
JOIN vacancies v ON v.id=c.vacancy_id WHERE q.id=:run_id AND q.user_id=:user_id
ORDER BY c.position;

-- QP06. Persist one validated direction; insertId is direction_id. Repeat up to 5.
-- Save all directions, links and completion in ONE transaction; rollback on validation/SQL failure.
INSERT INTO recommendation_directions(run_id,position,title,why_suitable)
SELECT id,:position,:title,:why_suitable FROM recommendation_runs
WHERE id=:run_id AND user_id=:user_id AND status='processing';

-- QP07. Link ONLY a candidate of the SAME run. Composite FKs enforce this too.
INSERT INTO recommendation_direction_vacancies(run_id,direction_id,vacancy_id,position)
SELECT q.id,d.id,c.vacancy_id,:position FROM recommendation_runs q
JOIN recommendation_directions d ON d.run_id=q.id AND d.id=:direction_id
JOIN recommendation_candidates c ON c.run_id=q.id AND c.vacancy_id=:vacancy_id
WHERE q.id=:run_id AND q.user_id=:user_id AND q.status='processing';

-- QP08. Finish valid grouping (zero candidates may finish with result_note instead).
UPDATE recommendation_runs SET status='done',completed_at=UTC_TIMESTAMP(6),result_note=:result_note
WHERE id=:run_id AND user_id=:user_id AND status='processing';

-- QP09. Safe failure code, never raw provider text/credentials/contacts.
UPDATE recommendation_runs SET status='failed',error_code=:error_code,completed_at=UTC_TIMESTAMP(6)
WHERE id=:run_id AND user_id=:user_id AND status IN ('pending','parsed','processing');

-- QP10. My runs, including original prompt and parsed profile.
SELECT id,prompt_text,parsed_profile,status,result_note,error_code,created_at,completed_at
FROM recommendation_runs WHERE user_id=:user_id ORDER BY created_at DESC,id DESC
LIMIT :page_size OFFSET :offset;

-- QP11. My grouped results; foreign run owners get no rows.
SELECT d.id AS direction_id,d.position AS direction_position,d.title,d.why_suitable,
 dv.position AS vacancy_position,v.id AS vacancy_id,v.title AS vacancy_title,v.original_url,v.status,
 (c.source_hash=v.content_hash) AS source_unchanged
FROM recommendation_runs q JOIN recommendation_directions d ON d.run_id=q.id
LEFT JOIN recommendation_direction_vacancies dv ON dv.direction_id=d.id AND dv.run_id=q.id
LEFT JOIN vacancies v ON v.id=dv.vacancy_id
LEFT JOIN recommendation_candidates c ON c.run_id=q.id AND c.vacancy_id=v.id
WHERE q.id=:run_id AND q.user_id=:user_id ORDER BY d.position,dv.position;

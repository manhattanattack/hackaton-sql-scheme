-- MySQL 8.0.16+. Catalog: execute ONE numbered operation per backend action.
-- @user_id is authenticated user_profiles.id, never a client-supplied owner ID.
USE vacancy_aggregator;

-- QP01. Save original prompt and create a pending parsing request.
INSERT INTO search_requests (user_id,prompt_text) VALUES (@user_id,@prompt_text);
SELECT LAST_INSERT_ID() AS search_request_id;

-- QP02. Complete parsing. Backend validates JSON structure/types/ranges first.
-- Keys map to Q03 parameters plus skills[] and availability[]; see JSON_CONTRACT.md.
UPDATE search_requests
SET parsed_filters=@parsed_filters,status='parsed',parser_kind=@parser_kind,
  model_name=@model_name,error_code=NULL,parsed_at=UTC_TIMESTAMP(6)
WHERE id=@search_request_id AND user_id=@user_id AND status='pending';
-- Exactly 1 affected row required; 0 means wrong owner, missing or already finished.

-- QP03. Mark parsing failure; error_code is a short safe code, not a raw provider response.
UPDATE search_requests SET status='failed',error_code=@error_code,parsed_at=UTC_TIMESTAMP(6)
WHERE id=@search_request_id AND user_id=@user_id AND status='pending';

-- QP04. Read one request, scoped to the authenticated user.
SELECT id,prompt_text,parsed_filters,status,parser_kind,model_name,error_code,created_at,parsed_at
FROM search_requests WHERE id=@search_request_id AND user_id=@user_id;

-- QP05. List my search history.
SELECT id,prompt_text,status,created_at,parsed_at
FROM search_requests WHERE user_id=@user_id ORDER BY created_at DESC,id DESC
LIMIT @page_size OFFSET @offset;

-- QP06. Clear snapshot before replacing results. Backend starts a transaction,
-- locks owned search_requests row FOR UPDATE, calls this and repeats QP07, then commits.
-- All writers of results must take that parent lock to serialize replacements.
DELETE r FROM search_results r JOIN search_requests q ON q.id=r.search_request_id
WHERE q.id=@search_request_id AND q.user_id=@user_id AND q.status='parsed';

-- QP07. Save ONE real vacancy from Q03. Repeat for complete result list in QP06 transaction.
-- Plain INSERT intentionally rejects duplicate vacancy/position; rollback entire replacement on error.
INSERT INTO search_results (search_request_id,vacancy_id,position,skill_match_percent,explanation)
SELECT q.id,v.id,@position,@skill_match_percent,@explanation
FROM search_requests q JOIN vacancies v ON v.id=@vacancy_id AND v.status='active'
WHERE q.id=@search_request_id AND q.user_id=@user_id AND q.status='parsed';
-- Exactly 1 affected row required; query ownership prevents saving into someone else's request.

-- QP08. Read saved recommendations, including later-archived cards for honest history.
SELECT r.position,r.skill_match_percent,r.explanation,v.id AS vacancy_id,v.title,
  v.original_url,v.status,c.name AS company_name,s.name AS source_name
FROM search_results r JOIN search_requests q ON q.id=r.search_request_id
JOIN vacancies v ON v.id=r.vacancy_id
LEFT JOIN companies c ON c.id=v.company_id
JOIN sources s ON s.id=v.source_id
WHERE q.id=@search_request_id AND q.user_id=@user_id
ORDER BY r.position;

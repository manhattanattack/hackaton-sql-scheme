-- mysql2 namedPlaceholders=true. Each numbered block is ONE driver statement.
USE vacancy_aggregator;

-- QI01. Last safe modifiedFrom cursor for THIS source/filter scope only.
SELECT MAX(window_to) AS modified_through FROM import_runs
WHERE source_id=:source_id AND scope_hash=UNHEX(:scope_hash_hex) AND status='succeeded';

-- QI02. Start import. scope hash = SHA256 of stable canonical scope JSON.
-- window_to is captured BEFORE fetching; pass it as modifiedTo when supported.
INSERT INTO import_runs(source_id,scope_hash,scope_json,mode,window_from,window_to)
VALUES (:source_id,UNHEX(:scope_hash_hex),:scope_json,:mode,:window_from,:window_to);

-- QI03. Final counters; succeeded ONLY after ALL pages/regions were saved.
UPDATE import_runs SET status=:status,finished_at=UTC_TIMESTAMP(6),
 records_seen=:records_seen,inserted_count=:inserted_count,updated_count=:updated_count,
 skipped_count=:skipped_count,error_code=:error_code
WHERE id=:import_run_id AND source_id=:source_id AND status='running';

-- QI04. Import audit for admin/demo; API enforces admin access.
SELECT r.*,s.name AS source_name FROM import_runs r JOIN sources s ON s.id=r.source_id
ORDER BY r.started_at DESC,r.id DESC LIMIT :page_size OFFSET :offset;

-- QI05. Enqueue current content only; same version is idempotent.
INSERT INTO vacancy_ai_summaries(vacancy_id,provider,model,prompt_version,source_hash)
SELECT id,:provider,:model,:prompt_version,content_hash FROM vacancies
WHERE id=:vacancy_id AND status='active'
ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(vacancy_ai_summaries.id);

-- QI06. BEGIN on a dedicated connection, select ONE pending job and lock it.
-- SKIP LOCKED supports multiple workers; do NOT hold transaction across LLM call.
SELECT id,vacancy_id,provider,model,prompt_version,HEX(source_hash) AS source_hash_hex
FROM vacancy_ai_summaries WHERE status='pending' AND available_at<=UTC_TIMESTAMP(6)
ORDER BY available_at,id LIMIT 1 FOR UPDATE SKIP LOCKED;

-- QI07. Claim selected job, require affectedRows=1, then COMMIT before LLM.
-- lease_token_hex: new random 128-bit hex string per attempt, not an API key.
UPDATE vacancy_ai_summaries SET status='processing',attempts=attempts+1,
 lease_token=UNHEX(:lease_token_hex),lease_expires_at=TIMESTAMPADD(SECOND,:lease_seconds,UTC_TIMESTAMP(6)),
 error_code=NULL
WHERE id=:summary_id AND status='pending' AND available_at<=UTC_TIMESTAMP(6)
 AND :lease_seconds BETWEEN 1 AND 3600;

-- QI08. Fetch input only if claimed hash is STILL current. No row => abandon/requeue current version.
SELECT v.id,v.title,v.description,v.requirements,v.responsibilities,v.schedule_text,
 v.work_format,v.employment_type,v.contract_type,v.salary_min,v.salary_max,v.currency,v.salary_period
FROM vacancy_ai_summaries a JOIN vacancies v ON v.id=a.vacancy_id AND v.content_hash=a.source_hash
WHERE a.id=:summary_id AND a.status='processing' AND a.lease_token=UNHEX(:lease_token_hex)
 AND a.lease_expires_at>UTC_TIMESTAMP(6) AND v.status='active';

-- QI09. Complete validated JSON. Old/timed-out workers cannot overwrite a newer lease.
UPDATE vacancy_ai_summaries SET status='done',result_json=:result_json,
 lease_token=NULL,lease_expires_at=NULL,error_code=NULL,completed_at=UTC_TIMESTAMP(6)
WHERE id=:summary_id AND status='processing' AND lease_token=UNHEX(:lease_token_hex)
 AND lease_expires_at>UTC_TIMESTAMP(6);

-- QI10. Failed attempt. Retry later with QI12 if appropriate; API uses original text meanwhile.
UPDATE vacancy_ai_summaries SET status='failed',error_code=:error_code,
 lease_token=NULL,lease_expires_at=NULL,completed_at=UTC_TIMESTAMP(6)
WHERE id=:summary_id AND status='processing' AND lease_token=UNHEX(:lease_token_hex)
 AND lease_expires_at>UTC_TIMESTAMP(6);

-- QI11. Recover crashed/timed-out workers. A refreshed lease token fences their late writes.
UPDATE vacancy_ai_summaries SET status=IF(attempts<:max_attempts,'pending','failed'),
 error_code=IF(attempts<:max_attempts,NULL,'LEASE_EXPIRED'),
 available_at=TIMESTAMPADD(SECOND,:retry_seconds,UTC_TIMESTAMP(6)),
 completed_at=IF(attempts<:max_attempts,NULL,UTC_TIMESTAMP(6)),lease_token=NULL,lease_expires_at=NULL
WHERE status='processing' AND lease_expires_at<=UTC_TIMESTAMP(6);

-- QI12. Retry a transient failure with bounded attempts and backoff.
UPDATE vacancy_ai_summaries SET status='pending',error_code=NULL,completed_at=NULL,
 available_at=TIMESTAMPADD(SECOND,:retry_seconds,UTC_TIMESTAMP(6))
WHERE id=:summary_id AND status='failed' AND attempts<:max_attempts;

-- QI13. Read current version only. No row => render original vacancy, never stale AI content.
SELECT a.result_json,a.model,a.prompt_version FROM vacancy_ai_summaries a
JOIN vacancies v ON v.id=a.vacancy_id AND v.content_hash=a.source_hash
WHERE v.id=:vacancy_id AND a.provider=:provider AND a.model=:model
 AND a.prompt_version=:prompt_version AND a.status='done';

-- QI14. Inside import transaction, read prior row to count insert/update accurately
-- and reject older source_updated_at snapshots in backend BEFORE Q02.
-- Do not infer audit counts solely from affectedRows with varying client flags.
SELECT id,source_updated_at,HEX(content_hash) AS content_hash_hex FROM vacancies
WHERE source_id=:source_id AND external_id=:external_id FOR UPDATE;

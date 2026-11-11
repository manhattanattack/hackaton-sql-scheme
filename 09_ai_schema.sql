-- Cache + leased queue; no Redis or provider credentials in DB.
USE vacancy_aggregator;
CREATE TABLE vacancy_ai_summaries (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  vacancy_id BIGINT NOT NULL,
  provider VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  model VARCHAR(150) COLLATE utf8mb4_bin NOT NULL,
  prompt_version VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  source_hash BINARY(32) NOT NULL,
  status ENUM('pending','processing','done','failed') NOT NULL DEFAULT 'pending',
  result_json JSON NULL,
  attempts SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  available_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  lease_token BINARY(16) NULL,
  lease_expires_at DATETIME(6) NULL,
  error_code VARCHAR(80) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  completed_at DATETIME(6) NULL,
  UNIQUE KEY uq_ai_summary_version (vacancy_id,provider,model,prompt_version,source_hash),
  KEY ix_ai_summary_queue (status,available_at,id),
  CONSTRAINT fk_ai_summary_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id) ON DELETE CASCADE,
  CONSTRAINT ck_ai_summary_result CHECK (result_json IS NULL OR (
    JSON_TYPE(result_json)='OBJECT'
    AND JSON_CONTAINS_PATH(result_json,'all','$.simpleTitle','$.whatYouDo','$.requirements','$.conditions','$.beginnerFriendly')
    AND JSON_TYPE(JSON_EXTRACT(result_json,'$.simpleTitle'))='STRING'
    AND JSON_TYPE(JSON_EXTRACT(result_json,'$.whatYouDo'))='ARRAY'
    AND JSON_TYPE(JSON_EXTRACT(result_json,'$.requirements'))='ARRAY'
    AND JSON_TYPE(JSON_EXTRACT(result_json,'$.conditions'))='ARRAY'
    AND JSON_TYPE(JSON_EXTRACT(result_json,'$.beginnerFriendly'))='BOOLEAN'
  )),
  CONSTRAINT ck_ai_summary_state CHECK (
    (status='pending' AND result_json IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL AND completed_at IS NULL)
    OR (status='processing' AND result_json IS NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND completed_at IS NULL)
    OR (status='done' AND result_json IS NOT NULL AND lease_token IS NULL AND lease_expires_at IS NULL AND completed_at IS NOT NULL AND error_code IS NULL)
    OR (status='failed' AND result_json IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL AND completed_at IS NOT NULL AND error_code IS NOT NULL)
  )
) ENGINE=InnoDB;

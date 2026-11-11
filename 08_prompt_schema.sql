-- Recommendations: one canonical history for prompt -> candidates -> directions.
USE vacancy_aggregator;
CREATE TABLE recommendation_runs (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  prompt_text TEXT NOT NULL,
  parsed_profile JSON NULL,
  status ENUM('pending','parsed','processing','done','failed') NOT NULL DEFAULT 'pending',
  parser_model VARCHAR(150) NULL,
  recommendation_model VARCHAR(150) NULL,
  prompt_version VARCHAR(64) NULL,
  error_code VARCHAR(80) NULL,
  result_note VARCHAR(500) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  parsed_at DATETIME(6) NULL,
  completed_at DATETIME(6) NULL,
  KEY ix_recommendation_runs_user (user_id,created_at,id),
  CONSTRAINT fk_recommendation_runs_user FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE,
  CONSTRAINT ck_recommendation_runs_prompt CHECK (CHAR_LENGTH(TRIM(prompt_text)) BETWEEN 1 AND 10000),
  CONSTRAINT ck_recommendation_runs_json CHECK (parsed_profile IS NULL OR JSON_TYPE(parsed_profile)='OBJECT'),
  CONSTRAINT ck_recommendation_runs_state CHECK (
    (status='pending' AND parsed_profile IS NULL AND parsed_at IS NULL AND completed_at IS NULL AND error_code IS NULL)
    OR (status IN ('parsed','processing') AND parsed_profile IS NOT NULL AND parsed_at IS NOT NULL AND completed_at IS NULL AND error_code IS NULL)
    OR (status='done' AND parsed_profile IS NOT NULL AND parsed_at IS NOT NULL AND completed_at IS NOT NULL AND error_code IS NULL)
    OR (status='failed' AND completed_at IS NOT NULL AND error_code IS NOT NULL)
  )
) ENGINE=InnoDB;

CREATE TABLE recommendation_candidates (
  run_id BIGINT NOT NULL,
  vacancy_id BIGINT NOT NULL,
  position SMALLINT UNSIGNED NOT NULL,
  source_hash BINARY(32) NOT NULL,
  skill_match_percent DECIMAL(5,2) NULL,
  PRIMARY KEY (run_id,vacancy_id),
  UNIQUE KEY uq_recommendation_candidates_position (run_id,position),
  KEY ix_recommendation_candidates_vacancy (vacancy_id),
  CONSTRAINT fk_recommendation_candidates_run FOREIGN KEY (run_id) REFERENCES recommendation_runs(id) ON DELETE CASCADE,
  CONSTRAINT fk_recommendation_candidates_vacancy FOREIGN KEY (vacancy_id) REFERENCES vacancies(id),
  CONSTRAINT ck_recommendation_candidates_position CHECK (position BETWEEN 1 AND 50),
  CONSTRAINT ck_recommendation_candidates_score CHECK (skill_match_percent IS NULL OR skill_match_percent BETWEEN 0 AND 100)
) ENGINE=InnoDB;

CREATE TABLE recommendation_directions (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  run_id BIGINT NOT NULL,
  position TINYINT UNSIGNED NOT NULL,
  title VARCHAR(255) NOT NULL,
  why_suitable TEXT NOT NULL,
  UNIQUE KEY uq_recommendation_direction_position (run_id,position),
  UNIQUE KEY uq_recommendation_direction_run (id,run_id),
  CONSTRAINT fk_recommendation_direction_run FOREIGN KEY (run_id) REFERENCES recommendation_runs(id) ON DELETE CASCADE,
  CONSTRAINT ck_recommendation_direction_position CHECK (position BETWEEN 1 AND 5)
) ENGINE=InnoDB;

CREATE TABLE recommendation_direction_vacancies (
  run_id BIGINT NOT NULL,
  direction_id BIGINT NOT NULL,
  vacancy_id BIGINT NOT NULL,
  position SMALLINT UNSIGNED NOT NULL,
  PRIMARY KEY (direction_id,vacancy_id),
  UNIQUE KEY uq_recommendation_direction_vacancy_position (direction_id,position),
  CONSTRAINT fk_direction_vacancies_direction FOREIGN KEY (direction_id,run_id)
    REFERENCES recommendation_directions(id,run_id) ON DELETE CASCADE,
  CONSTRAINT fk_direction_vacancies_candidate FOREIGN KEY (run_id,vacancy_id)
    REFERENCES recommendation_candidates(run_id,vacancy_id),
  CONSTRAINT ck_direction_vacancies_position CHECK (position BETWEEN 1 AND 50)
) ENGINE=InnoDB;

-- mysql2 namedPlaceholders=true; each statement executed separately.
-- Backend verifies passwords, creates JWT, enforces role/status; DB stores hashes only.
USE vacancy_aggregator;

-- QA01. Registration: BEGIN in backend, execute this and QA02, COMMIT; rollback on any error.
-- Backend UUID subject, normalized email and salted password hash (argon2/bcrypt).
-- Role is omitted intentionally: self-registration always gets DB default user.
INSERT INTO users(id,email,normalized_email,password_hash)
VALUES (:auth_subject,:email,:normalized_email,:password_hash);

-- QA02. Idempotent profile creation for a known active account.
INSERT INTO user_profiles(auth_subject,display_name)
SELECT u.id,:display_name FROM users u WHERE u.id=:auth_subject AND u.status='active'
ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(user_profiles.id);
SELECT p.id AS user_id FROM user_profiles p JOIN users u ON u.id=p.auth_subject
WHERE p.auth_subject=:auth_subject AND u.status='active';

-- QA03. Resolve a verified account to profile; never trust client owner/role.
SELECT p.id AS user_id,p.auth_subject,p.display_name,p.city,p.created_at,u.role,u.token_version
FROM user_profiles p JOIN users u ON u.id=p.auth_subject
WHERE u.id=:auth_subject AND u.status='active';

-- QA04. Login lookup, server only. Backend verifies password_hash; never send it to client.
SELECT id,password_hash,role,token_version FROM users
WHERE normalized_email=:normalized_email AND status='active';

-- QA05. Create refresh token AFTER password verification. Backend keeps raw random token;
-- DB only gets its SHA256 hex digest. verified_password_hash guards concurrent password changes.
INSERT INTO refresh_tokens(user_subject,token_hash,expires_at)
SELECT id,UNHEX(:token_hash_hex),:expires_at FROM users
WHERE id=:auth_subject AND status='active' AND password_hash=:verified_password_hash
 AND :expires_at>UTC_TIMESTAMP(6) AND CHAR_LENGTH(:token_hash_hex)=64
 AND :token_hash_hex REGEXP '^[0-9a-fA-F]{64}$';

-- QA06. Refresh rotation: BEGIN -> lock this row -> verify -> QA07 -> QA05 -> COMMIT.
-- Exactly one active token can win concurrent rotation. Keep all calls on ONE connection.
SELECT t.id,t.user_subject,u.role,u.token_version,u.password_hash
FROM refresh_tokens t JOIN users u ON u.id=t.user_subject
WHERE t.token_hash=UNHEX(:token_hash_hex) AND t.revoked_at IS NULL
  AND t.expires_at>UTC_TIMESTAMP(6) AND u.status='active'
FOR UPDATE;

-- QA07. Consume/revoke one locked refresh token; exactly 1 affected row required.
UPDATE refresh_tokens SET revoked_at=UTC_TIMESTAMP(6)
WHERE id=:refresh_id AND user_subject=:auth_subject AND revoked_at IS NULL;

-- QA08. Logout all/change credentials: BEGIN, revoke tokens + bump version, COMMIT.
-- JWT middleware must compare token version/status with DB for immediate access-token revocation.
UPDATE refresh_tokens SET revoked_at=UTC_TIMESTAMP(6) WHERE user_subject=:auth_subject AND revoked_at IS NULL;
UPDATE users SET token_version=token_version+1 WHERE id=:auth_subject;

-- QA09. Own profile update.
UPDATE user_profiles SET display_name=:display_name,city=:city WHERE auth_subject=:auth_subject;

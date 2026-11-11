-- Identity handles accounts, passwords, roles, login and tokens in the backend.
-- This catalog ONLY maps a verified Identity principal to a business profile.
-- @auth_subject is AspNetUsers.Id from the verified principal, never client body.
USE vacancy_aggregator;

-- QA01. Get my profile from the authenticated account ID.
SELECT p.id AS user_id,p.auth_subject,p.display_name,p.city,p.time_zone,p.created_at
FROM user_profiles p JOIN AspNetUsers u ON u.Id=p.auth_subject
WHERE p.auth_subject=@auth_subject;

-- QA02. Idempotent lazy profile creation. Existing profile data is retained.
-- Concurrent calls converge on UNIQUE(auth_subject); no account/password created.
INSERT INTO user_profiles (auth_subject,display_name,time_zone)
SELECT u.Id,@display_name,@time_zone FROM AspNetUsers u WHERE u.Id=@auth_subject
ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(user_profiles.id);
-- Do not use LAST_INSERT_ID when SELECT inserted 0 rows: find by trusted subject.
SELECT id AS user_id FROM user_profiles WHERE auth_subject=@auth_subject;

-- QA03. Update my profile. Changing timezone requires reviewing/replacing saved
-- availability in the same transaction, to preserve the intended local times.
UPDATE user_profiles p JOIN AspNetUsers u ON u.Id=p.auth_subject
SET p.display_name=@display_name,p.city=@city,p.time_zone=@time_zone
WHERE p.auth_subject=@auth_subject;
